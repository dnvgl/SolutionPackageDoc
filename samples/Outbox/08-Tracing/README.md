# Sample 08 — W3C trace context

The outbox breaks a request into two halves that run minutes apart, in different processes. This
sample shows that they still belong to the same trace.

It is sample 01 plus OpenTelemetry. The store, the destination and the receiver are unchanged —
the subject is what happens to `traceparent`.

---

## 1. What this demonstrates

- **The ambient trace is captured at enqueue time.** `Activity.Current` — the server span ASP.NET
  Core created for the incoming request — is persisted in the outbox row, inside the same
  transaction as the business data.
- **It is restored at dispatch time.** The dispatcher, running later in a background service that
  never saw the request, starts its span with the persisted context as parent. The trace id
  survives the database round trip.
- **The library's span is a plain `ActivitySource`.** `DNV.Outbox` — no OpenTelemetry dependency
  in the library at all. One `AddSource` line connects it.
- **An explicit `OutboxTraceContext` overrides the ambient one**, for the cases where
  `Activity.Current` is not the parent you want.

The smoke test asserts the trace id end to end and asserts the dispatch span's **parent** is the
span that was persisted. Those are the claims; everything else is narration.

---

## 2. Prerequisites

| What | Version used here | Notes |
| --- | --- | --- |
| .NET SDK | 10.0.402 | |
| SQL Server | any | `.\SQLEXPRESS` by default |
| `sqlcmd` | any | ships with the SQL Server Client SDK |

OpenTelemetry comes from NuGet (`OpenTelemetry.Extensions.Hosting` 1.20.1 and the ASP.NET Core,
HttpClient and console-exporter packages). Nothing else to install.

---

## 3. Cost

Nothing. Everything runs locally, and the traces go to the console rather than to a backend.

---

## 4. Setup

```powershell
$server = '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample08') IS NULL CREATE DATABASE OutboxSample08;"
```

The `verify.ps1` smoke test creates this database itself if it is missing, so this step is only
needed when running the sample by hand.

The outbox schema is created by the sample on startup.

---

## 5. Run

```powershell
cd samples\Outbox\08-Tracing
.\verify.ps1
```

```
Checking SQL Server...
Building...
Starting receiver...
Starting sample API (console exporter -> traces.log)...

Phase 1: the ambient trace survives the hand-off...
  trace 6d4b18e24a37a2dd0302f1e9f0cae406: caller span b53af93ebbb83d73 -> persisted span 2ddad1e36a5fffa0 -> receiver span b6807f9fde218d31.

Phase 2: an explicit trace context overrides the ambient one...
  trace a2b12d16514452de4cbb32c7422d608f was persisted verbatim and delivered, in spite of the ambient trace c890c7ff0845f2048b92e98505ca10b7.

Phase 3: the dispatch span is exported as a child of the persisted span...
  'outbox publish receiver' was exported under trace 6d4b18e24a37a2dd0302f1e9f0cae406, parented on the persisted span 2ddad1e36a5fffa0.

PASS: the trace started by the caller survived a database round trip and an asynchronous hand-off in another process - the receiver saw the same trace id, the explicit override was honoured, and the dispatch span was exported as a child of the span that was persisted with the order.
```

The trace ids differ on every run — they are generated per run so the assertions cannot pass by
accident.

To drive it by hand:

```powershell
# Terminal 1 — the destination
cd samples\Outbox
dotnet run --project shared\Outbox.Samples.Receiver --urls http://localhost:5100

# Terminal 2 — the sample. Spans go to stdout, so keep this terminal visible.
cd samples\Outbox
dotnet run --project 08-Tracing --urls http://localhost:5008
```

---

## 6. What you should see

### Place an order inside a trace

```powershell
$tp = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
Invoke-RestMethod -Method Post -NoProxy http://localhost:5008/orders `
  -ContentType application/json -Headers @{ traceparent = $tp } `
  -Body '{"tenantId":"acme","customerId":"cust-ambient","total":42.00}'
```

```json
{
  "id": "01a1c4e5-b50f-7b4e-b561-46736b953a1d",
  "eventId": "01a1c4e5-b51e-7b71-bf02-70887f2eb410",
  "outboxId": "01a1c4e5-b523-7bf9-a177-92ea6ef5d282",
  "traceParent": "00-4bf92f3577b34da6a3ce929d0e0e4736-c5c323d9b9f19ff3-01"
}
```

The trace id is the caller's. The **span** id is not: `c5c323d9b9f19ff3` is the server span ASP.NET
Core created for this request, and `00f067aa0ba902b7` is its parent. The outbox captures
`Activity.Current`, which is that server span.

### The producer's span

```
Activity.TraceId:            4bf92f3577b34da6a3ce929d0e0e4736
Activity.SpanId:             c5c323d9b9f19ff3
Activity.TraceFlags:         Recorded
Activity.ParentSpanId:       00f067aa0ba902b7
Activity.DisplayName:        POST /orders
Activity.Kind:               Server
Activity.StartTime:          2026-11-10T09:59:10.8022278Z
Activity.Duration:           00:00:00.0962612
Instrumentation scope (ActivitySource):
    Name: Microsoft.AspNetCore
```

The request is over in 96 ms. Nothing has been delivered yet.

### The dispatcher's span, started later by a different thread in a different service

```
Activity.TraceId:            4bf92f3577b34da6a3ce929d0e0e4736
Activity.SpanId:             9fe8229b4f2c55b8
Activity.TraceFlags:         Recorded
Activity.ParentSpanId:       c5c323d9b9f19ff3
Activity.DisplayName:        outbox publish receiver
Activity.Kind:               Producer
Activity.StartTime:          2026-11-10T09:59:10.9651171Z
Activity.Duration:           00:00:02.0889438
Activity.Tags:
    outbox.id: 01a1c4e5-b523-7bf9-a177-92ea6ef5d282
    outbox.event_id: 01a1c4e5-b51e-7b71-bf02-70887f2eb410
    outbox.destination: receiver
    outbox.event_type: OrderPlaced
    outbox.attempt: 1
Instrumentation scope (ActivitySource):
    Name: DNV.Outbox
```

This is the whole sample in one block:

- same `TraceId` as the request, though this span was started by a `BackgroundService` that never
  saw it;
- `ParentSpanId` is the request's span id, **read back out of a database column**;
- `ActivitySource` is `DNV.Outbox`;
- the tags carry both identifiers and the attempt number, so a retry is visible as a second span
  rather than a mystery.

The gap here is small — the dispatcher polls every second and the record was waiting. Slow the
poll interval down, or stop the receiver for a minute, and the gap grows to whatever the backlog
is. The parent link does not care.

> **There is no "enqueue" span.** The library emits a span on **dispatch** only. The producer-side
> span is the incoming request span your ASP.NET Core instrumentation already creates, which is
> exactly what you want to be the parent. Do not go hunting for a span that does not exist.

### The outbox row

```powershell
Invoke-RestMethod -NoProxy http://localhost:5008/outbox/01a1c4e5-b523-7bf9-a177-92ea6ef5d282
```

```json
{
  "outboxId": "01a1c4e5-b523-7bf9-a177-92ea6ef5d282",
  "eventId": "01a1c4e5-b51e-7b71-bf02-70887f2eb410",
  "eventType": "OrderPlaced",
  "status": "Delivered",
  "attemptCount": 1,
  "traceParent": "00-4bf92f3577b34da6a3ce929d0e0e4736-c5c323d9b9f19ff3-01",
  "traceState": null,
  "createdAt": "2026-11-10T17:59:10.8831452+08:00",
  "deliveredAt": "2026-11-10T17:59:13.0425455+08:00"
}
```

### What the receiver saw

```json
[
  {
    "outboxId": "01a1c4e5-b523-7bf9-a177-92ea6ef5d282",
    "eventId": "01a1c4e5-b51e-7b71-bf02-70887f2eb410",
    "eventType": "OrderPlaced",
    "attempt": "1",
    "traceParent": "00-4bf92f3577b34da6a3ce929d0e0e4736-bc390ccc12f2ea02-01",
    "receivedAt": "2026-11-10T17:59:13.0329277+08:00"
  }
]
```

Same trace, third span id. See section 7 — this one catches people out.

---

## 7. How it works

### Registration

```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService("outbox-sample-08"))
    .WithTracing(tracing => tracing
        .AddSource(OutboxTelemetry.ActivitySourceName)   // "DNV.Outbox"
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddConsoleExporter());
```

`AddSource("DNV.Outbox")` is the only outbox-specific line. The library depends on
`System.Diagnostics.ActivitySource`, part of the base class library — not on OpenTelemetry — so
any listener works, and an application with no listener pays nothing.

Metrics are published under the same `DNV.Outbox` name
(`OutboxTelemetry.MeterName`): delivery counts, durations, backlog age and dead-letter counts. Add
`.WithMetrics(m => m.AddMeter(OutboxTelemetry.MeterName))` to collect them.

### Capture, then restore

Enqueue calls `TraceContextAccessor.Capture`, which takes `Activity.Current.Id` when the activity
uses the W3C id format, and stores it in the row's `TraceParent` and `TraceState` columns —
**inside the business transaction**, so a trace context cannot survive a rollback or go missing
from a committed event.

Dispatch calls `TraceContextAccessor.TryParseParent`, which parses the persisted value with
`isRemote: true` and uses it as the parent of the `outbox publish {destination}` span. A malformed
value is logged and ignored: an unreadable trace must never turn a real delivery into a failure.

Note the sampled flag (`-01`) rides along with the context. A record enqueued inside a sampled
trace produces a sampled dispatch span hours later, which is what you want — otherwise the half of
the trace you care about is the half that gets dropped.

### The three span ids, and why the receiver sees a third one

```
00f067aa0ba902b7  the caller's span            (sent in the traceparent header)
c5c323d9b9f19ff3  POST /orders, Server         <- persisted in the outbox row
9fe8229b4f2c55b8  outbox publish receiver      <- parent: c5c323d9b9f19ff3, from the database
bc390ccc12f2ea02  POST (HttpClient), Client    <- what the receiver's traceparent header shows
```

`HttpOutboxDestination` sets the `traceparent` header from the persisted value. But when something
instruments `HttpClient` — as `AddHttpClientInstrumentation()` does here — the HTTP stack creates
a client span and injects **its** context into the outgoing request. The receiver therefore sees
the client span, not the persisted one.

This is correct, and it is better: the chain `request → outbox publish → HTTP POST → receiver` is
unbroken, and each hop is a real span. **The trace id is the invariant; the span id moves on by
one link.** Without HttpClient instrumentation (sample 01) the persisted value is what arrives
verbatim, because nothing overwrites it.

So: assert on trace ids, not on traceparent strings.

### The explicit override

```csharp
new OutboxEnqueueRequest(["receiver"], nameof(OrderPlaced))
{
    TraceContext = new OutboxTraceContext(traceParent, traceState),
}
```

Leave `TraceContext` null and the ambient context is captured — the right default for almost
everything. Supply it when `Activity.Current` is not the parent you want:

- replaying an archived or dead-lettered message and wanting the original trace, not the replay;
- a batch job continuing a trace that began in another system;
- a message consumed from a broker whose context you want to continue rather than branch from.

The sample exposes it as an optional `traceParent` field on the request body so both paths can be
exercised. A malformed value throws `OutboxValidationException` at enqueue time rather than being
silently dropped — a bad trace context is a bug in the caller, and it is cheaper to find it here.

An explicit context is persisted **verbatim**, span id included:

```json
{ "outboxId": "01a1c4e6-473a-76e4-a349-f04aa8be3070",
  "traceParent": "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01" }
```

...even though the request that carried it was itself in trace
`11111111111111111111111111111111`.

### If the trace id you sent does not arrive

`sample.http` sets a `traceparent` header explicitly. Some HTTP clients — anything built on .NET's
`HttpClient` with diagnostics enabled, which includes Visual Studio's `.http` runner — **add their
own `traceparent` as well**, because the injection appends rather than replaces. The request then
carries two:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
traceparent: 00-9999999999999999999999999999aaaa-8888888888888888-01
```

ASP.NET Core will not guess which one you meant. It treats the pair as unparseable, ignores both
and starts a **brand new root trace** — so the outbox faithfully persists a trace id you have never
seen, and the receiver reports that same unfamiliar id. Nothing is broken: the trace you sent never
reached the application.

`GET /trace` diagnoses it directly:

```json
{
  "incomingTraceParent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01,00-9999999999999999999999999999aaaa-8888888888888888-01",
  "incomingTraceParentCount": 2,
  "traceId": "aae97dd7a97ee2895593d48f821a99b2",
  "diagnosis": "2 traceparent headers were sent. ASP.NET Core cannot parse that, so it started a new root trace and the trace id you sent was lost. ..."
}
```

`incomingTraceParentCount` must be `1`. If it is `2`, use a client that does not instrument itself
— `curl.exe` and `Invoke-RestMethod` both send exactly what you give them, and both are used
throughout this README — or let the client supply the trace and read the id back out of the
response rather than choosing it yourself.

It is also a sound argument for the explicit `TraceContext` override: a trace context passed in the
**body** cannot be rewritten by transport-level instrumentation.

### Reading the trace in something other than a console

The console exporter is used here because it needs nothing installed. Swap it for
`.AddOtlpExporter()` and point it at Jaeger, Zipkin or Azure Monitor to see the gap as a gap — a
request span, then a long pause, then the publish span, in one waterfall.

---

## 8. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Cannot open database "OutboxSample08"` | Run the `sqlcmd` in section 4. |
| The outbox record has no `traceParent` | No `ActivityListener` is registered, so `Activity.Current` is null. Registering OpenTelemetry (or any listener) is what creates the activity. |
| No spans in the console at all | The incoming `traceparent` ended in `-00`, meaning "not sampled". The default parent-based sampler honours that and drops everything. Use `-01`. |
| `outbox publish` spans appear but `POST /orders` does not | `AddAspNetCoreInstrumentation()` is missing. |
| `POST /orders` spans appear but `outbox publish` does not | `AddSource("DNV.Outbox")` is missing. |
| The receiver's `traceparent` is not the persisted one | Expected. See section 7 — HttpClient instrumentation re-injects it. The trace id is unchanged. |
| The trace id in the database is **neither** the one I sent nor anything I recognise | Your HTTP client sent **two** `traceparent` headers — yours plus one it injected. ASP.NET Core cannot parse that and starts a fresh root trace, losing yours. `GET /trace` with the same client reports the header count and says so. See section 7. |
| `405 Method Not Allowed` in the dispatcher log | `Outbox:ReceiverEndpoint` must point at `/events`, not at `/deliveries` (which is the query endpoint). |
| `traces.log` is empty | The console exporter batches; give it a second or two. |

---

## 9. Teardown

```powershell
$server = '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample08') IS NOT NULL DROP DATABASE OutboxSample08;"
Remove-Item samples\Outbox\08-Tracing\traces.log -ErrorAction SilentlyContinue
```
