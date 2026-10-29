using DNV.Outbox.Abstractions;
using DNV.Outbox.Core;
using DNV.Outbox.EntityFrameworkCore;
using DNV.Outbox.Hosting;
using DNV.Outbox.Http;
using DNV.Outbox.SqlServer;
using Microsoft.EntityFrameworkCore;
using Outbox.Samples.Domain;
using Outbox.Samples.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("Sales")
	?? throw new InvalidOperationException("ConnectionStrings:Sales is not configured.");

builder.Services.AddDbContext<SalesContext>(options => options.UseSqlServer(connectionString));

// 1. Two halves that meet at one table.
//    UseEntityFrameworkCore is the PRODUCER: it stages outbox rows in the application's change
//    tracker so they are saved by the application's own SaveChangesAsync.
//    UseSqlServer is the DISPATCHER side: the store that claims and completes those same rows
//    over ADO.NET. Both are pointed at outbox.OutboxMessages.
builder.Services.AddOutbox()
	.UseSqlServer(options =>
	{
		options.ConnectionString = connectionString;
		options.Schema = "outbox";
		options.Table = "OutboxMessages";
	})
	.UseEntityFrameworkCore<SalesContext>()
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

// 2. Unlike sample 01, this sample does NOT call SqlOutboxSchemaInitializer. The outbox table is
//    part of the EF model thanks to ApplyOutboxConfiguration, so one migration creates the
//    business tables and the outbox table together.
await using (var scope = app.Services.CreateAsyncScope())
{
	await scope.ServiceProvider.GetRequiredService<SalesContext>().Database.MigrateAsync();
}

// 3. The whole point of the sample: business write and outbox write in ONE SaveChangesAsync.
app.MapPost("/orders", async (
	PlaceOrderRequest request,
	SalesContext context,
	IOutbox outbox,
	CancellationToken cancellationToken) =>
{
	var order = Order.Place(request.TenantId, request.CustomerId, request.Total);

	context.Orders.Add(new OrderRecord
	{
		Id = order.Id,
		TenantId = order.TenantId,
		CustomerId = order.CustomerId,
		Total = order.Total,
		Currency = order.Currency,
		PlacedAt = order.PlacedAt,
	});

	// The producer only adds entities to the change tracker. There is no SavingChanges
	// interceptor, so the application keeps full control of its transaction.
	var messages = await outbox.EnqueueAsync(
		order.ToIntegrationEvent(),
		new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
		cancellationToken);

	// SaveChangesAsync is the atomic boundary: business rows and outbox rows in one transaction.
	await context.SaveChangesAsync(cancellationToken);

	return Results.Ok(new
	{
		order.Id,
		OutboxIds = messages.Select(m => m.OutboxId),
		EventId = messages[0].EventId,
	});
});

// 4. The other half of the migration story. Use this when an EF application ADOPTS an outbox
//    table that script 001 already created outside EF: the script writes a history row so EF
//    knows not to create the table again. It is deliberately excluded from the automatic script
//    set, because writing to __EFMigrationsHistory is a decision about the application's
//    migration history, not about the outbox.
app.MapGet("/baseline-script", () => Results.Text(
	SqlOutboxSchemaInitializer.GetBaselineScript(
		schema: "outbox",
		table: "OutboxMessages",
		migrationId: "20260101000000_AdoptExistingOutbox",
		productVersion: "10.0.12"),
	"text/plain"));

// A browsable index, so hitting the bare port in a browser explains the sample rather than 404ing.
app.MapGet("/", () => Results.Ok(new
{
	Sample = "02-EntityFrameworkCore",
	Description = "Produces outbox records through the application's own DbContext, so business rows and outbox rows are saved by one SaveChangesAsync, and dispatches them with the ADO.NET SQL Server store.",
	Endpoints = new[]
	{
		"GET  /                 this index",
		"GET  /health           liveness probe",
		"POST /orders           place an order (body: { tenantId, customerId, total })",
		"GET  /baseline-script  the manual script for adopting an outbox table EF did not create",
	},
	Receiver = builder.Configuration["Outbox:ReceiverEndpoint"],
	Hint = "POST /orders from sample.http, then browse the receiver at http://localhost:5100 to see what was delivered.",
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record PlaceOrderRequest(string TenantId, string CustomerId, decimal Total);
