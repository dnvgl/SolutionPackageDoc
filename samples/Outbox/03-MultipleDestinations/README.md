# Sample 03 — one event, three destinations

Fan-out. A single `EnqueueAsync` call names three destinations and produces three independently
retried outbox rows that share one event id. Two of those destinations are HTTP; the third is a
transport written by this sample in about forty lines.

Read [sample 01](../01-SqlServer-Http/) first — this one assumes you know what a transactional
enqueue looks like.

## 1. What this demonstrates

- **Fan-out from one enqueue.** `OutboxEnqueueRequest(["receiver-a", "receiver-b", "audit-file"])`
  writes three rows inside the same transaction as the business data.
- **The identifier rule.** One `EventId` per *event*; one `OutboxId` per *delivery*. Every
  destination sees the same `EventId`, so a receiver can correlate across destinations, and its
  own `OutboxId`, so retries to one destination never confuse another.
- **Independent failure.** Each row carries its own status, attempt count and retry schedule. A
  destination that is down holds up nothing else.
- **A destination is a logical name.** The producer passes strings. Which transport serves a name
  is a startup concern, so a destination can move from HTTP to Service Bus without touching
  producing code.
- **A custom transport.** [`FileDestination`](FileDestination.cs) implements `IOutboxDestination`
  — one method returning an `OutboxOutcome`. The dispatcher supplies claiming, backoff, retry and
  dead-lettering for free.

## 2. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| .NET SDK | 10.0 or later | `dotnet --list-sdks` |
| SQL Server | any local edition | SQL Express is fine |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| PowerShell | 7.0 or later | `verify.ps1` requires `pwsh`, not Windows PowerShell |

The `SolutionPackage` repository must sit next to `SolutionPackageDoc`. If it does not, pass
`-p:SolutionPackageRoot=<path>` to `dotnet build`.

Ports **5003** (this sample), **5101** and **5102** (the two receivers) must be free. All three
are overridable — see [Run](#5-run).

## 3. Cost

None. Everything runs locally.

## 4. Setup

Create the database. Tables are created by the application on startup.

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample03') IS NULL CREATE DATABASE OutboxSample03;"
```

If your instance is not `.\SQLEXPRESS`, set `OUTBOX_SAMPLES_SQL` and update
`ConnectionStrings:Sales` in [`appsettings.json`](appsettings.json).

## 5. Run

The quickest path is the smoke test, which starts all three processes, asserts the identifier rule
and cleans up:

```powershell
cd samples\Outbox
pwsh .\03-MultipleDestinations\verify.ps1
```

It checks each port before doing anything, so an occupied port fails in a second with the name of
the offending process rather than after a 90-second timeout. If something else owns a port, move
this sample instead of killing it:

```powershell
pwsh .\03-MultipleDestinations\verify.ps1 -ApiPort 5013 -ReceiverAPort 5111 -ReceiverBPort 5112
```

To run by hand, use three terminals. Build once first — two of these run the *same* project, and
concurrent `dotnet run` of one project races on the build output:

```powershell
dotnet build shared\Outbox.Samples.Receiver
dotnet build 03-MultipleDestinations
```

```powershell
# Terminal 1
dotnet run --no-build --project shared\Outbox.Samples.Receiver --urls http://localhost:5101
```

```powershell
# Terminal 2
dotnet run --no-build --project shared\Outbox.Samples.Receiver --urls http://localhost:5102
```

```powershell
# Terminal 3
dotnet run --no-build --project 03-MultipleDestinations --urls http://localhost:5003
```

All three serve a browsable index at their root. Then place an order from
[`sample.http`](sample.http), or with curl — note `/orders` is POST-only and cannot be exercised
from the address bar:

```powershell
curl -X POST http://localhost:5003/orders -H "Content-Type: application/json" `
  -d '{"tenantId":"acme","customerId":"cust-1","total":99.50}'
```

## 6. What you should see

`verify.ps1` places three orders and asserts the identifier rule at all three destinations:

```
Checking SQL Server...
Building...
Starting receiver A and receiver B...
Starting sample API...
Placing 3 orders...
Waiting for the dispatcher to deliver to all three destinations...
Checking the identifier rule across all three destinations...
PASS: 3 orders each fanned out to 2 HTTP receivers and 1 file, sharing one event id per order with three distinct outbox ids.
```

`GET /destinations` shows the names and the transport resolved for each:

```json
[
  { "name": "receiver-a",  "transport": "HttpOutboxDestination" },
  { "name": "receiver-b",  "transport": "HttpOutboxDestination" },
  { "name": "audit-file",  "transport": "FileDestination" }
]
```

Two names, one transport class; a third name, a transport this sample wrote. The producer cannot
tell the difference.

Placing one order returns one event id and three outbox ids:

```json
{
  "id": "01a186cf-2d61-75ac-bc8d-f789a27125fd",
  "eventId": "01a186cf-2d6b-7206-b7c9-665e4cd900ba",
  "outboxIds": [
    "01a186cf-2d70-71cd-8f26-9d3d9c6327b6",
    "01a186cf-2d70-7727-bb9a-8c10d9f13b84",
    "01a186cf-2d70-76d4-85c8-57eb98b3b2e9"
  ],
  "deliveries": [
    { "destination": "receiver-a", "outboxId": "01a186cf-2d70-71cd-8f26-9d3d9c6327b6" },
    { "destination": "receiver-b", "outboxId": "01a186cf-2d70-7727-bb9a-8c10d9f13b84" },
    { "destination": "audit-file", "outboxId": "01a186cf-2d70-76d4-85c8-57eb98b3b2e9" }
  ]
}
```

The dispatcher claims all three in one batch and delivers them concurrently:

```
dbug: DNV.Outbox.Hosting.OutboxDispatcher[3103]
      Claimed 3 deliveries for CNSGHL25100648:66904:e9510709.
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a186cf-2d70-76d4-85c8-57eb98b3b2e9 to audit-file on attempt 1.
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a186cf-2d70-7727-bb9a-8c10d9f13b84 to receiver-b on attempt 1.
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a186cf-2d70-71cd-8f26-9d3d9c6327b6 to receiver-a on attempt 1.
```

The file destination finishes first because it never leaves the machine. Delivery order is not
guaranteed and must not be relied on.

`GET http://localhost:5101/deliveries` and `:5102/deliveries` each return their own row. Same
`eventId`, same `traceParent`, same body — different `outboxId` and `destination`:

```json
[{
  "outboxId": "01a186cf-2d70-71cd-8f26-9d3d9c6327b6",
  "eventId": "01a186cf-2d6b-7206-b7c9-665e4cd900ba",
  "eventType": "OrderPlaced",
  "eventVersion": "1",
  "destination": "receiver-a",
  "attempt": "1",
  "traceParent": "00-1a234d656c404ac50808284b2dc3b9be-cbc9dfcb9f9ce9c6-00",
  "body": "{\"orderId\":\"01a186cf-2d61-75ac-bc8d-f789a27125fd\",\"tenantId\":\"acme\",\"customerId\":\"cust-1\",\"total\":99.50,\"currency\":\"USD\",\"placedAt\":\"2026-10-29T08:38:06.9460639+00:00\"}"
}]
```

The third destination writes `03-MultipleDestinations/audit/<outboxId>.json` instead:

```
// outboxId=01a186cf-2d70-76d4-85c8-57eb98b3b2e9 eventId=01a186cf-2d6b-7206-b7c9-665e4cd900ba
// eventType=OrderPlaced v1 traceparent=00-1a234d656c404ac50808284b2dc3b9be-cbc9dfcb9f9ce9c6-00
{"orderId":"01a186cf-2d61-75ac-bc8d-f789a27125fd","tenantId":"acme","customerId":"cust-1","total":99.50,"currency":"USD","placedAt":"2026-10-29T08:38:06.9460639+00:00"}
```

In the database, every order means three rows — one per destination. After `verify.ps1`, which
places three orders:

```powershell
sqlcmd -S $server -d OutboxSample03 -Q "SELECT Destination, Status, AttemptCount, COUNT(*) AS Cnt FROM outbox.OutboxMessages GROUP BY Destination, Status, AttemptCount ORDER BY Destination;"
```

```
Destination  Status  AttemptCount  Cnt
-----------  ------  ------------  ---
audit-file   3       1             3
receiver-a   3       1             3
receiver-b   3       1             3
```

`Status = 3` is *delivered*.

## 7. How it works

Registration binds each logical name to a transport:

```csharp
builder.Services.AddOutbox()
	.UseSqlServer(options => { /* store */ })
	.AddHttpDestination("receiver-a", http => { http.Endpoint = new Uri(/* ... */); })
	.AddHttpDestination("receiver-b", http => { http.Endpoint = new Uri(/* ... */); })
	// AddDestination registers the logical name AND the transport serving it. Registering a
	// transport already registers its name, so never call AddDestination(name) for a name a
	// transport registers - duplicate names throw.
	.AddDestination("audit-file", _ => new FileDestination("audit-file", auditDirectory))
	.AddDispatcher(/* ... */);
```

Producing is one call, inside the transaction that already holds the business write:

```csharp
var messages = await outbox.EnqueueAsync(
	order.ToIntegrationEvent(),
	new OutboxEnqueueRequest(
		["receiver-a", "receiver-b", "audit-file"],
		eventType: nameof(OrderPlaced),
		eventVersion: 1),
	cancellationToken);

await transaction.CommitAsync(cancellationToken);
```

Three destinations, three rows, one `CommitAsync`. Either the order and all three pending
deliveries are durable, or none of them are — there is no state in which the order exists but one
destination was never going to hear about it.

### The identifier rule

| Identifier | Scope | Changes on retry? | What it is for |
| --- | --- | --- | --- |
| `EventId` | the event | no | the thing that happened — shared by every destination |
| `OutboxId` | one delivery | no | this destination's copy — the receiver's idempotency key |

Both are stable across attempts, which is what makes at-least-once delivery tolerable: a receiver
that has already processed an `OutboxId` can discard the duplicate. Because `EventId` is shared, a
downstream system reading from two destinations can tell that it saw one event twice rather than
two events.

### Independent retry

Each row has its own `Status`, `AttemptCount` and `NextAttemptAt`. Stop receiver B and place an
order: receiver A and the audit file are delivered immediately, while B's row alone retries with
exponential backoff and eventually dead-letters. The other two are never blocked, never re-sent,
and never roll back. [Sample 04](../04-RetryAndDeadLetter/) drives that path deliberately.

### Writing a transport

[`FileDestination`](FileDestination.cs) is the entire contract — a `Name` and one `SendAsync`
returning an outcome:

```csharp
catch (IOException ex)
{
	// The disk might be busy or the file locked. Worth another attempt.
	return OutboxOutcome.Transient(ex.Message, ex);
}
catch (UnauthorizedAccessException ex)
{
	// Permissions will not fix themselves. Do not burn retries on this.
	return OutboxOutcome.Permanent(ex.Message, ex);
}
```

Two rules worth copying:

- **Classify honestly.** `Transient` schedules a retry; `Permanent` dead-letters at once. Calling
  a permanent failure transient wastes the retry budget and delays the moment an operator notices.
- **Return expected failures, do not throw them.** Cancellation is the exception — it means the
  host is shutting down or the claim was lost, so it must propagate rather than be reported as a
  delivery result.

The file is named after the `OutboxId`, so a retry rewrites the same file instead of appending a
duplicate. Transports should be written to tolerate being called twice with the same message.

## 8. Troubleshooting

**`Port 5003 (sample API) is already in use by process 'ssh' (PID 40180)`**
Something else owns the port. Either stop it, or move the sample with `-ApiPort`,
`-ReceiverAPort`, `-ReceiverBPort`. `verify.ps1` checks all three up front precisely so this does
not show up later as an unexplained health-check timeout.

**`Destination 'receiver-a' is already registered.`**
An `OutboxValidationException` at startup: a name was registered twice.
`AddHttpDestination(name, ...)` already registers the name, so an additional
`AddDestination("receiver-a")` is a duplicate rather than a refinement.

**`Timed out waiting for http://localhost:5102/health` on the second receiver only**
Two `dotnet run` invocations of the same project race on the build output; one of them loses.
Build once first, then start both with `--no-build`, as `verify.ps1` does.

**Only two of the three destinations are delivered**
Check `GET /destinations` lists all three. A name present in `OutboxEnqueueRequest` but not
registered fails at enqueue; a registered name whose transport is failing leaves a row with
`Status = 0` and a rising `AttemptCount`.

**The audit directory is empty**
It is resolved against the content root, so it is `03-MultipleDestinations/audit` regardless of
the directory you ran `dotnet run` from. `GET /` prints the absolute path it is actually using.

**`Timed out waiting for .../health`**
If `HTTP_PROXY` is set and `NO_PROXY` does not exclude localhost, PowerShell tunnels loopback
traffic through the proxy and hangs. `verify.ps1` passes `-NoProxy` for this reason; do the same
in your own scripts.

**`NU1903: Package 'System.Security.Cryptography.Pkcs' has a known high severity vulnerability`**
`Microsoft.Data.SqlClient` 7.1.1 resolves a vulnerable version transitively, and these samples
build with `TreatWarningsAsErrors`. [`Directory.Build.props`](../Directory.Build.props) pins a
patched version.

**`The DNV Outbox library was not found at '...'`**
`SolutionPackage` is not a sibling of `SolutionPackageDoc`. Pass
`-p:SolutionPackageRoot=<path-to-SolutionPackage>`.

## 9. Teardown

Stop the three processes with Ctrl+C, delete the audit files, then drop the database:

```powershell
Remove-Item .\03-MultipleDestinations\audit -Recurse -Force -ErrorAction SilentlyContinue
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample03') IS NOT NULL DROP DATABASE OutboxSample03;"
```
