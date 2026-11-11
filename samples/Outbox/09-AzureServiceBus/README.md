# Sample 09 — Azure Service Bus

The first sample that leaves your machine. Orders still commit to a local SQL Server, but the
outbox now dispatches to a real Azure Service Bus queue, and a separate consumer process receives
them.

The subject is **idempotent redelivery**. At-least-once means a message *will* eventually be sent
twice. This sample makes that happen on demand and shows the consumer receiving it exactly once,
because the outbox id becomes the broker's `MessageId` and the queue deduplicates on it.

---

## 1. What this demonstrates

- **The outbox id is the `MessageId`.** `ServiceBusMessageIdSource.OutboxId` is stable across
  every retry of one delivery, which is what makes the broker's duplicate detection usable.
- **A replayed send is silently discarded.** `POST /outbox/{id}/resend` sends an
  already-delivered record again with identical identifiers. The broker returns success; the
  consumer never sees it. This is the at-least-once producer meeting the exactly-once-ish
  consumer.
- **Identity, not connection strings.** The namespace has `disableLocalAuth: true`, so there is
  no SAS key to leak. Both processes authenticate with `DefaultAzureCredential` and the role
  assignments made by `infra\provision.ps1`.
- **Nothing on the wire is outbox-specific.** The consumer references only
  `Azure.Messaging.ServiceBus`. It reads `MessageId`, `CorrelationId`, `Subject` and a few
  application properties — ordinary Service Bus.
- **The transaction boundary is unchanged.** Service Bus is remote, slow and occasionally
  unreachable, and none of that is allowed to decide whether an order exists.

Unlike samples 01–08 there is **no `verify.ps1`**. Azure samples are driven by hand with
`sample.http` so that nothing can quietly provision billable resources.

---

## 2. Prerequisites

| What | Version used here | Notes |
| --- | --- | --- |
| .NET SDK | 10.0.402 | |
| SQL Server | any | `.\SQLEXPRESS` by default — the outbox store stays local |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| Azure CLI | 2.81.0 | `az login` with an account that can create resources |
| Bicep CLI | 0.49.2 | `az bicep install` |
| Azure subscription | — | `Microsoft.ServiceBus` must be registered (see §4) |

---

## 3. Cost — read this first

This sample creates a **Standard** Service Bus namespace, which is billed per hour whether or not
you send anything.

| Resource | Rate | If left running for a month |
| --- | --- | --- |
| Service Bus Standard namespace | ~0.0134 USD/hour | **~9.81 USD** |

Standard tier is required: **Basic does not support duplicate detection**, which is the entire
point of the sample. A 50 USD/month budget with alerts at 80% actual and 100% forecasted is
deployed alongside it, but a budget **alerts, it does not stop anything**.

When you are finished:

```powershell
.\infra\teardown.ps1
```

That deletes the whole resource group and is the only thing that stops the charge. Everything
else in this sample is free and local.

---

## 4. Setup

### 4.1 Provision Azure

```powershell
az login
az account set --subscription "<your subscription>"
az bicep install
az provider register --namespace Microsoft.ServiceBus --wait

cd samples\Outbox
.\infra\provision.ps1 -Samples 09
```

`provision.ps1` shows a what-if plan before it changes anything, then creates:

- resource group `rg-outbox-samples` in `southeastasia`,
- a Standard namespace named `sb-outbox-<hash>` (the hash is derived from the resource group id,
  so it is stable for you and unique globally),
- queue `order-events` with **10-minute duplicate detection**,
- topic `order-events-topic` (used by sample 10, harmless here),
- **Azure Service Bus Data Sender** and **Data Receiver** on your signed-in user,
- the 50 USD budget.

It prints the namespace FQDN at the end. Put it in both `appsettings.json` files if it differs
from the committed value:

- `09-AzureServiceBus\Publisher\appsettings.json`
- `09-AzureServiceBus\Consumer\appsettings.json`

> Role assignments propagate asynchronously. A 401 in the first minute after provisioning is
> usually just propagation — wait and retry before changing anything.

### 4.2 Create the local database

```powershell
$server = '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample09') IS NULL CREATE DATABASE OutboxSample09;"
```

The outbox schema and the `dbo.Orders` table are created by the sample on startup.

---

## 5. Run

Build once, then run both processes with `--no-build`.

```powershell
cd samples\Outbox\09-AzureServiceBus
dotnet build Publisher\Publisher.csproj
dotnet build Consumer\Consumer.csproj
```

```powershell
# Terminal 1 — the consumer. Keep it visible; it is the evidence.
dotnet run --project Consumer\Consumer.csproj --no-build
```

```powershell
# Terminal 2 — the publisher.
dotnet run --project Publisher\Publisher.csproj --no-build --no-launch-profile --urls http://localhost:5009
```

Then work through `sample.http`, or use the commands in §6.

---

## 6. What you should see

### Place an order

```powershell
$r = Invoke-RestMethod -NoProxy -Uri http://localhost:5009/orders -Method Post `
    -ContentType 'application/json' `
    -Body '{"tenantId":"dnv-maritime","customerId":"cust-9001","total":1499.50}'
$r
```

```
id        : 01a1c916-fcc3-709d-af9f-bb174295c03d
eventId   : 01a1c916-fcd0-7f53-b9c5-02f9a705616f
outboxId  : 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
```

The consumer prints it within a few seconds:

```
[13:31:40] RECEIVED #1
  MessageId (outbox id) : 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
  CorrelationId (event) : 01a1c916-fcd0-7f53-b9c5-02f9a705616f
  Subject (event type)  : OrderPlaced
  EnqueuedTime          : 05:31:39
  DeliveryCount         : 1
  [eventId] 01a1c916-fcd0-7f53-b9c5-02f9a705616f
  [eventVersion] 1
  [outboxId] 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
  [traceparent] 00-c0b33181a3ddebb594cf64e497be7a9c-47487cc9b3ad6cd2-00
  Body: {"orderId":"01a1c916-fcc3-709d-af9f-bb174295c03d","tenantId":"dnv-maritime",...}
```

`MessageId` equals `outboxId` — that is the whole mechanism in one line.

The row agrees:

```powershell
Invoke-RestMethod -NoProxy -Uri "http://localhost:5009/outbox/$($r.outboxId)"
```

```
outboxId    : 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
eventId     : 01a1c916-fcd0-7f53-b9c5-02f9a705616f
destination : billing
eventType   : OrderPlaced
status      : Delivered
attemptCount: 1
traceParent : 00-c0b33181a3ddebb594cf64e497be7a9c-47487cc9b3ad6cd2-00
deliveredAt : 2026-11-11T13:31:40.1523788+08:00
lastError   :
```

### Replay it — twice

```powershell
1..2 | ForEach-Object {
    Invoke-RestMethod -NoProxy -Method Post `
        -Uri "http://localhost:5009/outbox/$($r.outboxId)/resend"
}
```

```
outboxId  : 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
eventId   : 01a1c916-fcd0-7f53-b9c5-02f9a705616f
outcome   : Success
error     :
messageId : 01a1c916-fcd7-7d0c-a199-b9ac93a80ec4
note      : Sent again with the same MessageId. Inside the duplicate detection window the broker discards it.
```

**The consumer terminal does not change.** No `RECEIVED #2`. Two more messages were accepted by
the broker and both were dropped on arrival.

Note that `outcome` is `Success` for a message nobody will ever receive. The broker does not tell
the sender it discarded a duplicate — which is correct, because to the sender a duplicate and a
successful retry are the same event.

### Prove the queue is still live

A silent consumer could just mean a broken consumer, so place a *different* order:

```powershell
Invoke-RestMethod -NoProxy -Uri http://localhost:5009/orders -Method Post `
    -ContentType 'application/json' `
    -Body '{"tenantId":"dnv-energy","customerId":"cust-9002","total":275.00}'
```

```
[13:40:16] RECEIVED #2
  MessageId (outbox id) : 01a1c91e-fe58-7e1b-837a-bb3427637602
  CorrelationId (event) : 01a1c91e-fe58-705a-86c8-3a5d9918fc98
  Subject (event type)  : OrderPlaced
  DeliveryCount         : 1
  ...
```

New outbox id, not a duplicate, arrives immediately.

### Counters

```powershell
Invoke-RestMethod -NoProxy -Uri http://localhost:5009/outbox/stats
```

```
pending                    : 0
processing                 : 0
failed                     : 0
delivered                  : 2
deadLettered               : 0
oldestUndeliveredCreatedAt :
```

Two orders, two records, two consumer messages — and four sends. Resending does not create outbox
records; it replays an existing one.

---

## 7. How it works

### Registration

```csharp
builder.Services.AddSingleton(new ServiceBusClient(fullyQualifiedNamespace, credential));

builder.Services.AddOutbox()
    .UseSqlServer(options => { options.ConnectionString = connectionString; /* ... */ })
    .AddServiceBusDestination("billing", sb =>
    {
        sb.EntityPath = queueName;
        sb.MessageIdSource = ServiceBusMessageIdSource.OutboxId;
    })
    .AddDispatcher(d => { d.PollInterval = TimeSpan.FromSeconds(2); d.BatchSize = 20; });
```

`AddServiceBusDestination` **resolves** `ServiceBusClient` from DI and never constructs one. The
library therefore has no opinion about credentials, endpoints, retry policy or transport — all of
that is the application's `ServiceBusClient`, configured however the application likes.

### What lands on the message

| Service Bus property | Value | Why |
| --- | --- | --- |
| `MessageId` | outbox id | stable across retries; the duplicate-detection key |
| `CorrelationId` | event id | identifies the business event, not the delivery |
| `Subject` | event type (`OrderPlaced`) | lets a consumer route without parsing the body |
| `ApplicationProperties["outboxId"]` | outbox id | available even if `MessageIdSource` is changed |
| `ApplicationProperties["eventId"]` | event id | |
| `ApplicationProperties["eventVersion"]` | `1` | schema version for forward compatibility |
| `ApplicationProperties["traceparent"]` | W3C trace context | see sample 08 |
| Body | the serialized integration event | |

### Why `MessageIdSource.OutboxId` and not `EventId`

One event can be fanned out to several destinations (sample 03). Each destination gets its **own**
outbox record and its own outbox id, but they share an event id. If `MessageId` were the event id,
a fan-out to two Service Bus entities in the same namespace could be mistaken for a duplicate.
The outbox id is per-delivery, which is exactly the granularity duplicate detection needs.

### Why `/resend` is honest

The endpoint loads the stored `OutboxMessage` and calls the destination's `SendAsync` directly:

```csharp
var message = await store.GetAsync(outboxId, partitionKey: null, cancellationToken);
var destination = destinations.Single(d => d.Name == message.Destination);
var outcome = await destination.SendAsync(message, cancellationToken);
```

That is byte-for-byte what the dispatcher does on a retry. It is not a mock or a test hook — it is
the real failure mode: the send succeeded, the acknowledgement was lost, the claim expired, and
the record was picked up again.

> `IOutboxStore.RequeueAsync` is **not** used here. It returns a *dead-lettered* delivery to the
> queue and no-ops on anything else (see sample 04), so it cannot replay a delivered record.

### Duplicate detection is time-boxed

The queue is created with `requiresDuplicateDetection: true` and a **10-minute** window
(`duplicateDetectionHistoryTimeWindow: 'PT10M'`). Resend after 11 minutes and the message
**will** arrive a second time. That is not a bug — the broker only remembers so far back, and it
is why consumers must still be idempotent. Duplicate detection narrows the window; it does not
replace consumer-side idempotency.

To change it, edit `infra\modules\servicebus.bicep` and re-run `provision.ps1`. The window cannot
be changed on an existing queue — the queue has to be recreated.

### The credential chain is pinned

```csharp
new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    ExcludeVisualStudioCredential = true,
    ExcludeAzurePowerShellCredential = true,
    ExcludeInteractiveBrowserCredential = true,
})
```

This is not tidying. `DefaultAzureCredential` tries `VisualStudioCredential` **before**
`AzureCliCredential`, so on a machine where Visual Studio is signed in as a different account than
`az login` — an admin account, for instance — every send fails with `'Send' claim(s) are
required` even though the role assignment is correct and visible in the portal. Pinning the chain
makes the sample use the identity `provision.ps1` granted roles to.

`ManagedIdentityCredential` is still in the chain, so the same code works unchanged in Azure
Container Apps or App Service with a managed identity granted the same roles.

### The consumer

PeekLock, `AutoCompleteMessages = false`, and `CompleteMessageAsync` only after the handler
succeeds. That is the receiving half of at-least-once: crash mid-handler and the lock expires and
the message comes back, which is why `DeliveryCount` exists and why your handler must be
idempotent.

---

## 8. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `'Send' claim(s) are required` / `'Listen' claim(s) are required` | The token is for a different identity than the one holding the role. Run the credential check below. |
| Same error immediately after `provision.ps1` | Role assignment propagation. Wait a minute and retry. |
| `MessagingEntityNotFound` | `ServiceBus:Queue` does not match the provisioned queue, or you are pointed at the wrong namespace. |
| `Put token failed. status-code: 401` | `az login` has expired, or `az account set` is on a different subscription than the namespace. |
| Resend *does* arrive at the consumer | More than 10 minutes elapsed — the duplicate detection window closed. Expected. |
| Consumer prints nothing, publisher says `Delivered` | Another consumer is draining the same queue. Check for a stray terminal. |
| `Cannot open database "OutboxSample09"` | §4.2 was skipped. |
| Record stuck in `Failed` with a 401 | Fix the credential, then restart the publisher — the dispatcher retries with backoff automatically. |

To see which identity your code actually gets:

```powershell
az ad signed-in-user show --query "{id:id, upn:userPrincipalName}"
az role assignment list --scope "$(az servicebus namespace show -g rg-outbox-samples -n <namespace> --query id -o tsv)" `
    --query "[].{principal:principalId, role:roleDefinitionName}" -o table
```

The `principal` column must contain the `id` from the first command. Note that
`az role assignment list` at **resource group** scope does *not* show assignments made at the
namespace — pass the namespace id as above.

---

## 9. Teardown

```powershell
cd samples\Outbox
.\infra\teardown.ps1
```

It lists what will be deleted and makes you type the resource group name to confirm. Until you
run it the namespace keeps billing at roughly **9.81 USD/month**.

The local database costs nothing, but to reset the sample:

```powershell
sqlcmd -S .\SQLEXPRESS -Q "DROP DATABASE OutboxSample09;"
```
