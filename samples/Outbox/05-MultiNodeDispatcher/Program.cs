using System.Data.Common;
using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.Hosting;
using DNV.Outbox.Http;
using DNV.Outbox.SqlServer;
using Microsoft.Data.SqlClient;
using Outbox.Samples.Domain;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

// Every replica of this one project is identical apart from this value. In a container app it
// would be the replica name; here run-nodes.ps1 sets OUTBOX__NODEID to node-1, node-2, node-3.
var nodeId = builder.Configuration["Outbox:NodeId"] ?? Environment.MachineName;

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
		// This is the whole sample: every node runs the dispatcher, against the same table, with
		// no leader election and no distributed lock. Safety comes from the claim, not from
		// coordination between nodes.
		dispatcher.InstanceId = nodeId;

		// Deliberately small and fast so the three nodes genuinely contend. Production defaults
		// are a batch of 50 every five seconds, which would let one node drain the table before
		// the others woke up - correct, but it would demonstrate nothing.
		dispatcher.PollInterval = TimeSpan.FromMilliseconds(500);
		dispatcher.BatchSize = 10;
		dispatcher.MaxConcurrency = 4;

		// How long a claim is held. It is a lease, not a lock: if this process dies, the lease
		// expires and another node picks the record up. Short here so that is quick to watch.
		dispatcher.ClaimDuration = TimeSpan.FromSeconds(30);
	});

var app = builder.Build();

// Schema bootstrap, deliberately done before the dispatcher can do anything useful. Note that
// this is the one part of startup that is NOT safe to run on three nodes at once - see README
// section 7 - which is why both scripts start the nodes one at a time.
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

app.Logger.LogInformation("Node {NodeId} ready.", nodeId);

// Identical on every node. Which node accepts an order has nothing to do with which node
// eventually dispatches it - that is the point.
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
		new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
		cancellationToken);

	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		AcceptedBy = nodeId,
		EventId = messages[0].EventId,
		OutboxIds = messages.Select(m => m.OutboxId),
	});
});

// Aggregate counters over the shared table. Every node returns the same numbers, because there
// is only one table - which is worth seeing for yourself.
app.MapGet("/outbox/stats", async (IOutboxStore store, CancellationToken cancellationToken) =>
	Results.Ok(new
	{
		Node = nodeId,
		Statistics = await store.GetStatisticsAsync(cancellationToken),
	}));

app.MapGet("/", () => Results.Ok(new
{
	Sample = "05-MultiNodeDispatcher",
	Node = nodeId,
	Description = "Three identical nodes run the dispatcher against one outbox table. No leader election, no distributed lock, and no record is delivered twice.",
	Endpoints = new[]
	{
		"GET  /              this index",
		"GET  /health        liveness probe",
		"POST /orders        place an order (body: { tenantId, customerId, total })",
		"GET  /outbox/stats  aggregate counters over the shared table",
	},
	Hint = "Place orders on any node, then watch all three node windows: the dispatch logs interleave.",
}));

app.MapGet("/health", () => Results.Ok(new { Status = "healthy", Node = nodeId }));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
