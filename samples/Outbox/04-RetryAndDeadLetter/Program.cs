using System.Data;
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
	})
	.ConfigureRetry(retry =>
	{
		// Deliberately tiny so the whole failure path finishes in seconds and is visible in one
		// screen of logs. Production defaults back off to minutes and allow 8 attempts.
		retry.BaseDelay = TimeSpan.FromSeconds(1);
		retry.Multiplier = 2;
		retry.MaxDelay = TimeSpan.FromSeconds(8);

		// Jitter spreads retries from competing replicas so they do not stampede a recovering
		// destination together. It makes the delays slightly unpredictable, which is the point.
		retry.JitterRatio = 0.2;

		// The attempt on which a transient failure becomes terminal: attempts 1-3 are retried,
		// attempt 4 dead-letters.
		retry.MaxAttempts = 4;
	})
	.AddRetention(retention =>
	{
		// Terminal records are swept so the table does not grow without bound. Dead letters are
		// kept far longer than delivered ones, because somebody has to come and look at them.
		retention.DeliveredRetention = TimeSpan.FromMinutes(1);
		retention.DeadLetteredRetention = TimeSpan.FromHours(1);
		retention.SweepInterval = TimeSpan.FromSeconds(30);
	})
	.AddHealthCheck(health =>
	{
		// Backlog age, not backlog size, is the symptom that matters: it means events the
		// business already committed are not reaching anyone.
		health.DegradedBacklogAge = TimeSpan.FromSeconds(30);
		health.UnhealthyBacklogAge = TimeSpan.FromMinutes(2);
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

	var outbox = sessionFactory.ForTransaction(connection, transaction);
	var messages = await outbox.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
		cancellationToken);

	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		EventId = messages[0].EventId,
		OutboxIds = messages.Select(m => m.OutboxId),
	});
});

// Inspect one record. This is how you watch a record move Pending -> Failed -> DeadLettered,
// and it is the honest way to see NextAttemptAt: a failed record is invisible to the dispatcher
// until that moment passes.
app.MapGet("/outbox/{outboxId:guid}", async (
	Guid outboxId,
	IOutboxStore store,
	CancellationToken cancellationToken) =>
{
	// partitionKey is null for SQL Server. The Cosmos sample passes a real value, because there
	// a point read without the partition key is not possible.
	var message = await store.GetAsync(outboxId, partitionKey: null, cancellationToken);

	return message is null
		? Results.NotFound()
		: Results.Ok(Describe(message));
});

// The dead-letter queue. The library deliberately exposes no query API for this - an operator
// investigating a backlog uses SQL - so the sample reads the table directly, which is what you
// would really do.
app.MapGet("/outbox/dead-lettered", async (CancellationToken cancellationToken) =>
{
	await using var connection = new SqlConnection(connectionString);
	await connection.OpenAsync(cancellationToken);
	await using var command = connection.CreateCommand();
	command.CommandText = """
		SELECT OutboxId, EventId, Destination, EventType, AttemptCount, LastError,
		       CreatedAt, LastAttemptAt, DeadLetteredAt
		FROM outbox.OutboxMessages
		WHERE [Status] = @deadLettered
		ORDER BY DeadLetteredAt DESC;
		""";
	command.Parameters.Add("@deadLettered", SqlDbType.TinyInt).Value = (byte)OutboxStatus.DeadLettered;

	var rows = new List<object>();
	await using var reader = await command.ExecuteReaderAsync(cancellationToken);
	while (await reader.ReadAsync(cancellationToken))
	{
		rows.Add(new
		{
			OutboxId = reader.GetGuid(0),
			EventId = reader.GetGuid(1),
			Destination = reader.GetString(2),
			EventType = reader.GetString(3),
			AttemptCount = reader.GetInt32(4),
			LastError = reader.IsDBNull(5) ? null : reader.GetString(5),
			CreatedAt = reader.GetDateTimeOffset(6),
			LastAttemptAt = reader.IsDBNull(7) ? (DateTimeOffset?)null : reader.GetDateTimeOffset(7),
			DeadLetteredAt = reader.IsDBNull(8) ? (DateTimeOffset?)null : reader.GetDateTimeOffset(8),
		});
	}

	return Results.Ok(rows);
});

// Replay a dead-lettered record. Both identifiers are preserved, so the replay stays idempotent
// for a consumer that deduplicates on them.
app.MapPost("/outbox/{outboxId:guid}/requeue", async (
	Guid outboxId,
	IOutboxStore store,
	CancellationToken cancellationToken) =>
{
	var result = await store.RequeueAsync(
		outboxId,
		partitionKey: null,
		DateTimeOffset.UtcNow,
		resetAttemptCount: true,
		cancellationToken);

	// Requeue only applies to a dead-lettered record. Anything else - already delivered, still
	// retrying, or simply not there - leaves the row untouched rather than resurrecting it.
	return result.Applied
		? Results.Accepted($"/outbox/{outboxId}")
		: Results.Conflict(new
		{
			OutboxId = outboxId,
			Message = "Only a dead-lettered record can be requeued. This one is missing, or is in another state.",
		});
});

// The counters the health check is built on, which is usually what you actually want to look at.
app.MapGet("/outbox/stats", async (IOutboxStore store, CancellationToken cancellationToken) =>
	Results.Ok(await store.GetStatisticsAsync(cancellationToken)));

app.MapGet("/", () => Results.Ok(new
{
	Sample = "04-RetryAndDeadLetter",
	Description = "Shows what happens when delivery fails: bounded retry with exponential backoff, dead-lettering, and operator requeue that preserves both identifiers.",
	Endpoints = new[]
	{
		"GET  /                        this index",
		"GET  /health                  liveness probe",
		"GET  /health/outbox           backlog pressure as a health verdict",
		"POST /orders                  place an order (body: { tenantId, customerId, total })",
		"GET  /outbox/{outboxId}       inspect one record: status, attempts, next attempt, last error",
		"GET  /outbox/dead-lettered    records that exhausted their attempts",
		"POST /outbox/{outboxId}/requeue  replay a dead-lettered record",
		"GET  /outbox/stats            aggregate counters",
	},
	Hint = "POST http://localhost:5100/fail-next/3 on the receiver first, then place an order and watch GET /outbox/{outboxId}.",
}));

app.MapGet("/health", () => Results.Ok("healthy"));

// Healthy and Degraded both return 200; only Unhealthy returns 503. A single dead letter is
// enough to report Degraded, which is the default and is usually what you want.
app.MapHealthChecks("/health/outbox");

app.Run();

static object Describe(OutboxMessage message) => new
{
	message.OutboxId,
	message.EventId,
	message.Destination,
	message.EventType,

	// Serialized by name rather than as the underlying number, so the output reads as
	// "Failed" rather than "2".
	Status = message.Status.ToString(),
	message.AttemptCount,

	// Null unless the record is waiting to be retried. Until it passes, the dispatcher will not
	// claim the record no matter how often it polls.
	message.NextAttemptAt,
	message.LastError,
	message.CreatedAt,
	message.LastAttemptAt,
	message.DeliveredAt,
	message.DeadLetteredAt,
};

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
