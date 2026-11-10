using System.Collections.Concurrent;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

var pubSubName = builder.Configuration["Dapr:PubSubName"]!;
var topicName = builder.Configuration["Dapr:TopicName"]!;

var received = new ConcurrentQueue<ReceivedMessage>();
var subscriptionFetched = 0;

var app = builder.Build();

// The subscription endpoint. The sidecar calls this once at startup and subscribes on the app's
// behalf, which is why the app itself needs no broker credentials and no broker SDK.
app.MapGet("/dapr/subscribe", (ILogger<Program> logger) =>
{
	Interlocked.Exchange(ref subscriptionFetched, 1);
	logger.LogInformation("Sidecar asked for subscriptions; advertising {PubSub}/{Topic}.", pubSubName, topicName);

	return Results.Ok(new[]
	{
		new { pubsubname = pubSubName, topic = topicName, route = "/order-events" },
	});
});

// The delivery endpoint. Dapr posts a CloudEvents envelope here.
app.MapPost("/order-events", async (HttpRequest request, ILogger<Program> logger) =>
{
	using var document = await JsonDocument.ParseAsync(request.Body);
	var envelope = document.RootElement;

	// The outbox published the event as JSON, and DaprOutboxDestination parses it before
	// publishing, so `data` is the event object itself rather than a string containing JSON.
	// That is what lets the fields below be read directly.
	var data = envelope.TryGetProperty("data", out var d) ? d : default;

	var message = new ReceivedMessage(
		CloudEventId: Text(envelope, "id"),
		CloudEventType: Text(envelope, "type"),
		TraceParent: Text(envelope, "traceparent"),
		OrderId: data.ValueKind == JsonValueKind.Object ? Text(data, "orderId") : null,
		CustomerId: data.ValueKind == JsonValueKind.Object ? Text(data, "customerId") : null,
		ReceivedAt: DateTimeOffset.UtcNow,
		RawData: data.ValueKind == JsonValueKind.Undefined ? null : data.GetRawText());

	received.Enqueue(message);

	logger.LogInformation(
		"Received CloudEvent {CloudEventId} type {CloudEventType} for order {OrderId} traceparent {TraceParent}",
		message.CloudEventId,
		message.CloudEventType,
		message.OrderId,
		message.TraceParent);

	// 200 with no body is the Dapr acknowledgement. Returning an error, or a body of
	// { "status": "RETRY" }, would make the sidecar redeliver - which is exactly the redelivery
	// the CloudEvents id is there to let a real subscriber absorb.
	return Results.Ok();
});

app.MapGet("/received", () => Results.Ok(received.ToArray()));

app.MapDelete("/received", () =>
{
	received.Clear();
	return Results.NoContent();
});

// Lets a test wait for the sidecar to finish wiring the subscription. Publishing before this is
// true means publishing to a topic nobody is subscribed to yet, and the message is simply gone.
app.MapGet("/subscription-status", () => Results.Ok(new
{
	Subscribed = Volatile.Read(ref subscriptionFetched) == 1,
	PubSub = pubSubName,
	Topic = topicName,
}));

app.MapGet("/", () => Results.Ok(new
{
	Sample = "07-Dapr (subscriber)",
	Description = "A plain HTTP app that the Dapr sidecar subscribes on behalf of, and that records the CloudEvents it receives.",
	Endpoints = new[]
	{
		"GET    /                     this index",
		"GET    /health               liveness probe",
		"GET    /dapr/subscribe       subscriptions, called by the sidecar at startup",
		"POST   /order-events         delivery endpoint for the sidecar",
		"GET    /received             everything received so far",
		"DELETE /received             clear the recorded messages",
		"GET    /subscription-status  whether the sidecar has fetched the subscription yet",
	},
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

static string? Text(JsonElement element, string property) =>
	element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
		? value.GetString()
		: null;

internal sealed record ReceivedMessage(
	string? CloudEventId,
	string? CloudEventType,
	string? TraceParent,
	string? OrderId,
	string? CustomerId,
	DateTimeOffset ReceivedAt,
	string? RawData);
