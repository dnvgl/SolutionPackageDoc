# Sample 04 — retry, dead-letter and requeue

What happens when delivery *fails*. Every other sample shows the happy path; this one shows the
path that actually justifies the pattern, and how an operator recovers from it.

Read [sample 01](../01-SqlServer-Http/) first.

## 1. What this demonstrates

- **Bounded retry with exponential backoff.** A transient failure is retried on a growing delay,
  with jitter, up to `MaxAttempts`.
- **A retry is the same record.** Four attempts, one `OutboxId`, one `EventId`. The outbox never
  creates a second row for a second attempt, which is what makes at-least-once delivery
  deduplicable rather than merely repetitive.
- **Dead-lettering.** When attempts run out the record becomes terminal and the dispatcher stops
  touching it. A permanent failure dead-letters immediately, without exhausting attempts.
- **`NextAttemptAt` as a scheduling gate.** A failed record is invisible to the dispatcher until
  that moment passes, no matter how often it polls.
- **Operator requeue.** `RequeueAsync` replays a dead-lettered record **preserving both
  identifiers**, so a consumer that deduplicates sees a duplicate rather than a new event.
- **Retention and health.** Terminal records are swept on a schedule, and backlog pressure is
  surfaced as a health check.

## 2. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| .NET SDK | 10.0 or later | `dotnet --list-sdks` |
| SQL Server | any local edition | SQL Express is fine |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| PowerShell | 7.0 or later | `verify.ps1` requires `pwsh`, not Windows PowerShell |

The `SolutionPackage` repository must sit next to `SolutionPackageDoc`. If it does not, pass
`-p:SolutionPackageRoot=<path>` to `dotnet build`.

Ports **5004** (this sample) and **5100** (the shared receiver) must be free; both are overridable
with `-ApiPort` and `-ReceiverPort`.

## 3. Cost

None. Everything runs locally.

## 4. Setup

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample04') IS NULL CREATE DATABASE OutboxSample04;"
```

## 5. Run

The smoke test drives all three phases and asserts each one:

```powershell
cd samples\Outbox
pwsh .\04-RetryAndDeadLetter\verify.ps1
```

To drive it by hand, start the receiver and the sample in two terminals:

```powershell
# Terminal 1 — the destination
dotnet run --project shared\Outbox.Samples.Receiver --urls http://localhost:5100
```

```powershell
# Terminal 2 — the sample
dotnet run --project 04-RetryAndDeadLetter --urls http://localhost:5004
```

The receiver can be told to reject the next *n* deliveries with HTTP 500, which is how failures
are induced here — nothing is broken to simulate them:

```powershell
# Fail three times, then accept. MaxAttempts is 4, so this is survivable.
curl -X POST http://localhost:5100/fail-next/3

curl -X POST http://localhost:5004/orders -H "Content-Type: application/json" `
  -d '{"tenantId":"acme","customerId":"cust-1","total":42.00}'

# Watch the record move. Substitute the outboxId from the response above.
curl http://localhost:5004/outbox/<outboxId>
```

Fail more times than the record has attempts and it dead-letters instead:

```powershell
curl -X POST http://localhost:5100/fail-next/50
```

See [`sample.http`](sample.http) for the full set, including the operator endpoints.

## 6. What you should see

```
Phase 1: retry after transient failures...
  3 rejections, then delivered on attempt 4 as the same record.

Phase 2: dead-letter after exhausting attempts...
  Stopped at 4 attempts and stayed stopped.

Phase 3: operator requeues the dead-lettered record...
  Replayed with the original outbox id and event id, then delivered on attempt 1.

PASS: transient failures retried as one record, dead-lettered at 4 attempts, then requeued and delivered with both identifiers preserved.
```

### Phase 1 — retry

The dispatcher reports each failure and the time it will try again:

```
warn: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3002]
      Delivery 01a18c37-179a-728d-8e19-b1e46cd918a7 to receiver failed on attempt 1; retrying at 10/30/2026 09:49:46 +00:00. receiver responded 500 Internal Server Error
warn: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3002]
      Delivery 01a18c37-179a-728d-8e19-b1e46cd918a7 to receiver failed on attempt 2; retrying at 10/30/2026 09:49:51 +00:00. receiver responded 500 Internal Server Error
warn: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3002]
      Delivery 01a18c37-179a-728d-8e19-b1e46cd918a7 to receiver failed on attempt 3; retrying at 10/30/2026 09:49:57 +00:00. receiver responded 500 Internal Server Error
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a18c37-179a-728d-8e19-b1e46cd918a7 to receiver on attempt 4.
```

The gaps grow — roughly one, two then four seconds — but they are not exact. `JitterRatio`
randomizes each delay, and the dispatcher only notices an eligible record on its next poll, so
the real gap is the computed delay plus up to one poll interval.

Caught between attempts, the record shows the failure and the time it is waiting for:

```json
{
  "outboxId": "01a18c32-f6ae-72d8-b767-77e84bcfb68b",
  "status": "Failed",
  "attemptCount": 3,
  "nextAttemptAt": "2026-10-30T09:45:27.2153344+00:00",
  "lastError": "receiver responded 500 Internal Server Error",
  "deliveredAt": null,
  "deadLetteredAt": null
}
```

Poll at the wrong moment and you will see `"status": "Processing"` instead, with a `nextAttemptAt`
left over from the previous failure. That is not a bug: `Processing` means a dispatcher holds a
claim on the record *right now*, and the stale schedule is overwritten when that attempt resolves.

Once it succeeds, the attempt count is preserved — four attempts, one record:

```json
{
  "outboxId": "01a18c37-179a-728d-8e19-b1e46cd918a7",
  "eventId": "01a18c37-1795-757f-80b6-709f32d9c14c",
  "status": "Delivered",
  "attemptCount": 4,
  "nextAttemptAt": null,
  "lastError": null,
  "deliveredAt": "2026-10-30T09:49:59.9653491+00:00"
}
```

The receiver confirms it saw four deliveries that were all the *same* record:

```json
{ "total": 4, "distinctOutboxIds": 1, "distinctEventIds": 1 }
```

This is the sample's central claim. At-least-once delivery means a consumer will sometimes see the
same message more than once — but because the identifiers are stable, it can tell.

### Phase 2 — dead-letter

With more forced failures than attempts, the fourth attempt is terminal:

```
fail: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3003]
      Delivery 01a18c33-2c6d-717f-b8dc-8270ff5830a6 to receiver was dead-lettered after 4 attempts. receiver responded 500 Internal Server Error
warn: Microsoft.Extensions.Diagnostics.HealthChecks.DefaultHealthCheckService[103]
      Health check outbox with status Degraded completed after 5.1592ms with message '2 outbox deliveries are dead-lettered and need operator attention.'
```

`GET /outbox/dead-lettered` is the queue an operator works from. `LastError` is why it is there:

```json
[{
  "outboxId": "01a18c33-2c6d-717f-b8dc-8270ff5830a6",
  "eventId": "01a18c33-2c6d-7087-ac21-9767bd2f7525",
  "destination": "receiver",
  "eventType": "OrderPlaced",
  "attemptCount": 4,
  "lastError": "receiver responded 500 Internal Server Error",
  "deadLetteredAt": "2026-10-30T09:45:42.4189848+00:00"
}]
```

A dead letter makes the service **Degraded**, not Unhealthy, so the endpoint still returns 200:

```
GET /health/outbox  ->  Degraded [HTTP 200]
```

That is deliberate. A dead letter needs a human, but the service itself is working — failing the
probe would restart a healthy container and fix nothing.

### Phase 3 — requeue

```
POST /outbox/01a18c33-2c6d-717f-b8dc-8270ff5830a6/requeue  ->  [HTTP 202]
```

The record returns to the queue and is delivered, with its identifiers intact:

```json
{
  "outboxId": "01a18c33-2c6d-717f-b8dc-8270ff5830a6",
  "eventId": "01a18c33-2c6d-7087-ac21-9767bd2f7525",
  "status": "Delivered",
  "attemptCount": 1,
  "deliveredAt": "2026-10-30T09:45:54.3254279+00:00",
  "deadLetteredAt": null
}
```

`attemptCount` restarted at zero because `RequeueAsync` is called with `resetAttemptCount: true` —
a replayed record gets a full budget of attempts, not the zero it had left. Pass `false` to keep
the original count, and the record will dead-letter again on its first failure.

Requeue only applies to a dead-lettered record. Replaying this one a second time is refused:

```json
{ "message": "Only a dead-lettered record can be requeued. This one is missing, or is in another state." }
```

```
[HTTP 409]
```

## 7. How it works

### Retry is configuration, not code

```csharp
.ConfigureRetry(retry =>
{
	// Deliberately tiny so the whole failure path finishes in seconds. Production defaults
	// back off to minutes and allow 8 attempts.
	retry.BaseDelay = TimeSpan.FromSeconds(1);
	retry.Multiplier = 2;
	retry.MaxDelay = TimeSpan.FromSeconds(8);
	retry.JitterRatio = 0.2;
	retry.MaxAttempts = 4;
})
```

The delay after attempt *n* is `BaseDelay × Multiplier^(n-1)`, capped at `MaxDelay`, then
randomized by `JitterRatio`. Jitter is not decoration: without it, replicas that failed together
retry together and stampede a destination that is just coming back.

`MaxAttempts` is the attempt on which a transient failure becomes terminal. With `4`, attempts
1–3 are retried and attempt 4 dead-letters.

### `NextAttemptAt` is the gate

A failed record is written with a `NextAttemptAt` in the future, and the claim query simply does
not return it until then. The dispatcher can poll every second without disturbing a record that
is backing off for a minute — the backoff lives in the row, not in the dispatcher's memory, which
is why it survives a restart and why any replica can honour it.

### Two ways to become terminal

| Cause | When | Attempts used |
| --- | --- | --- |
| Attempts exhausted | `AttemptCount` reaches `MaxAttempts` | all of them |
| Permanent failure | the transport returns `OutboxOutcome.Permanent` | one |

A transport that knows a request can never succeed — a 400, a malformed payload, a missing
permission — should say so and dead-letter immediately. Retrying an identical request that failed
for a deterministic reason only delays the moment somebody notices. [Sample 03](../03-MultipleDestinations/)
shows a transport making that call.

### Why requeue preserves identifiers

```csharp
var result = await store.RequeueAsync(
	outboxId, partitionKey: null, DateTimeOffset.UtcNow, resetAttemptCount: true, cancellationToken);
```

The record is reset — status, attempt count, schedule, error, claim — but `OutboxId` and `EventId`
are untouched. A consumer that deduplicates on either one recognises the replay as something it
has already seen. If requeue minted new identifiers, every operator replay would look like a
brand-new business event, and replaying a dead letter would risk shipping the order twice.

`result.Applied` is `false` when the record was not dead-lettered, which is why the endpoint
returns 409 rather than pretending to succeed. The guard is in the `WHERE` clause, so two
operators clicking requeue at once cannot both win.

### Retention

```csharp
.AddRetention(retention =>
{
	retention.DeliveredRetention = TimeSpan.FromMinutes(1);
	retention.DeadLetteredRetention = TimeSpan.FromHours(1);
	retention.SweepInterval = TimeSpan.FromSeconds(30);
})
```

Delivered records are evidence; dead letters are work. Dead letters are therefore kept far longer
— the defaults are 7 and 30 days. The sweep deletes in bounded batches so it never holds a long
lock on the table the dispatcher is claiming from. The values above are shortened for the demo;
a one-minute delivered retention in production would destroy your audit trail.

## 8. Troubleshooting

**`Port 5004 (sample API) is already in use by process '...'`**
Stop the process, or pass `-ApiPort` / `-ReceiverPort`.

**Nothing is retried; the record stays `Pending`**
The receiver is not running, so the dispatcher cannot even get a failure. Rows sit `Pending` with
`AttemptCount` 0. Confirm <http://localhost:5100> answers.

**The record dead-lettered when you expected it to succeed**
`fail-next/{count}` must be *fewer* than `MaxAttempts`. With `MaxAttempts = 4`, `fail-next/4`
dead-letters, because the fourth and final attempt is also rejected.

**`fail-next` seems to be ignored**
`DELETE /deliveries` resets the failure budget as well as the recorded deliveries. Set the budget
*after* clearing, never before.

**Requeue returns 409**
Only a dead-lettered record can be requeued. Check `GET /outbox/{outboxId}` — if it already says
`Delivered`, there is nothing to replay.

**Dead letters vanished before you could look at them**
`DeadLetteredRetention` is one hour in this sample and the sweep runs every 30 seconds. Raise it
if you are investigating slowly.

**`/health/outbox` says Degraded and you want it green**
Requeue or clear the dead letters. `DegradedDeadLetterCount` defaults to 1, so a single dead
letter is enough — which is the point.

**`Timed out waiting for http://localhost:5100/health`**
If `HTTP_PROXY` is set and `NO_PROXY` does not exclude localhost, PowerShell tunnels loopback
traffic through the proxy and hangs. `verify.ps1` passes `-NoProxy` for this reason.

**`NU1903: Package 'System.Security.Cryptography.Pkcs' has a known high severity vulnerability`**
`Microsoft.Data.SqlClient` 7.1.1 resolves a vulnerable version transitively.
`DNV.Outbox.SqlServer` references a patched version directly, so the samples inherit it and you
should no longer see this. If you do, the library is out of date — see
`SolutionPackage/src/Outbox/SqlServer/DNV.Outbox.SqlServer.csproj`.

**`The DNV Outbox library was not found at '...'`**
`SolutionPackage` is not a sibling of `SolutionPackageDoc`. Pass
`-p:SolutionPackageRoot=<path-to-SolutionPackage>`.

## 9. Teardown

Stop both processes with Ctrl+C, then drop the database:

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample04') IS NOT NULL DROP DATABASE OutboxSample04;"
```
