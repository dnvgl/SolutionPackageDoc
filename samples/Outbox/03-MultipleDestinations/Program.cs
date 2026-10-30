using System.Data.Common;
using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.Hosting;
using DNV.Outbox.Http;
using DNV.Outbox.SqlServer;
using Microsoft.Data.SqlClient;
using Outbox.Samples.Domain;
using Outbox.Samples.MultipleDestinations;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

// Relative paths are resolved against the content root so the sample behaves the same whether it
// is started by verify.ps1 or by dotnet run from another directory.
var auditDirectory = Path.Combine(
	builder.Environment.ContentRootPath,
	builder.Configuration["Outbox:AuditDirectory"] ?? "audit");

// 1. Three destinations. Two share a transport (HTTP) and differ only by endpoint; the third is
//    a transport this sample wrote itself. The producer below names all three and knows nothing
//    about any of this.
builder.Services.AddOutbox()
	.UseSqlServer(options =>
	{
		options.ConnectionString = connectionString;
		options.Schema = "outbox";
		options.Table = "OutboxMessages";
	})
	.AddHttpDestination("receiver-a", http =>
	{
		http.Endpoint = new Uri(builder.Configuration["Outbox:ReceiverAEndpoint"]!);
	})
	.AddHttpDestination("receiver-b", http =>
	{
		http.Endpoint = new Uri(builder.Configuration["Outbox:ReceiverBEndpoint"]!);
	})
	// AddDestination registers the logical name AND the transport serving it. Registering a
	// transport already registers its name, so never call AddDestination(name) for a name a
	// transport registers - duplicate names throw.
	.AddDestination("audit-file", _ => new FileDestination("audit-file", auditDirectory))
	.AddDispatcher(dispatcher =>
	{
		// Aggressive for a demo. Production defaults are far less chatty.
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

// 2. One enqueue, three deliveries, still one transaction.
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

	// Naming three destinations produces THREE rows from ONE event. They share an EventId and
	// a payload; each gets its own OutboxId, status, attempt count and retry schedule, so a
	// failing destination never holds up a healthy one.
	var messages = await outbox.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest(
			["receiver-a", "receiver-b", "audit-file"],
			eventType: nameof(OrderPlaced),
			eventVersion: 1),
		cancellationToken);

	await transaction.CommitAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		EventId = messages[0].EventId,
		OutboxIds = messages.Select(m => m.OutboxId),
		Deliveries = messages.Select(m => new { m.Destination, m.OutboxId }),
	});
});

// A browsable index, so hitting the bare port in a browser explains the sample rather than 404ing.
app.MapGet("/", () => Results.Ok(new
{
	Sample = "03-MultipleDestinations",
	Description = "Fans one integration event out to three destinations - two HTTP receivers and a custom file transport - as three independently retried rows sharing one event id.",
	Endpoints = new[]
	{
		"GET  /                 this index",
		"GET  /health           liveness probe",
		"POST /orders           place an order (body: { tenantId, customerId, total })",
		"GET  /destinations     the registered destination names",
	},
	AuditDirectory = auditDirectory,
	Hint = "POST /orders from sample.http, then compare http://localhost:5111/deliveries, http://localhost:5112/deliveries and the audit directory.",
}));

// Shows that a destination is a logical NAME resolved to a transport at startup. The producer
// above names strings; nothing in it knows that two of these are HTTP and one writes files.
app.MapGet("/destinations", (IEnumerable<IOutboxDestination> destinations) => Results.Ok(
	destinations.Select(d => new { d.Name, Transport = d.GetType().Name })));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
