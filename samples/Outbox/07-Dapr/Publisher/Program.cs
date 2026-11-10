using System.Data.Common;
using DNV.Dapr.PubSub;
using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.Dapr;
using DNV.Outbox.Hosting;
using DNV.Outbox.SqlServer;
using Microsoft.Data.SqlClient;
using Outbox.Samples.Domain;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

var pubSubName = builder.Configuration["Dapr:PubSubName"]!;
var topicName = builder.Configuration["Dapr:TopicName"]!;

// The pub/sub client talks to the sidecar over HTTP. No endpoint is configured here on purpose:
// DaprPubSubOptions falls back to DAPR_HTTP_ENDPOINT, then to http://localhost:{DAPR_HTTP_PORT},
// both of which `dapr run` sets for the process it starts. Hard-coding a port would break the
// moment the sample is run with a different one.
builder.Services.AddDaprPubSubClient("billing", options =>
{
	options.PubSubName = pubSubName;
	options.TopicName = topicName;
});

builder.Services.AddOutbox()
	.UseSqlServer(options =>
	{
		options.ConnectionString = connectionString;
		options.Schema = "outbox";
		options.Table = "OutboxMessages";
	})
	.AddDaprDestination("billing", dapr =>
	{
		// The named pub/sub client to publish through. It defaults to the destination name, so
		// this line is redundant here - it is spelled out because the two are separate concepts
		// and are free to differ.
		dapr.ClientName = "billing";
		dapr.TopicName = topicName;

		// Publish the outbox id as the CloudEvents id. Dapr itself delivers at least once, so a
		// subscriber can see the same message twice; stamping the id the outbox already
		// guarantees to be stable across retries gives the subscriber something to deduplicate
		// on. On by default - written out because it is the point of this sample.
		dapr.SendCloudEventId = true;
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

// Place an order. The row and its outbox record are written in one SQL transaction; nothing is
// published here. The dispatcher picks the record up afterwards and publishes it through the
// sidecar, so a broker outage cannot lose an event the business already committed to.
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

		// Worth watching: this value turns up unchanged as the CloudEvents id at the subscriber.
		OutboxId = messages[0].OutboxId,
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
	Sample = "07-Dapr (publisher)",
	Description = "Commits orders and their outbox records in one SQL transaction, then publishes them through a Dapr pub/sub component.",
	Endpoints = new[]
	{
		"GET  /                    this index",
		"GET  /health              liveness probe",
		"POST /orders              place an order (body: { tenantId, customerId, total })",
		"GET  /outbox/{outboxId}   inspect one record",
		"GET  /outbox/stats        aggregate counters",
	},
	PubSub = new { Component = pubSubName, Topic = topicName },
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
