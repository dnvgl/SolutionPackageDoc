using System.Data.Common;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using DNV.Outbox.Abstractions;
using DNV.Outbox.AzureServiceBus;
using DNV.Outbox.Core;
using DNV.Outbox.Hosting;
using DNV.Outbox.SqlServer;
using Microsoft.Data.SqlClient;
using Outbox.Samples.Domain;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

var fullyQualifiedNamespace = builder.Configuration["ServiceBus:Namespace"]
	?? throw new InvalidOperationException("ServiceBus:Namespace is not configured.");

var queueName = builder.Configuration["ServiceBus:Queue"] ?? "order-events";

// The application owns the client and its credentials; the library only ever resolves it.
//
// The exclusions matter more than they look. DefaultAzureCredential walks a chain, and on a
// developer machine VisualStudioCredential is tried BEFORE AzureCliCredential - so if Visual
// Studio is signed in as a different account than `az login` (very common where an admin
// account exists), every send fails with "'Send' claim(s) are required" even though the roles
// were granted correctly. Pinning the chain makes the sample use the identity that
// infra\provision.ps1 actually assigned roles to. ManagedIdentityCredential is still in the
// chain, so the same code works unchanged when hosted in Azure.
builder.Services.AddSingleton(new ServiceBusClient(
	fullyQualifiedNamespace,
	new DefaultAzureCredential(new DefaultAzureCredentialOptions
	{
		ExcludeVisualStudioCredential = true,
		ExcludeAzurePowerShellCredential = true,
		ExcludeInteractiveBrowserCredential = true,
	})));

builder.Services.AddOutbox()
	.UseSqlServer(options =>
	{
		options.ConnectionString = connectionString;
		options.Schema = "outbox";
		options.Table = "OutboxMessages";
	})
	.AddServiceBusDestination("billing", sb =>
	{
		sb.EntityPath = queueName;

		// The broker deduplicates on MessageId within the queue's detection window. The OutboxId
		// is stable across every retry of one delivery, so an at-least-once resend collapses into
		// exactly one message for the consumer. This is the whole point of the sample, and it is
		// the default - written out because it is what makes the guarantee work.
		sb.MessageIdSource = ServiceBusMessageIdSource.OutboxId;
	})
	.AddDispatcher(dispatcher =>
	{
		dispatcher.PollInterval = TimeSpan.FromSeconds(2);
		dispatcher.BatchSize = 20;
	});

var app = builder.Build();

await using (var scope = app.Services.CreateAsyncScope())
{
	await scope.ServiceProvider
		.GetRequiredService<SqlOutboxSchemaInitializer>()
		.EnsureCreatedAsync();

	await using var connection = new SqlConnection(connectionString);
	await connection.OpenAsync();
	await using var command = connection.CreateCommand();
	command.CommandText = """
		IF OBJECT_ID(N'dbo.Orders', N'U') IS NULL
		CREATE TABLE dbo.Orders
		(
			Id          NVARCHAR(64)   NOT NULL PRIMARY KEY,
			TenantId    NVARCHAR(64)   NOT NULL,
			CustomerId  NVARCHAR(64)   NOT NULL,
			Total       DECIMAL(18, 2) NOT NULL,
			Currency    NVARCHAR(3)    NOT NULL,
			PlacedAt    DATETIMEOFFSET NOT NULL
		);
		""";
	await command.ExecuteNonQueryAsync();
}

// Place an order. The row and its outbox record are committed in one local SQL transaction, and
// nothing is sent to the broker here. Service Bus is a remote system that can be slow, throttled
// or unreachable, and none of that may be allowed to decide whether an order exists.
app.MapPost("/orders", async (
	PlaceOrderRequest request,
	ISqlOutboxSessionFactory sessionFactory,
	CancellationToken cancellationToken) =>
{
	var order = Order.Place(request.TenantId, request.CustomerId, request.Total);

	await using var connection = new SqlConnection(connectionString);
	await connection.OpenAsync(cancellationToken);
	await using DbTransaction transaction = await connection.BeginTransactionAsync(cancellationToken);

	await using (var command = connection.CreateCommand())
	{
		command.Transaction = (SqlTransaction)transaction;
		command.CommandText = """
			INSERT INTO dbo.Orders (Id, TenantId, CustomerId, Total, Currency, PlacedAt)
			VALUES (@id, @tenantId, @customerId, @total, @currency, @placedAt);
			""";
		command.Parameters.AddWithValue("@id", order.Id);
		command.Parameters.AddWithValue("@tenantId", order.TenantId);
		command.Parameters.AddWithValue("@customerId", order.CustomerId);
		command.Parameters.AddWithValue("@total", order.Total);
		command.Parameters.AddWithValue("@currency", order.Currency);
		command.Parameters.AddWithValue("@placedAt", order.PlacedAt);
		await command.ExecuteNonQueryAsync(cancellationToken);
	}

	var outbox = sessionFactory.ForTransaction(connection, transaction);
	var messages = await outbox.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest(["billing"], eventType: nameof(OrderPlaced), eventVersion: 1),
		cancellationToken);

	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		EventId = messages[0].EventId,

		// Watch this value: it arrives at the consumer as the Service Bus MessageId.
		OutboxId = messages[0].OutboxId,
	});
});

// Sends an already-delivered record to the broker a second time, with its identifiers unchanged.
//
// This is not a contrived test hook. It is exactly what the dispatcher does when a send succeeds
// but the acknowledgement is lost: the record is still Processing, the claim expires, and the
// same OutboxMessage is sent again. At-least-once delivery guarantees this will happen
// eventually, so the interesting question is what the consumer sees - and the answer is one
// message, because the MessageId has not changed and the broker is deduplicating.
app.MapPost("/outbox/{outboxId:guid}/resend", async (
	Guid outboxId,
	IOutboxStore store,
	IEnumerable<IOutboxDestination> destinations,
	CancellationToken cancellationToken) =>
{
	var message = await store.GetAsync(outboxId, partitionKey: null, cancellationToken);
	if (message is null)
		return Results.NotFound();

	var destination = destinations.Single(d => d.Name == message.Destination);
	var outcome = await destination.SendAsync(message, cancellationToken);

	return Results.Ok(new
	{
		message.OutboxId,
		message.EventId,

		// The broker accepts a duplicate without complaint and silently discards it, so a
		// successful outcome here does NOT mean the consumer received anything.
		Outcome = outcome.Kind.ToString(),
		Error = outcome.Error,
		MessageId = message.OutboxId.ToString("D"),
		Note = "Sent again with the same MessageId. Inside the duplicate detection window the broker discards it.",
	});
});

app.MapGet("/outbox/{outboxId:guid}", async (
	Guid outboxId,
	IOutboxStore store,
	CancellationToken cancellationToken) =>
{
	var message = await store.GetAsync(outboxId, partitionKey: null, cancellationToken);

	return message is null
		? Results.NotFound()
		: Results.Ok(new
		{
			message.OutboxId,
			message.EventId,
			message.Destination,
			message.EventType,

			// Serialized by name rather than as the underlying number, so this reads as
			// "Delivered" rather than "3".
			Status = message.Status.ToString(),
			message.AttemptCount,
			message.TraceParent,
			message.CreatedAt,
			message.DeliveredAt,
			message.LastError,
		});
});

app.MapGet("/outbox/stats", async (IOutboxStore store, CancellationToken cancellationToken) =>
	Results.Ok(await store.GetStatisticsAsync(cancellationToken)));

app.MapGet("/", () => Results.Ok(new
{
	Sample = "09-AzureServiceBus",
	Description = "Commits orders and their outbox records in one SQL transaction, then dispatches them to an Azure Service Bus queue whose duplicate detection is keyed on the outbox id.",
	Endpoints = new[]
	{
		"GET  /                          this index",
		"GET  /health                    liveness probe",
		"POST /orders                    place an order (body: { tenantId, customerId, total })",
		"GET  /outbox/{outboxId}         inspect one record",
		"POST /outbox/{outboxId}/resend  send it again with the same MessageId",
		"GET  /outbox/stats              aggregate counters",
	},
	ServiceBus = new { Namespace = fullyQualifiedNamespace, Queue = queueName },
	Hint = "Run the Consumer project in another terminal to watch messages arrive.",
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
