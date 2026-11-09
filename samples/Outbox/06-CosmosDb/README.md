# Sample 06 — Azure Cosmos DB

One order document and its outbox record committed in a **single Cosmos transactional batch**,
inside one container and one logical partition — the only scope in which Cosmos is atomic.

---

## 1. What this demonstrates

Cosmos DB has no multi-container transaction, and no cross-partition transaction. Its unit of
atomicity is a **transactional batch**: a set of operations against **one container** and **one
logical partition**, which Cosmos either applies completely or rejects completely.

That single fact drives the whole design of this sample:

| Habit from SQL Server | What it becomes in Cosmos | Why |
| --- | --- | --- |
| The outbox gets its own table | The outbox shares the **orders** container | A batch cannot span containers, so an outbox in its own container could not commit with the business write |
| Any row, any transaction | Every enqueue supplies a **partition key** | A batch cannot span partitions, so an outbox record must land in the same partition as the order |
| `BEGIN TRAN` / `COMMIT` | `ForPartition(...)` / `ExecuteAsync()` | The batch *is* the transaction |

The sample proves the guarantee rather than asserting it. `POST /orders/doomed` stages a valid
order, a valid outbox record, and one operation that cannot succeed. Cosmos rejects the batch, and
afterwards **neither** the order **nor** the outbox record exists — which is the property that
matters, because an outbox record surviving a failed business write would publish an event
announcing an order that was never placed.

Also shown:

- `AutoProvision` creating the database and container at startup, with the composite index the
  dispatcher's poll query needs.
- The `recordType` discriminator that lets business and outbox documents coexist in one container.
- Trace context captured on the outbox document and carried to the destination.

**Not** shown: Entra ID authentication (this sample targets the emulator, which only speaks keys —
see §2), and running against a real Azure Cosmos account (configuration only — see §7).

---

## 2. Prerequisites

- .NET 10 SDK
- **Azure Cosmos DB Emulator**, running. See §4 — it needs administrator rights to start.
- The shared receiver from `../shared/Outbox.Samples.Receiver` (started for you in §5)

### A note on the key in `appsettings.json`

`appsettings.json` contains the emulator's access key in plain text. That is safe and deliberate:
the emulator's key is fixed, identical on every machine, and published in Microsoft's
documentation. It is not a secret.

It is also **not how you should connect to a real account.** Azure Cosmos DB supports Entra ID, and
production code should use it:

```csharp
new CosmosClient(endpoint, new DefaultAzureCredential())
```

with the app granted the *Cosmos DB Built-in Data Contributor* role. No key, nothing to rotate,
nothing to leak. The emulator does not support Entra ID, which is the only reason this sample uses
a key at all.

The same applies to `Cosmos:TrustSelfSignedCertificate`. The emulator serves a self-signed
certificate, and that flag tells the sample to accept it. Against a real account it would disable
the protection that stops a proxy impersonating Cosmos, which is why it lives in configuration
rather than in the code path you would copy.

---

## 3. Cost

Nothing. The emulator is free and runs locally.

---

## 4. Setup

Start the emulator **in an elevated PowerShell window** — it cannot start without administrator
rights, and it takes a minute or two to become ready:

```powershell
& 'C:\Program Files\Azure Cosmos DB Emulator\Microsoft.Azure.Cosmos.Emulator.exe' `
    /NoExplorer /DisableRateLimiting /PartitionCount=10
```

Check it is up:

```powershell
# 401 is a PASS here: it means Cosmos answered and rejected an unauthenticated request.
Invoke-WebRequest https://localhost:8081/ -SkipCertificateCheck -NoProxy
```

There is nothing else to set up. The database (`sales`) and the container (`orders`, partitioned
by `/tenantId`) are created at startup by `AutoProvision`.

---

## 5. Run

The fastest check is the smoke test, which starts everything, asserts all three properties and
shuts down:

```powershell
cd samples/Outbox/06-CosmosDb
pwsh ./verify.ps1
```

```
Checking the Cosmos emulator...
Building...
Starting receiver...
Starting sample API...

Phase 1: placing 5 orders in partition 'acme'...
  Checking both document kinds share one container...
  5 orders and 5 outbox records in container 'orders'.

Phase 2: waiting for delivery...
  5 deliveries, 5 distinct outbox ids.

Phase 3: a doomed batch must write NOTHING...
  Rejected with HTTP 409. Order absent, outbox unchanged at 5 records, no extra delivery.

PASS: 5 orders and their outbox records committed atomically in one Cosmos container and partition and were delivered exactly 5 times, and a rejected batch wrote neither the order nor its outbox record.
```

To drive it by hand, use two terminals:

```powershell
# Terminal 1 — the destination
cd samples/Outbox/shared/Outbox.Samples.Receiver
dotnet run --urls http://localhost:5100
```

```powershell
# Terminal 2 — the sample
cd samples/Outbox/06-CosmosDb
dotnet run --urls http://localhost:5006
```

Open <http://localhost:5006/> for an index of the endpoints, or step through `sample.http`.

---

## 6. What you should see

Every response below was captured from a run against an empty database.

### Place an order

```powershell
Invoke-RestMethod -NoProxy -Method Post http://localhost:5006/orders `
    -ContentType 'application/json' `
    -Body '{"tenantId":"acme","customerId":"cust-1","total":42.50}'
```

```json
{
  "orderId": "01a1aaef-2ac0-7ae0-aa0e-92189be44c99",
  "tenantId": "acme",
  "eventId": "01a1aaef-2ac5-7f8b-bffa-3f2b74c5bacb",
  "outboxId": "01a1aaef-2acc-75cd-bf95-631899d1c025",
  "destination": "receiver"
}
```

### Both kinds of document, one container

After three orders:

```powershell
Invoke-RestMethod -NoProxy http://localhost:5006/container/acme
```

```json
{
  "database": "sales",
  "container": "orders",
  "partitionKey": "acme",
  "orders": 3,
  "outboxRecords": 3,
  "note": "Both counts come from the same container. That is what makes the write transactional."
}
```

Three orders, three outbox records, **one container**. In SQL Server those would be two tables in
one database; here they are two kinds of document in one container, and the colocation is not an
optimisation — it is the requirement.

### The outbox records

```powershell
Invoke-RestMethod -NoProxy http://localhost:5006/outbox/acme
```

```json
[
  {
    "id": "01a1aaef-2acc-75cd-bf95-631899d1c025",
    "eventId": "01a1aaef-2ac5-7f8b-bffa-3f2b74c5bacb",
    "destination": "receiver",
    "eventType": "OrderPlaced",
    "status": "Delivered",
    "attemptCount": 1,
    "createdAt": "2026-11-05T08:59:23.2124756Z",
    "deliveredAt": "2026-11-05T08:59:26.4732596Z",
    "lastError": null,
    "traceParent": "00-4da1f7a9cc2aeadceec24736c91ce4ba-e8c7b2ca89d86302-00"
  }
]
```

`outboxId` in the placement response is the `id` here. It never changes, across any number of
retries, which is what lets the receiver deduplicate.

### The doomed batch

```powershell
Invoke-RestMethod -NoProxy -Method Post http://localhost:5006/orders/doomed `
    -ContentType 'application/json' `
    -Body '{"tenantId":"acme","customerId":"cust-doomed","total":99.00}'
```

`HTTP 409`:

```json
{
  "orderId": "01a1aaef-7d22-73e6-89a4-523d320121c5",
  "tenantId": "acme",
  "rejected": true,
  "message": "The Cosmos transactional batch on container 'orders' partition 'acme' failed with status 404. Nothing was written. Operation 2 (replace OrderDocument) returned 404.",
  "explanation": "The batch was rejected, so neither the order nor its outbox record exists. Check with GET /orders/{tenantId}/{id} and GET /container/{tenantId}."
}
```

Note what the error names: **operation 2**, the deliberately doomed replace. Cosmos reports `424`
(failed dependency) for every *other* operation in a rejected batch, so the library skips the 424s
and reports the one that actually failed. Without that, the message would blame the order.

Now check that nothing landed:

```powershell
Invoke-RestMethod -NoProxy http://localhost:5006/orders/acme/01a1aaef-7d22-73e6-89a4-523d320121c5
```

`HTTP 404` — the order does not exist.

```powershell
Invoke-RestMethod -NoProxy http://localhost:5006/container/acme
```

```json
{
  "database": "sales",
  "container": "orders",
  "partitionKey": "acme",
  "orders": 3,
  "outboxRecords": 3,
  "note": "Both counts come from the same container. That is what makes the write transactional."
}
```

Still three and three. And at the receiver:

```powershell
Invoke-RestMethod -NoProxy http://localhost:5100/deliveries/summary
```

```json
{
  "total": 3,
  "distinctOutboxIds": 3,
  "distinctEventIds": 3
}
```

Three deliveries, not four. The rejected order never produced an event, because its outbox record
was rolled back with it.

---

## 7. How it works

### The batch is the transaction

```csharp
var batch = batchFactory.ForPartition(order.TenantId);

batch.CreateItem(OrderDocument.From(order));

await batch.EnqueueAsync(
    order.ToIntegrationEvent(),
    new OutboxEnqueueRequest([ "receiver" ], eventType: nameof(OrderPlaced))
    {
        PartitionKey = order.TenantId,
    },
    cancellationToken);

await batch.ExecuteAsync(cancellationToken);
```

Nothing reaches Cosmos until `ExecuteAsync`. `CreateItem` and `EnqueueAsync` stage operations on
one `TransactionalBatch`; `ExecuteAsync` sends them as one request. There is no commit to forget
and no window in which the order exists without its event.

`ForPartition` takes the partition key value because **that**, not the container, is the
transaction boundary. Pass a `PartitionKey` on the enqueue that differs from the batch's partition
and the library throws immediately, naming both values — far better than discovering at commit
time that the two documents were never going to be atomic.

Calling `UseCosmos` also sets `OutboxOptions.RequirePartitionKey = true`, so an enqueue that
forgets the partition key is rejected at the call site rather than quietly committing somewhere
it cannot be transactional.

### Why the outbox lives in the business container

It has to. A transactional batch spans one container. An outbox in its own container would be a
second, independent write — exactly the dual-write problem the outbox pattern exists to eliminate.

The two kinds of document coexist because each carries a discriminator:

| Document | Discriminator |
| --- | --- |
| Order | `"type": "order"` — this sample's own convention |
| Outbox record | `"recordType": "OutboxDelivery"` — stamped by the library |

Every query the library issues filters on `recordType`, so it never sees your documents, and the
sample's `/container/{tenantId}` counts filter on `type`, so it never miscounts outbox records as
orders. Pick a discriminator for your own documents that is not `recordType`, and avoid the
property names the library reserves (`id`, `status`, `payload`, `createdAt`, `eventId`, and the
rest — `CosmosOutboxOptions.Validate()` will tell you if you collide).

### Partition keys must be single-level

`PartitionKeyPath` must be something like `/tenantId`, not `/tenant/id`. The library writes that
property as a **top-level** property onto its own outbox documents so they land in the same logical
partition as the order; a nested path cannot be satisfied that way, so the options validator
rejects it at startup rather than letting records scatter across partitions.

Choose the path the same way you would for any Cosmos container: it must be something every
business write already has. `TenantId` works here precisely because an order always belongs to
exactly one tenant.

### Timestamps are fixed-width strings

Cosmos has no date type. The library stores timestamps as `yyyy-MM-ddTHH:mm:ss.fffffffZ` — always
UTC, always the same width — so that lexicographic string comparison and ordering behave exactly
like chronological comparison. That is what makes `ORDER BY c.createdAt` and
`c.nextAttemptAt <= @now` correct in the dispatcher's poll query.

### Provisioning

`AutoProvision = true` registers a startup hosted service that creates the database and container
before the dispatcher's first poll, and then verifies that an existing container's partition key
path matches the configured one — failing startup loudly if it does not, rather than writing
records that can never be read back.

The container it creates carries a composite index on `/status` ascending plus `/createdAt`
ascending, because that is precisely what the dispatcher filters and orders by on every poll.
Without it, each poll degrades into a scan and burns request units.

Unlike SQL DDL, this is replica-safe: `CreateDatabaseIfNotExists` / `CreateContainerIfNotExists`
are idempotent, so every instance can run it concurrently. Even so, leave it **off** in
production and provision from your deployment pipeline, where throughput, indexing and TTL are
reviewed rather than inherited from a default.

### Running against real Azure Cosmos DB

The application code in `Program.cs` needs no change. Swap the `CosmosClient` construction for
`DefaultAzureCredential`, drop `TrustSelfSignedCertificate`, point `Cosmos:Endpoint` at the
account, and set `AutoProvision = false`. Everything else — the batch, the discriminator, the
partition key, the dispatcher — is identical.

---

## 8. Troubleshooting

**`FAIL: Cannot reach a Cosmos account at 'https://localhost:8081/'`**

The emulator is not running. Start it from an **elevated** window (§4). It cannot be started from
a non-elevated process: Windows will show a UAC prompt, and in an automated session that prompt is
cancelled and the start silently fails.

**The emulator seems to start, then exits**

It needs a minute or two on first run to build its data files. If it exits immediately, another
instance is probably already running — check for `Microsoft.Azure.Cosmos.Emulator`,
`...GatewayService`, `...Master` and `...Server` processes. A healthy emulator has all four.

Note that `netstat` shows port 8081 owned by PID 4 (`System`), because the emulator registers with
HTTP.sys. A port-owner check is therefore a misleading way to decide whether it is up; probe the
endpoint instead.

**`The SSL connection could not be established`**

The emulator's certificate is not trusted on this machine. Either set
`Cosmos:TrustSelfSignedCertificate` to `true` (it already is in `appsettings.json`), or import the
certificate from the emulator's Data Explorer.

**`/health` returns 503 for a long time**

`AutoProvision` is still creating the container, or the emulator is still starting. The readiness
probe reads the container deliberately, so it only answers `200` once writes can actually succeed.

**`429 Too Many Requests` / `RequestRateTooLargeException`**

The container is provisioned at 400 RU/s. Start the emulator with `/DisableRateLimiting` as shown
in §4, or raise `ProvisionedThroughput`.

**Everything passes but the counts in §6 are higher than expected**

The counts are cumulative — the emulator keeps its data between runs. To start clean, delete the
`sales` database from the emulator's Data Explorer at
<https://localhost:8081/_explorer/index.html>.

---

## 9. Teardown

Stop the two `dotnet run` processes. To reclaim the data, delete the `sales` database from the
emulator's Data Explorer, or shut the emulator down entirely:

```powershell
# From an elevated window
& 'C:\Program Files\Azure Cosmos DB Emulator\Microsoft.Azure.Cosmos.Emulator.exe' /Shutdown
```

Nothing was created in Azure, so there is nothing to bill.
