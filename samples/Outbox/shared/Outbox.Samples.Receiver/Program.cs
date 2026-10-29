using System.Collections.Concurrent;

// An HTTP sink for outbox deliveries.
//
// It records what it received so a verify.ps1 can assert on it, and it can be told to fail a
// number of times on demand so the retry and dead-letter samples have something to retry against.

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var deliveries = new ConcurrentQueue<Delivery>();
var failuresRemaining = 0;

// The destination endpoint. Returns 500 while a forced-failure budget remains, so the
// dispatcher sees a transient failure and retries.
app.MapPost("/events", async (HttpRequest request) =>
{
	using var reader = new StreamReader(request.Body);
	var body = await reader.ReadToEndAsync();

	string? Header(string name) =>
		request.Headers.TryGetValue(name, out var value) ? value.ToString() : null;

	var delivery = new Delivery(
		OutboxId: Header("x-outbox-id"),
		EventId: Header("x-event-id"),
		EventType: Header("x-event-type"),
		EventVersion: Header("x-event-version"),
		Destination: Header("x-outbox-destination"),
		Attempt: Header("x-outbox-attempt"),
		TraceParent: Header("traceparent"),
		Body: body,
		ReceivedAt: DateTimeOffset.UtcNow);

	// Record the attempt even when it is about to be rejected, so the retry sample can show
	// every attempt rather than only the successful one.
	deliveries.Enqueue(delivery);

	if (Interlocked.Decrement(ref failuresRemaining) >= 0)
	{
		app.Logger.LogWarning(
			"Rejecting outbox {OutboxId} attempt {Attempt} (forced failure)",
			delivery.OutboxId,
			delivery.Attempt);

		return Results.StatusCode(StatusCodes.Status500InternalServerError);
	}

	// Decrement overshoots below zero once the budget is spent; clamp it back.
	Interlocked.CompareExchange(ref failuresRemaining, 0, -1);

	app.Logger.LogInformation(
		"Received outbox {OutboxId} event {EventId} type {EventType} attempt {Attempt} traceparent {TraceParent}",
		delivery.OutboxId,
		delivery.EventId,
		delivery.EventType,
		delivery.Attempt,
		delivery.TraceParent);

	return Results.NoContent();
});

// Everything received so far, for assertions.
app.MapGet("/deliveries", () => Results.Ok(deliveries.ToArray()));

// Distinct successful outbox ids, which is what "no double delivery" is asserted against.
app.MapGet("/deliveries/summary", () =>
{
	var all = deliveries.ToArray();
	return Results.Ok(new
	{
		Total = all.Length,
		DistinctOutboxIds = all.Select(d => d.OutboxId).Distinct().Count(),
		DistinctEventIds = all.Select(d => d.EventId).Distinct().Count(),
	});
});

app.MapDelete("/deliveries", () =>
{
	deliveries.Clear();
	Interlocked.Exchange(ref failuresRemaining, 0);
	return Results.NoContent();
});

// Reject the next n deliveries with 500 so the dispatcher retries them.
app.MapPost("/fail-next/{count:int}", (int count) =>
{
	Interlocked.Exchange(ref failuresRemaining, count);
	return Results.Ok(new { FailuresRemaining = count });
});

// A browsable index, so hitting the bare port in a browser explains the receiver rather than 404ing.
app.MapGet("/", () => Results.Ok(new
{
	Service = "Outbox.Samples.Receiver",
	Description = "Shared HTTP sink for outbox deliveries. Records what it received so verify.ps1 can assert on it, and can be told to fail on demand so retry samples have something to retry against.",
	Endpoints = new[]
	{
		"GET    /                    this index",
		"GET    /health              liveness probe",
		"POST   /events              the outbox destination (the dispatcher posts here)",
		"GET    /deliveries          everything received so far",
		"GET    /deliveries/summary  totals and distinct outbox/event ids",
		"DELETE /deliveries          reset the recorded deliveries and the failure budget",
		"POST   /fail-next/{count}   reject the next {count} deliveries with HTTP 500",
	},
}));

app.MapGet("/health", () => Results.Ok("healthy"));

app.Run();

internal sealed record Delivery(
	string? OutboxId,
	string? EventId,
	string? EventType,
	string? EventVersion,
	string? Destination,
	string? Attempt,
	string? TraceParent,
	string Body,
	DateTimeOffset ReceivedAt);
