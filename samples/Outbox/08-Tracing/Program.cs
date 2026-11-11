using System.Data.Common;
using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.Hosting;
using DNV.Outbox.Http;
using DNV.Outbox.SqlServer;
using Microsoft.Data.SqlClient;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Outbox.Samples.Domain;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

// The library takes no dependency on OpenTelemetry. It publishes a plain ActivitySource named
// "DNV.Outbox" (OutboxTelemetry.ActivitySourceName), and metrics under the same name, so any
// listener can subscribe. AddSource is the one line that connects them.
builder.Services.AddOpenTelemetry()
	.ConfigureResource(resource => resource.AddService("outbox-sample-08"))
	.WithTracing(tracing => tracing
		.AddSource(OutboxTelemetry.ActivitySourceName)
		.AddAspNetCoreInstrumentation()
		.AddHttpClientInstrumentation()
		.AddConsoleExporter());

builder.Services.AddOutbox()
	.UseSqlServer(options =>
	{
		options.ConnectionString = connectionString;
		options.Schema = "outbox";
		options.Table = "OutboxMessages";
	})
	.AddHttpDestination("receiver", http =>
	{
		http.Endpoint = new Uri(builder.Configuration["Outbox:ReceiverEndpoint"]!);
	})
	.AddDispatcher(dispatcher =>
	{
		dispatcher.PollInterval = TimeSpan.FromSeconds(1);
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

	var enqueue = new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1)
	{
		// Normally omitted. Leaving TraceContext null is the path almost every application wants:
		// the library captures Activity.Current, which here is the server span ASP.NET Core
		// created for this request, and persists its traceparent.
		//
		// Supply it explicitly when Activity.Current is not the parent you want - replaying an
		// archived message, a batch job continuing a trace that started elsewhere, or a message
		// received from a broker whose context you want to continue rather than branch from.
		TraceContext = request.TraceParent is null
			? null
			: new OutboxTraceContext(request.TraceParent, request.TraceState),
	};

	var outbox = sessionFactory.ForTransaction(connection, transaction);
	var messages = await outbox.EnqueueAsync(order.ToIntegrationEvent(), enqueue, cancellationToken);

	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		EventId = messages[0].EventId,
		OutboxId = messages[0].OutboxId,

		// The traceparent that was actually persisted - ambient or explicit, whichever won.
		messages[0].TraceParent,
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
			message.EventType,
			Status = message.Status.ToString(),
			message.AttemptCount,
			message.TraceParent,
			message.TraceState,
			message.CreatedAt,
			message.DeliveredAt,
		});
});

// Reports the trace the current request belongs to. Handy for seeing that an incoming traceparent
// becomes a server span whose id is what the outbox will capture - and, when it does not, for
// seeing why. The usual cause is a client that sends its own traceparent in ADDITION to yours.
app.MapGet("/trace", (HttpContext context) =>
{
	var incoming = context.Request.Headers["traceparent"];
	var current = System.Diagnostics.Activity.Current;
	var honoured = incoming.Count == 1
		&& current is not null
		&& incoming[0]!.Contains(current.TraceId.ToString(), StringComparison.OrdinalIgnoreCase);

	return Results.Ok(new
	{
		IncomingTraceParent = incoming.Count == 0 ? null : incoming.ToString(),
		IncomingTraceParentCount = incoming.Count,
		CurrentActivityId = current?.Id,
		TraceId = current?.TraceId.ToString(),
		Diagnosis = incoming.Count switch
		{
			0 => "No traceparent was sent, so this request started a brand new root trace.",
			1 when honoured => "The incoming traceparent was honoured: this request continues that trace.",
			1 => "A traceparent was sent but not honoured - check that it is well formed: 00-<32 hex>-<16 hex>-01.",
			_ => $"{incoming.Count} traceparent headers were sent. ASP.NET Core cannot parse that, so it " +
				"started a new root trace and the trace id you sent was lost. Your HTTP client is almost " +
				"certainly injecting its own on top of yours - see the README troubleshooting section.",
		},
	});
});

app.MapGet("/", () => Results.Ok(new
{
	Sample = "08-Tracing",
	Description = "Shows that a W3C trace survives the outbox: the delivery happens later, in another process, and is still part of the trace that caused it.",
	Endpoints = new[]
	{
		"GET  /                   this index",
		"GET  /health             liveness probe",
		"GET  /trace              the trace this request belongs to",
		"POST /orders             place an order (body: { tenantId, customerId, total, traceParent?, traceState? })",
		"GET  /outbox/{outboxId}  inspect one record, including the persisted trace context",
	},
	Hint = "Send a traceparent header and watch the same trace id arrive at the receiver, which records what it saw on http://localhost:5100/deliveries.",
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

// traceParent and traceState are optional. When absent the ambient trace is captured, which is
// the normal path; when present they override it.
internal sealed record PlaceOrderRequest(
	string TenantId,
	string CustomerId,
	decimal Total,
	string? TraceParent = null,
	string? TraceState = null);
