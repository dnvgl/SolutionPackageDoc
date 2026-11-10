# Sample 07 — Dapr Pub/Sub

Two applications, each behind its own Dapr sidecar. The publisher commits orders and their outbox
records in one SQL Server transaction; the dispatcher publishes them through a Dapr pub/sub
component; the subscriber receives them as CloudEvents.

Neither application contains a line of broker-specific code. The broker is a YAML file.

---

## 1. What this demonstrates

- **Dapr as an outbox destination.** `AddDaprDestination` publishes through the sidecar's HTTP
  API, so the application never holds broker credentials or a broker SDK.
- **The outbox id becomes the CloudEvents id.** Dapr delivers at least once and will redeliver on
  failure. Because the outbox guarantees the same `OutboxId` on every retry, stamping it as
  `cloudevent.id` gives a subscriber a stable key to deduplicate on. The smoke test asserts this
  rather than taking it on trust.
- **Trace context survives the broker.** The `traceparent` captured when the order was placed is
  persisted in the outbox row and arrives on the CloudEvent, so the publish and the receive are
  the same distributed trace.
- **The published body is the event, not a string containing the event.** The destination parses
  the persisted payload into JSON before publishing, so a subscriber reads `data.orderId`
  directly.
- **Swapping brokers is a configuration change.** `components/pubsub.yaml` names Redis here;
  pointing it at Azure Service Bus changes no C#.

This is the same store as samples 01, 03, 04 and 05 — the point of interest is the destination.

---

## 2. Prerequisites

| What | Version used here | Notes |
| --- | --- | --- |
| .NET SDK | 10.0.402 | |
| SQL Server | any | `.\SQLEXPRESS` by default |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| Docker Desktop | any | only to host the Redis that `dapr init` installs |
| Dapr CLI | 1.16.5 | |
| Dapr runtime | 1.16.9 | installed by `dapr init` |

Check the last two:

```powershell
dapr --version
# CLI version: 1.16.5
# Runtime version: 1.16.9
```

If the runtime line is missing, run `dapr init` once (it needs Docker running). It creates the
`dapr_redis`, `dapr_placement`, `dapr_scheduler` and `dapr_zipkin` containers.

### The component name

The component is called **`order-pubsub`** and the topic **`order-events`**. The name appears in
three places and all three must agree: `components/pubsub.yaml` (`metadata.name`), and
`Dapr:PubSubName` in both applications' `appsettings.json`. A mismatch produces a 404 from the
sidecar on publish, not a startup error.

---

## 3. Cost

Nothing. Everything runs locally: SQL Server, and the Redis container that `dapr init` already
installed.

---

## 4. Setup

```powershell
$server = '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample07') IS NULL CREATE DATABASE OutboxSample07;"
```

The outbox schema itself is created by the publisher on startup — no migration step.

Make sure Redis is up:

```powershell
docker start dapr_redis dapr_placement dapr_scheduler
docker ps --filter name=dapr_redis
```

---

## 5. Run

The scripted route, which asserts everything in section 1 and cleans up after itself:

```powershell
cd samples\Outbox\07-Dapr
.\verify.ps1
```

```
Checking the Dapr CLI and runtime...
  CLI version: 1.16.5  | Runtime version: 1.16.9
Checking Redis (the pub/sub component backing store)...
Checking SQL Server...
Building...
Starting both apps and their sidecars (dapr run -f dapr.yaml)...
Waiting for the subscription to be registered...

Phase 1: placing 3 orders...
  3 orders committed with their outbox records.

Phase 2: waiting for the subscriber...
  3 messages, 3 distinct outbox ids.

Phase 3: checking the CloudEvent carries the outbox identity...
  Every CloudEvent id equals its outbox id, typed 'OrderPlaced', with a traceparent and a parsed body.

PASS: 3 orders committed transactionally in SQL Server were published through Dapr pub/sub and received by a separate subscriber process as 3 distinct CloudEvents, each carrying its outbox id so a redelivery can be deduplicated.
```

To drive it by hand, start both applications and both sidecars with one command:

```powershell
cd samples\Outbox\07-Dapr
dotnet build .\Publisher
dotnet build .\Subscriber
dapr run -f .\dapr.yaml
```

Then use `sample.http`, or the requests in section 6, from another terminal. `Ctrl+C` stops
everything; `dapr stop -f .\dapr.yaml` from another terminal does the same thing more politely.

---

## 6. What you should see

### Startup

```
Validating config and starting app "order-publisher"
Started Dapr with app id "order-publisher". HTTP Port: 3507. gRPC Port: 63798
Validating config and starting app "order-subscriber"
== APP - order-publisher == info: DNV.Outbox.SqlServer.SqlOutboxSchemaInitializer[2001]
== APP - order-publisher ==       Applied outbox schema script 001_CreateOutbox.sql.
== APP - order-publisher == info: DNV.Outbox.Hosting.OutboxDispatcher[3101]
== APP - order-publisher ==       Outbox dispatcher CNSGHL25100648:81856:180067f6 started with a batch size of 20.
Started Dapr with app id "order-subscriber". HTTP Port: 3517. gRPC Port: 57478
== APP - order-subscriber == info: Program[0]
== APP - order-subscriber ==       Sidecar asked for subscriptions; advertising order-pubsub/order-events.
```

That last line is the sidecar calling `GET /dapr/subscribe` on the subscriber. **Until it appears,
publishing goes nowhere** — there is no subscription yet, and Redis pub/sub does not retain
messages for subscribers that have not arrived. `verify.ps1` waits for
`GET /subscription-status` to report `true` before placing its first order, and so should you:

```powershell
curl.exe --noproxy '*' http://localhost:5017/subscription-status
```

```json
{
  "subscribed": true,
  "pubSub": "order-pubsub",
  "topic": "order-events"
}
```

### Place an order

```powershell
Invoke-RestMethod -Method Post -NoProxy http://localhost:5007/orders `
  -ContentType application/json `
  -Body '{"tenantId":"acme","customerId":"cust-1","total":11.0}'
```

```json
{
  "id": "01a1bfb8-8e46-74f2-a030-745aeef2b7b3",
  "eventId": "01a1bfb8-8e4f-7ee0-9da4-607a74bfafc5",
  "outboxId": "01a1bfb8-8e56-7c33-9755-3984748b6004"
}
```

### The publish, a second later

```
== APP - order-publisher == info: System.Net.Http.HttpClient.billing.LogicalHandler[100]
== APP - order-publisher ==       Start processing HTTP request POST http://localhost:3507/v1.0/publish/order-pubsub/order-events?*
== APP - order-subscriber == info: Program[0]
== APP - order-subscriber ==       Received CloudEvent 01a1bfb8-8e56-7c33-9755-3984748b6004 type OrderPlaced for order 01a1bfb8-8e46-74f2-a030-745aeef2b7b3 traceparent 00-910eeaccf4719919c64d7b5598b81fd5-4052b46b69101768-00
== APP - order-publisher == info: System.Net.Http.HttpClient.billing.ClientHandler[101]
== APP - order-publisher ==       Received HTTP response headers after 2074.6451ms - 204
```

The publish goes to `localhost:3507` — the sidecar, on this machine — not to Redis. The
`204` is the sidecar's acknowledgement, which is what the dispatcher treats as a successful
delivery.

### The outbox record

```powershell
Invoke-RestMethod -NoProxy http://localhost:5007/outbox/01a1bfb8-8e56-7c33-9755-3984748b6004
```

```json
{
  "outboxId": "01a1bfb8-8e56-7c33-9755-3984748b6004",
  "eventId": "01a1bfb8-8e4f-7ee0-9da4-607a74bfafc5",
  "destination": "billing",
  "eventType": "OrderPlaced",
  "status": "Delivered",
  "attemptCount": 1,
  "traceParent": "00-910eeaccf4719919c64d7b5598b81fd5-4052b46b69101768-00",
  "createdAt": "2026-11-09T17:51:45.7501316+08:00",
  "deliveredAt": "2026-11-09T17:51:48.1739595+08:00",
  "lastError": null
}
```

### What the subscriber got

```powershell
Invoke-RestMethod -NoProxy http://localhost:5017/received
```

```json
[
  {
    "cloudEventId": "01a1bfb8-8e56-7c33-9755-3984748b6004",
    "cloudEventType": "OrderPlaced",
    "traceParent": "00-910eeaccf4719919c64d7b5598b81fd5-4052b46b69101768-00",
    "orderId": "01a1bfb8-8e46-74f2-a030-745aeef2b7b3",
    "customerId": "cust-1",
    "receivedAt": "2026-11-09T17:51:48.1688263+08:00",
    "rawData": "{\"currency\":\"USD\",\"customerId\":\"cust-1\",\"orderId\":\"01a1bfb8-8e46-74f2-a030-745aeef2b7b3\",\"placedAt\":\"2026-11-09T09:51:45.7348757+00:00\",\"tenantId\":\"acme\",\"total\":11.0}"
  }
]
```

Three things to compare against the two responses above:

| At the subscriber | In the outbox | |
| --- | --- | --- |
| `cloudEventId` `01a1bfb8-8e56-…6004` | `outboxId` `01a1bfb8-8e56-…6004` | identical — see section 7 |
| `traceParent` `00-910eeacc…1768-00` | `traceParent` `00-910eeacc…1768-00` | one trace across the broker |
| `orderId` `01a1bfb8-8e46-…b7b3` | the order's `id` | the body is the event itself |

---

## 7. How it works

### Registration

```csharp
builder.Services.AddDaprPubSubClient("billing", options =>
{
    options.PubSubName = "order-pubsub";
    options.TopicName = "order-events";
});

builder.Services.AddOutbox()
    .UseSqlServer(...)
    .AddDaprDestination("billing", dapr =>
    {
        dapr.ClientName = "billing";
        dapr.TopicName = "order-events";
        dapr.SendCloudEventId = true;
    })
    .AddDispatcher(...);
```

Two registrations, because they are two things: `AddDaprPubSubClient` creates a **named pub/sub
client** (a named `HttpClient` pointed at the sidecar), and `AddDaprDestination` creates an
**outbox destination** that publishes through it. `ClientName` is what joins them, and defaults to
the destination name.

The sidecar's address is never configured. `DaprPubSubOptions.HttpEndpoint` falls back to
`DAPR_HTTP_ENDPOINT`, then to `http://localhost:{DAPR_HTTP_PORT}` — both of which `dapr run` sets
for the process it starts. That is why the log above shows port 3507 without anybody naming it in
C#.

> **One client per application, in practice.** `AddDaprPubSubClient` registers the factory with
> `TryAddSingleton` and the factory applies its configure callback to *every* client it creates.
> Calling it twice with different options therefore silently gives both clients the **first**
> call's options. If you need several topics, use one client and set `TopicName` per destination,
> as this sample does.

### Why `SendCloudEventId` matters

Dapr guarantees at-least-once delivery between the sidecar and the subscriber. If the subscriber
returns an error, or the app restarts mid-handler, the sidecar redelivers. So the same business
event can legitimately arrive twice.

The outbox already guarantees that a retried delivery reuses the same `OutboxId` — that is its
idempotency contract. `SendCloudEventId = true` publishes that value as `cloudevent.id`, which
Dapr uses as the CloudEvents envelope id instead of generating a fresh one. The subscriber then
has a key that is stable across *both* layers of retry:

```csharp
// in the subscriber, in real code
if (!await seen.TryAddAsync(cloudEventId)) return Results.Ok();   // already handled
```

Had Dapr generated the id, every redelivery would carry a different one and deduplication would
have to fall back on the business payload.

The metadata the destination sends — all of it visible as `?metadata.*` query parameters on the
publish URL:

| Metadata key | Value |
| --- | --- |
| `cloudevent.id` | `OutboxId` (when `SendCloudEventId`) |
| `cloudevent.type` | `EventType` — `OrderPlaced` here |
| `cloudevent.traceparent` | the persisted W3C trace parent |
| `cloudevent.tracestate` | the persisted W3C trace state |
| `outboxEventId` | `EventId`, the business event's identity |
| `outboxEventVersion` | `EventVersion` |

Note the distinction the last two make visible: **`EventId` identifies the event, `OutboxId`
identifies one delivery of it to one destination.** Fan the same event out to three destinations
and you get one `EventId` and three `OutboxId`s — sample 03 shows that directly.

### The body is the event, not a string

The outbox stores the payload as JSON text. A naive destination would send that text as a JSON
string, and the subscriber would have to parse `data` a second time. `DaprOutboxDestination`
parses it into a `JsonElement` first, so the envelope's `data` is a real object:

```json
"data": { "orderId": "01a1bfb8-…", "customerId": "cust-1", "total": 11.0, "currency": "USD" }
```

A payload that is not valid JSON is classified `Permanent` rather than retried — it will never
become valid, so retrying it only delays the dead letter.

### The subscriber has no Dapr dependency

`Subscriber.csproj` references nothing at all. A Dapr subscriber is a plain HTTP server that:

1. answers `GET /dapr/subscribe` with its subscriptions, and
2. accepts CloudEvents by `POST` on the route it advertised.

```csharp
app.MapGet("/dapr/subscribe", () => Results.Ok(new[]
{
    new { pubsubname = "order-pubsub", topic = "order-events", route = "/order-events" },
}));
```

`Dapr.AspNetCore` would let you write `[Topic("order-pubsub", "order-events")]` instead. It is
sugar over exactly this.

Returning `200` acknowledges the message. Returning an error status, or a body of
`{ "status": "RETRY" }`, asks the sidecar to redeliver.

### Failure handling

Nothing extra is configured. If the sidecar is down or the component is misconfigured, the publish
fails and the standard outbox machinery applies: `Classify` maps 408, 429 and 5xx to transient
(retried with exponential backoff), everything else to permanent. A sidecar that is not listening
at all yields no status code, which is treated as transient — the right answer, since
`dapr run` may simply not have finished starting. Sample 04 covers retry and dead-lettering in
detail.

### Moving to Azure Service Bus

Replace `components/pubsub.yaml`:

```yaml
spec:
  type: pubsub.azure.servicebus.topics
  version: v1
  metadata:
    - name: connectionString
      secretKeyRef: { name: sb-connection, key: sb-connection }
```

Keep `metadata.name: order-pubsub` and no C# changes at all. On Azure Container Apps the component
is declared in the environment instead of a local folder, and the same `order-pubsub` name is used
there.

---

## 8. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `The Dapr CLI is not installed or not on PATH` | Install the CLI, then `dapr init`. |
| `Nothing is listening on localhost:6379` | Docker Desktop is not running, or the `dapr_redis` container is stopped. `docker start dapr_redis dapr_placement dapr_scheduler`. |
| Publish returns 404 from the sidecar | The component name in `appsettings.json` does not match `metadata.name` in `components/pubsub.yaml`. |
| Orders are `Delivered` but `/received` stays empty | The order was published before the sidecar fetched `/dapr/subscribe`. Redis pub/sub drops messages with no subscriber. Wait for `/subscription-status` to report `true`. |
| `Port 5007 (publisher) is already in use` | A previous run was killed without stopping Dapr. `dapr stop -f .\dapr.yaml`, or pass different ports to `verify.ps1`. |
| `Cannot open database "OutboxSample07"` | Run the `sqlcmd` in section 4. |
| Both apps start, then exit immediately | `dapr.yaml` uses `--no-build`. Build both projects first, as section 5 does. |
| Dapr logs about the placement or scheduler service | Those containers belong to `dapr init`, not to this sample. `docker start dapr_placement dapr_scheduler`. |

`dapr run` also writes per-app logs to `Publisher\.dapr\logs` and `Subscriber\.dapr\logs`, which
is where the sidecar's own errors go. Both are gitignored.

---

## 9. Teardown

```powershell
cd samples\Outbox\07-Dapr
dapr stop -f .\dapr.yaml

$server = '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample07') IS NOT NULL DROP DATABASE OutboxSample07;"
```

The Redis container is shared with every other Dapr application on the machine; leave it alone, or
`dapr uninstall` if you want the whole control plane gone.
