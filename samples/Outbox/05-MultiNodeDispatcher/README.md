# Sample 05 — many dispatcher nodes, one outbox table

Three identical replicas run the dispatcher against a single outbox table. There is no leader
election, no distributed lock and no "only run the dispatcher on instance 0" configuration flag —
and no record is ever delivered twice.

---

## 1. What this demonstrates

Requirement 5 of the design: *when dispatching messages, consider multiple service nodes. Imagine
dispatchers in two service nodes fetching from the same outbox table — they must not fetch the
same record.*

This is the sample that answers "can I just run my service with three replicas?" The answer is
yes, and nothing special is needed to make it so:

- Every node runs the full application: HTTP API **and** dispatcher. They are identical.
- Safety comes from a **conditional claim in the database**, not from coordination between nodes.
- Scaling out has no configuration consequences. The nodes never talk to each other, and never
  need to know how many of them there are.
- The claim is a **lease**, so a node that dies does not strand the work it was holding.

The assertion in `verify.ps1` is a negative one, which is what makes it worth running: 50 orders
must produce **exactly** 50 deliveries. 51 would mean two nodes dispatched the same record.

---

## 2. Prerequisites

| Requirement | Notes |
| --- | --- |
| .NET 10 SDK | `dotnet --version` should report 10.x |
| SQL Server | LocalDB, SQL Express or a full instance. The default is `.\SQLEXPRESS` |
| PowerShell 7 | `verify.ps1` and `run-nodes.ps1` both need `pwsh`, not Windows PowerShell |
| Four free TCP ports | `5100` for the receiver, `5005`–`5007` for the nodes |

No Azure resources, and nothing to pay for. Set `OUTBOX_SAMPLES_SQL` to point at a different
instance, or pass `-SqlServer`.

---

## 3. Cost

Nothing. Everything runs locally.

---

## 4. Setup

Create the database. The schema itself is created by the application at startup.

```powershell
sqlcmd -S .\SQLEXPRESS -E -Q "IF DB_ID('OutboxSample05') IS NULL CREATE DATABASE OutboxSample05;"
```

The `verify.ps1` smoke test creates this database itself if it is missing, so this step is only
needed when running the sample by hand.

If `sqlcmd` is not on your `PATH` it ships with the ODBC client tools, typically at
`C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe`.

---

## 5. Run

### The fast way

```powershell
.\verify.ps1
```

It starts everything, places 50 orders, asserts the result and shuts down. Expected output:

```
PASS: 50 orders placed across 3 dispatcher nodes sharing one outbox table were delivered exactly 50 times (node-1=14, node-2=16, node-3=20).
```

The per-node split differs on every run — that is the contention working.

Pass `-ReceiverPort`, `-NodePorts` or `-OrderCount` if the defaults do not suit:

```powershell
.\verify.ps1 -NodePorts 5015,5016,5017 -OrderCount 200
```

### The way you actually learn something

```powershell
.\run-nodes.ps1
```

Four labelled windows open: the receiver and `node-1`, `node-2`, `node-3`. Place some orders —
all on one node, deliberately:

```powershell
1..30 | ForEach-Object {
	Invoke-RestMethod -NoProxy -Method Post -Uri "http://localhost:5005/orders" -ContentType 'application/json' `
		-Body (@{ tenantId = 'acme'; customerId = "cust-$_"; total = 10 } | ConvertTo-Json)
} | Out-Null
```

Then watch all three node windows. The dispatch logs interleave: **which node accepted an order
has nothing to do with which node dispatches it.**

Each node is browsable at its root — `http://localhost:5005`, `:5006`, `:5007` — and reports
which node it is.

> `--no-launch-profile` is not optional in those scripts. See Troubleshooting.

---

## 6. What you should see

### Each node knows who it is

`GET http://localhost:5006/`

```json
{
  "sample": "05-MultiNodeDispatcher",
  "node": "node-2",
  "description": "Three identical nodes run the dispatcher against one outbox table. No leader election, no distributed lock, and no record is delivered twice.",
  "endpoints": [
    "GET  /              this index",
    "GET  /health        liveness probe",
    "POST /orders        place an order (body: { tenantId, customerId, total })",
    "GET  /outbox/stats  aggregate counters over the shared table"
  ],
  "hint": "Place orders on any node, then watch all three node windows: the dispatch logs interleave."
}
```

### Placing an order names the node that accepted it

`POST http://localhost:5005/orders`

```json
{
  "id": "01a1a5c2-5fed-7c5b-8626-8afa3bf4e410",
  "acceptedBy": "node-1",
  "eventId": "01a1a5c2-5ffb-7652-8781-ee3382a061a9",
  "outboxIds": [
    "01a1a5c2-6005-72f3-968a-c774b2135ff6"
  ]
}
```

`acceptedBy` exists only to make the next point concrete: it is routinely **not** the node that
ends up dispatching the record.

### 51 orders in, 51 deliveries out

The receiver's tally after the demo order above plus 50 more:

```json
{
  "total": 51,
  "distinctOutboxIds": 51,
  "distinctEventIds": 51
}
```

`total` equal to `distinctOutboxIds` is the whole sample in one line. Three nodes polled the same
table continuously and not one record went out twice.

### The work really was shared

Counting `Delivered` lines in each node's own log:

```
node-1 delivered 19
node-2 delivered 16
node-3 delivered 16
```

`verify.ps1` asserts this too. A run where one node did all 50 would satisfy the no-duplicates
check while demonstrating nothing about contention, so that case fails the script.

### Every node sees the same table

`GET /outbox/stats` on node-1 and then on node-3:

```json
{
  "node": "node-1",
  "statistics": {
    "pending": 0, "processing": 0, "failed": 0,
    "delivered": 51, "deadLettered": 0,
    "oldestUndeliveredCreatedAt": null
  }
}
{
  "node": "node-3",
  "statistics": {
    "pending": 0, "processing": 0, "failed": 0,
    "delivered": 51, "deadLettered": 0,
    "oldestUndeliveredCreatedAt": null
  }
}
```

Identical numbers, because there is one table. The nodes are replicas, not shards.

### The node console

```
info: DNV.Outbox.SqlServer.SqlOutboxSchemaInitializer[2001]
      Applied outbox schema script 001_CreateOutbox.sql.
info: Outbox.Samples.MultiNodeDispatcher[0]
      Node node-1 ready.
info: DNV.Outbox.Hosting.OutboxDispatcher[3101]
      Outbox dispatcher node-1 started with a batch size of 10.
info: Microsoft.Hosting.Lifetime[14]
      Now listening on: http://localhost:5005
dbug: DNV.Outbox.Hosting.OutboxDispatcher[3103]
      Claimed 1 deliveries for node-1.
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a1a5c2-6005-72f3-968a-c774b2135ff6 to receiver on attempt 1.
dbug: DNV.Outbox.Hosting.OutboxDispatcher[3103]
      Claimed 10 deliveries for node-1.
```

And on node-3, at the same moment, against the same table:

```
      Claimed 4 deliveries for node-3.
      Delivered 01a1a5c2-605d-7d3a-a33f-7651cd0fad9f to receiver on attempt 1.
      Delivered 01a1a5c2-60bb-7e66-aea2-ecbd87fb00ff to receiver on attempt 1.
      Delivered 01a1a5c2-6089-761f-a902-da2bd3329d91 to receiver on attempt 1.
      Delivered 01a1a5c2-60da-7a5e-8819-9cdb3cf571ed to receiver on attempt 1.
      Claimed 10 deliveries for node-3.
```

Note `Claimed 4` and `Claimed 1` against a configured batch size of 10. A node takes what is
available and not already claimed by a peer; it does not wait for a full batch.

### Killing a node

Queue 60 orders, then kill `node-2` while the backlog drains:

```json
{
  "total": 60,
  "distinctOutboxIds": 60,
  "distinctEventIds": 60
}
```

Still exactly 60. The surviving nodes absorbed the whole backlog, and losing a replica cost
nothing — no lost events, no duplicates, no operator intervention.

> Honest caveat about this particular run: `node-2` was killed early enough that it had claimed
> nothing, so it delivered none of the 60. It therefore demonstrates that the survivors complete
> the backlog — **not** that an abandoned claim is recovered. For that, see the lease discussion
> below; it is a timing window that is hard to hit on demand with a fast local receiver.

---

## 7. How it works

### The claim is one statement

The dispatcher does not read-then-update, which would race. It claims in a single statement,
in `SqlOutboxStore.ClaimAsync`:

```sql
WITH [candidates] AS (
    SELECT TOP (@BatchSize) *
    FROM [outbox].[OutboxMessages] WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE [Status] = 0
       OR ([Status] = 2 AND [NextAttemptAt] IS NOT NULL AND [NextAttemptAt] <= @Now)
       OR ([Status] = 1 AND [ClaimExpiresAt] IS NOT NULL AND [ClaimExpiresAt] <= @Now)
    ORDER BY [CreatedAt], [OutboxId]
)
UPDATE [candidates]
SET [Status] = 1,
    [ClaimOwner] = @Owner,
    [ClaimExpiresAt] = @ClaimExpiresAt,
    [LastAttemptAt] = @Now,
    [AttemptCount] = [AttemptCount] + 1
OUTPUT ...;
```

Three hints do the work:

- **`UPDLOCK`** takes the update lock during the *select*, so a row cannot be read by one node and
  then claimed by another in the gap.
- **`READPAST`** is the important one. A row another node currently holds is **skipped**, not
  waited for. Without it the nodes would serialise behind each other and adding replicas would
  buy you nothing; with it, they fan out across the table.
- **`ROWLOCK`** keeps that skipping at row granularity rather than escalating to a page.

Because the select and the update are one statement under one lock, there is no window in which
two nodes can both believe they own a record.

### The claim is a lease, not a lock

`ClaimExpiresAt` is set to `now + ClaimDuration` (30 seconds in this sample). That third `WHERE`
clause — `Status = 1 AND ClaimExpiresAt <= @Now` — is how a crashed node's work is recovered: once
the lease lapses, the record becomes claimable again and another node takes it.

This is why no node needs to know that another has died, and why there is no health check or
membership protocol anywhere in the design.

A long delivery does not lose its lease: when `ClaimDuration` is not comfortably longer than
`DestinationTimeout`, the processor starts a `ClaimRenewalLoop` that extends `ClaimExpiresAt`
while the attempt is in flight. Renewal deliberately leaves `AttemptCount` untouched — extending
a lease is not a new attempt.

### `AttemptCount` increments on claim, not on failure

Worth internalising, because it is the opposite of what most people assume: the `UPDATE` above
increments `AttemptCount` *when the record is claimed*, before any delivery is attempted.

The consequence is that **an attempt abandoned by a crash still counts against `MaxAttempts`**.
If a node is killed mid-delivery, the record is retried elsewhere, but the budget has already been
charged for the attempt that never completed. A record on a repeatedly-crashing node will
eventually dead-letter. That is the intended trade: the alternative — not counting an attempt
until its outcome is known — cannot distinguish a crashed node from a slow one, and would let a
poisonous record cycle forever.

On a *graceful* shutdown the processor logs
`[3007] Abandoned the in-flight attempt ... the claim will expire and another replica will retry`
and deliberately writes no outcome, so the record is not marked failed. The attempt is still
counted, for the same reason.

### At-least-once, and where the duplicate would come from

This sample shows exactly-once in practice, but the guarantee remains at-least-once. The honest
duplicate window is this: a node delivers successfully, then fails to record that success — its
`CompleteAsync` finds the claim already taken over by a peer whose lease check won. The processor
logs `[3004] The claim on ... was lost before the attempt result could be written` and lets the
other node deliver again.

Delivering twice is recoverable by a consumer that deduplicates on `eventId`; losing an event is
not. The design chooses the recoverable failure. This is why samples 01 and 04 stress that the
identifiers stay stable across retries.

### Making the nodes contend

Production defaults — a batch of 50 every 5 seconds — would let one node drain 50 records before
the others next polled, which is correct but demonstrates nothing. So this sample uses:

```csharp
dispatcher.InstanceId = nodeId;
dispatcher.PollInterval = TimeSpan.FromMilliseconds(500);
dispatcher.BatchSize = 10;
dispatcher.MaxConcurrency = 4;
dispatcher.ClaimDuration = TimeSpan.FromSeconds(30);
```

`InstanceId` is diagnostics only — it is written to `ClaimOwner` and appears in the logs. It plays
no part in correctness, and defaults to `MachineName:ProcessId:random` so two replicas on one host
never collide. Set it to something meaningful anyway; when a record is stuck in `Processing` at
3am, `ClaimOwner` is how you find out which replica was holding it.

`PollJitterRatio` (0.2 by default) randomises the gap between polls so replicas that started
together drift apart instead of hammering the store in lockstep.

### Schema bootstrap is the one thing that is not replica-safe

Both scripts start the nodes **one at a time**, waiting for each to be healthy. That is not about
dispatch — it is about startup. Three processes concurrently running `EnsureCreatedAsync` and
`CREATE TABLE dbo.Orders` are racing on DDL, and the loser can throw.

In production this does not arise, because schema migration is a deployment step that runs once,
not something every replica does on boot. Sample 02 shows the migration-based approach. The
bootstrap here is a convenience for a sample you are expected to run from a dropped database.

---

## 8. Troubleshooting

**Every node reports `"node": "node-1"`.**
`dotnet run` applied the first profile in `launchSettings.json`, and its `OUTBOX__NODEID`
overrode the environment variable the script set. Pass `--no-launch-profile`, as both scripts do.
Delivery stays correct — safety comes from the row claim, not the identity — but every log line
and `ClaimOwner` value names the wrong node, which is worse than useless when diagnosing.
`verify.ps1` asserts each node's reported identity so this cannot regress quietly.

**`Port 5005 (node 1) is already in use by process 'x' (PID n).`**
Exactly what it says, and it fails in a second rather than as a mystifying timeout 90 seconds
later. Stop the process or pass `-NodePorts`.

**One node never starts, with a file-lock error during build.**
Three `dotnet run` invocations of the *same* project race on the build output. Both scripts build
once up front and then start every process with `--no-build`. Keep it that way.

**`total` is greater than `OrderCount`.**
A genuine double delivery — the thing this sample exists to disprove. Before suspecting the
library, check the receiver was reset (`DELETE /deliveries`) and that no stray node from an
earlier run is still attached to the same database.

**`total` is less than `OrderCount` and stays there.**
Deliveries are failing rather than duplicating. Check `GET /outbox/stats`: a non-zero `failed` or
`deadLettered` means the receiver is rejecting. Sample 04 covers that path.

**These nodes dispatched nothing: node-N.**
Everything was delivered correctly, but one node did none of it, so the run proves nothing about
contention. Usually it means the orders drained faster than a node could join in. Raise
`-OrderCount`.

---

## 9. Teardown

Close the windows `run-nodes.ps1` opened; `verify.ps1` cleans up after itself. Then:

```powershell
sqlcmd -S .\SQLEXPRESS -E -Q "DROP DATABASE OutboxSample05;"
```
