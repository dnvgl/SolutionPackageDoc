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

// 1. Register the outbox: a store (SQL Server), a destination (HTTP) and the dispatcher.
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
		// Aggressive for a demo. Production defaults are far less chatty.
		dispatcher.PollInterval = TimeSpan.FromSeconds(1);
		dispatcher.BatchSize = 20;
	});

var app = builder.Build();

// 2. Create the business table and the outbox table. EnsureCreatedAsync is for development;
//    production applies the scripts from a deployment pipeline.
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

// 3. The whole point of the sample: business write and outbox write in ONE transaction.
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

	// The producer is bound to the transaction the caller already owns. There is no unbound
	// IOutbox, because an outbox write outside the business transaction would break atomicity.
	var outbox = sessionFactory.ForTransaction(connection, transaction);

	var messages = await outbox.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
		cancellationToken);

	// Business row and outbox row commit together, or neither does.
	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		OutboxIds = messages.Select(m => m.OutboxId),
		EventId = messages[0].EventId,
	});
});

// A browsable index, so hitting the bare port in a browser explains the sample rather than 404ing.
app.MapGet("/", () => Results.Ok(new
{
	Sample = "01-SqlServer-Http",
	Description = "Writes an order and its outbox record in one SQL Server transaction, then a background dispatcher delivers the integration event over HTTP.",
	Endpoints = new[]
	{
		"GET  /                 this index",
		"GET  /health           liveness probe",
		"POST /orders           place an order (body: { tenantId, customerId, total })",
	},
	Receiver = builder.Configuration["Outbox:ReceiverEndpoint"],
	Hint = "POST /orders from sample.http, then browse the receiver at http://localhost:5100 to see what was delivered.",
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
