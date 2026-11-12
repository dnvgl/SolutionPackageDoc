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

// A way to prove the image itself is sound without a database behind it.
//
// deploy.ps1 runs the freshly built image with OUTBOX_SMOKE=1 before pushing it. That exercises
// the entrypoint, the base image and the processor architecture - the things that are easy to get
// wrong when building a Linux image from Windows, and that otherwise fail for the first time in
// Azure as a crash-looping revision with no useful logs.
if (Environment.GetEnvironmentVariable("OUTBOX_SMOKE") == "1")
{
	Console.WriteLine($"smoke ok: {Environment.Version} on {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}");
	return 0;
}

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

var pubSubName = builder.Configuration["Dapr:PubSubName"]!;
var topicName = builder.Configuration["Dapr:TopicName"]!;

// Container Apps sets CONTAINER_APP_REPLICA_NAME to the name shown by
// `az containerapp replica list`, which is what makes the evidence in this sample checkable: a
// claim owner in the database can be matched to a replica in the portal. HOSTNAME is the fallback
// for a plain `docker run`, where neither variable is set by Azure.
var replicaName =
	Environment.GetEnvironmentVariable("CONTAINER_APP_REPLICA_NAME")
	?? Environment.GetEnvironmentVariable("HOSTNAME")
	?? Environment.MachineName;

var revisionName = Environment.GetEnvironmentVariable("CONTAINER_APP_REVISION") ?? "(local)";

// Captured once at startup so /node shows how long this replica has been up, which is how the
// restart test is confirmed to have actually restarted something.
var startedAt = DateTimeOffset.UtcNow;

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
		dapr.ClientName = "billing";
		dapr.TopicName = topicName;

		// The outbox id travels as the CloudEvents id. In this sample it is also the thing the
		// verifier counts: if two replicas ever dispatched the same record, the same id would
		// arrive twice on a topic that is deliberately not deduplicating.
		dapr.SendCloudEventId = true;
	})
	.AddDispatcher(dispatcher =>
	{
		// Every replica runs a dispatcher. Nothing elects a leader and nothing is configured to
		// make one replica special - the store's claim is the only thing keeping them apart.
		//
		// InstanceId already defaults to something unique per process. It is set explicitly to
		// the replica name so that the ClaimOwner column reads as a name you can look up rather
		// than a machine name and a pid.
		dispatcher.InstanceId = replicaName;

		dispatcher.PollInterval = TimeSpan.FromSeconds(2);
		dispatcher.BatchSize = 20;

		// Comfortably longer than a publish through the sidecar. If a replica is killed
		// mid-flight, its claims stay held for this long before another replica may take them -
		// which is the delay you see in the restart test.
		dispatcher.ClaimDuration = TimeSpan.FromSeconds(60);
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

static async Task<OutboxMessage> PlaceOrderAsync(
	string connectionString,
	ISqlOutboxSessionFactory sessionFactory,
	string tenantId,
	string customerId,
	decimal total,
	CancellationToken cancellationToken)
{
	var order = Order.Place(tenantId, customerId, total);

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
	return messages[0];
}

app.MapPost("/orders", async (
	PlaceOrderRequest request,
	ISqlOutboxSessionFactory sessionFactory,
	CancellationToken cancellationToken) =>
{
	var message = await PlaceOrderAsync(
		connectionString, sessionFactory, request.TenantId, request.CustomerId, request.Total, cancellationToken);

	return Results.Ok(new
	{
		message.OutboxId,
		message.EventId,

		// Which replica took the HTTP request. Ingress load-balances, so a burst spreads across
		// replicas - but note that this says nothing about which replica will dispatch the
		// record. Those are independent decisions.
		AcceptedBy = replicaName,
	});
});

// The burst. One transaction per order, because that is what a real caller does - batching them
// into a single transaction would quietly make the dispatcher's job easier than it is in life.
app.MapPost("/orders/bulk", async (
	ISqlOutboxSessionFactory sessionFactory,
	CancellationToken cancellationToken,
	int count = 100,
	string tenantId = "tenant-scaleout",
	string customerId = "customer-1") =>
{
	if (count is < 1 or > 1000)
		return Results.BadRequest(new { Error = "count must be between 1 and 1000." });

	var outboxIds = new List<Guid>(count);
	for (var i = 0; i < count; i++)
	{
		var message = await PlaceOrderAsync(
			connectionString, sessionFactory, tenantId, customerId, 10m + i, cancellationToken);
		outboxIds.Add(message.OutboxId);
	}

	return Results.Ok(new
	{
		Count = outboxIds.Count,
		AcceptedBy = replicaName,

		// The full list, so the verifier's count can be compared against the ids that were
		// actually enqueued rather than against a number somebody remembered.
		OutboxIds = outboxIds,
	});
});

app.MapGet("/node", () => Results.Ok(new
{
	Replica = replicaName,
	Revision = revisionName,
	StartedAt = startedAt,
}));

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
			Status = message.Status.ToString(),
			message.AttemptCount,

			// Non-null only while the record is being processed. CompleteAsync clears it, so a
			// delivered record does not remember which replica sent it - the Log Analytics query
			// in the README is where that evidence lives.
			message.ClaimOwner,
			message.CreatedAt,
			message.DeliveredAt,
			message.LastError,
		});
});

app.MapGet("/outbox/stats", async (IOutboxStore store, CancellationToken cancellationToken) =>
	Results.Ok(await store.GetStatisticsAsync(cancellationToken)));

// Deliberately sends an already-delivered record a second time, with the same identifiers the
// dispatcher would use.
//
// This exists to keep the verifier honest. A verifier that reports "0 duplicates" is worthless
// until it has been shown reporting a duplicate it should have caught, and this topic has
// duplicate detection switched off, so the replay really does arrive and really is counted.
// Sample 09 runs the same endpoint against a de-duplicating queue and sees the opposite result.
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
		Outcome = outcome.Kind.ToString(),
		Error = outcome.Error,
		Note = "Replayed with the same outbox id. scaleout-events has no duplicate detection, so the verifier WILL count this as a duplicate.",
	});
});

app.MapGet("/", () => Results.Ok(new
{
	Sample = "10-ContainerApps-Scaleout",
	Description = "Several Container Apps replicas run the same dispatcher against one outbox table. Each record is delivered exactly once despite that.",
	Replica = replicaName,
	Revision = revisionName,
	Endpoints = new[]
	{
		"GET  /                    this index",
		"GET  /health              liveness probe",
		"GET  /node                which replica answered",
		"POST /orders              place one order (body: { tenantId, customerId, total })",
		"POST /orders/bulk?count=  place many orders and return their outbox ids",
		"GET  /outbox/{outboxId}   inspect one record",
		"POST /outbox/{id}/resend  replay a record to prove the verifier detects duplicates",
		"GET  /outbox/stats        aggregate counters",
	},
	PubSub = new { Component = pubSubName, Topic = topicName },
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

return 0;

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
