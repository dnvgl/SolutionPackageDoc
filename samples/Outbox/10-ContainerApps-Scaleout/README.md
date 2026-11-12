# Sample 10 — Container Apps scale-out

Several replicas of the same service run the same dispatcher against the same outbox table, and
every record is still delivered exactly once.

This is the sample that answers the question samples 01–09 deliberately avoided: *what happens
when you scale the producer out?* Samples 01–09 run a single process, where the correctness of
the dispatcher is uninteresting because there is nobody to race. Here there are two replicas
polling one Azure SQL table every two seconds, and the only thing standing between you and
duplicate deliveries is the claim protocol in `SqlOutboxStore`.

> This sample runs **in Azure** and **costs money**. Read §3 before provisioning.

---

## 1. What this demonstrates

- **Work sharing without coordination.** Two replicas, no leader election, no distributed lock
  service, no partition assignment. Each replica claims a batch with a single atomic
  `UPDATE … OUTPUT` and the other one simply does not see those rows.
- **Exactly one delivery per record, proven by counting.** The `Verifier` project drains the
  Service Bus subscription and counts messages by their **outbox id**. 100 orders must produce
  100 messages and 100 distinct ids.
- **The counter is proven to work.** `POST /outbox/{id}/resend` replays a record on purpose and
  the verifier fails. A verifier that has only ever printed PASS has proven nothing.
- **Killing a replica mid-flight loses nothing and duplicates nothing.** Records claimed by a
  dead replica are redelivered by the survivor once the claim expires.
- **Managed identity end to end.** No connection string secret, no Service Bus key, no registry
  password. SQL, Service Bus and ACR are all reached with a user-assigned identity.

Unlike samples 01–08 there is **no `verify.ps1`**. Azure samples are driven by hand with
`sample.http` so that nothing can quietly provision billable resources.

---

## 2. Prerequisites

| What | Version used here | Notes |
| --- | --- | --- |
| .NET SDK | 10.0.403 | |
| Docker | 29.1.2 | must be running — the image is built and smoke-run locally before it is pushed |
| Azure CLI | 2.81.0 | `az login` with an account that can create resources |
| `containerapp` extension | any | `az extension add --name containerapp` |
| An Azure subscription | — | with quota for Container Apps in your region |

**Pin the subscription before you start.** On a machine with several subscriptions the CLI's
active one drifts, and the failure mode is a baffling `ResourceGroupNotFound` for a resource
group you are looking at in the portal:

```powershell
az account set --subscription <subscription-id>
az account show --query "{name:name, id:id}" -o table
```

`deploy.ps1` takes `-SubscriptionId` and prints what it is using, for the same reason.

---

## 3. Cost — read this first

| Resource | SKU | Cost while running |
| --- | --- | --- |
| Azure SQL Database | General Purpose serverless, 1 vCore, **free offer** | 0 USD for the first 100 000 vCore-seconds/month, then auto-paused |
| Container Apps | 2 replicas × 0.25 vCPU / 0.5 GiB, always on | ~11 USD/month |
| Container Registry | Basic | ~5 USD/month |
| Service Bus | Standard | ~10 USD/month |
| Log Analytics | pay-as-you-go ingestion | a few cents for this sample |

**`provision.ps1` prints ~52.88 USD/month** for samples 09 + 10 together. That is a deliberately
pessimistic figure — everything always on, free limits ignored — and it **exceeds the 50 USD
budget alert** the infra scripts create, so expect the alert to fire if you leave it up. The
realistic cost for working through this sample is in the 11–38 USD/month range, and nothing at
all once you tear it down.

Two Container Apps settings carry most of the bill:

- **`minReplicas: 2`.** The whole point of the sample is concurrent dispatchers, so scale-to-zero
  is off and you pay for two replicas continuously. Set `minReplicas` to 0 in
  `infra\modules\containerapps.bicep` when you are done reading and the compute cost goes away.
- **0.25 vCPU / 0.5 GiB per replica.** 0.5 vCPU would roughly double the compute line for no
  additional insight.

The SQL database uses the **free offer** (`useFreeLimit`), with
`freeLimitExhaustionBehavior: AutoPause` — when the free vCore-seconds run out the database
pauses instead of billing you. `provision.ps1` reads these three settings back off the live
database after deployment and **fails** if Azure did not grant them, because a silently
non-free database is an expensive thing to discover at the end of the month.

**Teardown is §9. Do it.**

---

## 4. Setup

### 4.1 Provision the infrastructure

```powershell
cd samples\Outbox
.\infra\provision.ps1 -Samples 10 -SubscriptionId <subscription-id>
```

This creates the Service Bus namespace, the Azure SQL server and database, and the container
registry. It does **not** create the container app yet — see §7 for why.

### 4.2 Build, push and deploy

```powershell
cd samples\Outbox\10-ContainerApps-Scaleout
.\deploy.ps1 -SubscriptionId <subscription-id>
```

`deploy.ps1` does five things in order:

1. Publishes the app as a Linux container image.
2. **Runs that image locally with `OUTBOX_SMOKE=1`** and requires it to print `smoke ok`.
3. Pushes it to the registry.
4. Re-runs `provision.ps1 -ContainerImage <tag>`, which now creates the container app.
5. Prints the FQDN and the replica list.

Step 2 is not ceremony. Building a Linux image from Windows is easy to get subtly wrong, and
every such mistake otherwise shows up for the first time in Azure as a crash-looping revision
with no useful logs. Two seconds locally beats five minutes of guessing.

Take the FQDN it prints and put it at the top of `sample.http`.

---

## 5. Run

Everything runs in Azure. The only thing on your machine is the verifier.

```powershell
# Terminal 1 — empty the subscription first, so leftovers are not counted as part of this run.
cd samples\Outbox\10-ContainerApps-Scaleout\Verifier
dotnet run --drain true

# Terminal 1 — now start counting, and refuse to pass unless 100 messages arrive.
dotnet run --idle 45 --expect 100

# Terminal 2 — enqueue the burst.
$app = 'https://<your-app>.azurecontainerapps.io'
(Invoke-RestMethod -NoProxy -Method Post "$app/orders/bulk?count=100").count
```

---

## 6. What you should see

### Both replicas take work

```powershell
Invoke-RestMethod -NoProxy "$app/node"
Invoke-RestMethod -NoProxy "$app/node"
```

Ingress round-robins, so repeated calls return different `replica` values. That proves the
ingress is balanced; it does not prove the **dispatchers** are both working. For that, ask Log
Analytics:

```powershell
$ws = az monitor log-analytics workspace show -g rg-outbox-samples -n log-outbox-samples `
    --only-show-errors --query customerId -o tsv

$kql = "ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(40m)
| where Log_s has 'deliveries for'
| extend Claimed = toint(extract(@'Claimed ([0-9]+) deliveries', 1, Log_s)),
         Replica = extract(@'deliveries for ([^\s.]+)', 1, Log_s)
| where Claimed > 0
| summarize batches = count(), deliveries = sum(Claimed) by Replica
| order by deliveries desc" -replace "`r`n", ' '

az monitor log-analytics query -w $ws --analytics-query $kql --only-show-errors -o table
```

```
Replica                                      Batches    Deliveries
-------------------------------------------  ---------  ------------
ca-outbox-scaleout--0000003-f895d7dc7-7n727  4          65
ca-outbox-scaleout--0000003-f895d7dc7-xdcjn  3          35
```

**65 + 35 = 100.** Both replicas claimed work, the split is uneven (whoever polls first wins the
batch — there is no fairness guarantee and none is needed), and the total is exactly the number
of orders enqueued.

> The split being uneven is the expected result, not a defect. Any run where one replica takes
> all 100 is also valid — it just means the other one was between polls.

### The count

```
RESULT
  messages received : 100
  distinct ids      : 100
  duplicated ids    : 0

PASS - every outbox record reached the topic exactly once.
```

### What lands on the message

```
First message:
  MessageId     : 613ce01c05ca47feba967b3ad8b0df3d  (Dapr's own, changes on every publish)
  CloudEvents id: 01a1cdc8-4bc8-7167-ae9b-db0db227ef0d  (the outbox id - this is what gets counted)
  Properties    : cloudevent.id=01a1cdc8-4bc8-7167-ae9b-db0db227ef0d,
                  cloudevent.type=OrderPlaced,
                  cloudevent.traceparent=00-da9a94da7fdba15ae9114d87191c59a3-1e58f6d257b2edb7-00,
                  outboxEventId=01a1cdc8-4bc7-71c1-87eb-a7c3882760d1,
                  outboxEventVersion=1
```

Read those two ids carefully, because the difference between them is the whole sample:

- **`MessageId` is Dapr's.** It is a fresh GUID on every publish call. Two dispatches of the same
  outbox record get two different `MessageId`s.
- **`cloudevent.id` is the outbox id.** The outbox sets it and it is stable across every retry.

An earlier version of the verifier counted `MessageId`. It passed — and it would have passed
just as happily if every record had been dispatched twice, because each dispatch carries a new
`MessageId`. Counting the wrong identifier produces a test that cannot fail.

### Prove the verifier can fail

```powershell
dotnet run --idle 30            # terminal 1

$id = (Invoke-RestMethod -NoProxy -Method Post "$app/orders").outboxId
1..2 | ForEach-Object { (Invoke-RestMethod -NoProxy -Method Post "$app/outbox/$id/resend").outcome }
```

```
RESULT
  messages received : 2
  distinct ids      : 1
  duplicated ids    : 1
    01a1cdc8-4b5e-7f88-bc02-731ef15e1fd6 delivered 2 times

FAIL - the same outbox record was delivered more than once.
```

The verifier exits **1**. `/resend` calls the destination's `SendAsync` with the stored record —
byte for byte what the dispatcher does on a retry — so this is the real double-dispatch, not a
simulation of one.

### Kill a replica mid-burst

```powershell
dotnet run --idle 90 --expect 100     # terminal 1

(Invoke-RestMethod -NoProxy -Method Post "$app/orders/bulk?count=100").count
$rev = az containerapp show -g rg-outbox-samples -n ca-outbox-scaleout `
    --only-show-errors --query properties.latestRevisionName -o tsv
az containerapp revision restart -g rg-outbox-samples -n ca-outbox-scaleout --revision $rev --only-show-errors
```

Still `100 received, 100 distinct, 0 duplicated`.

**Use `--idle 90`, not 45.** Rows claimed by a replica that died are invisible to everyone else
until the claim expires, and `ClaimDuration` is 60 seconds. Delivery of the orphaned batch
therefore resumes roughly a minute after the restart, and a 45-second window closes before it
arrives — the verifier reports `0 received` and fails, which looks alarming and is in fact the
claim protocol working correctly. This is the trade-off `ClaimDuration` encodes: a long duration
means slow recovery from a dead node, a short one risks two nodes working the same row.

---

## 7. How it works

### Registration

```csharp
builder.Services.AddDaprPubSubClient("billing", o => { o.PubSubName = pubSubName; o.TopicName = topicName; });

builder.Services.AddOutbox()
    .UseSqlServer(options => { options.ConnectionString = connectionString; /* ... */ })
    .AddDaprDestination("billing", dapr => { /* ... */ })
    .AddDispatcher(dispatcher =>
    {
        dispatcher.InstanceId = replicaName;                     // CONTAINER_APP_REPLICA_NAME
        dispatcher.PollInterval = TimeSpan.FromSeconds(2);
        dispatcher.BatchSize = 20;
        dispatcher.ClaimDuration = TimeSpan.FromSeconds(60);
    });
```

**Nothing here is scale-out-specific except `InstanceId`,** and even that is only for the
evidence. The identical registration in sample 07 running on one node is already safe on ten.
That is the point: scaling out the producer requires no code change.

### How two dispatchers avoid each other

`SqlOutboxStore.ClaimAsync` claims a batch in one statement:

```sql
WITH [candidates] AS (
    SELECT TOP (@BatchSize) *
    FROM outbox.OutboxMessages WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE [Status] = 0
       OR ([Status] = 2 AND [NextAttemptAt] IS NOT NULL AND [NextAttemptAt] <= @Now)
       OR ([Status] = 1 AND [ClaimExpiresAt] IS NOT NULL AND [ClaimExpiresAt] <= @Now)
    ORDER BY [CreatedAt], [OutboxId]
)
UPDATE [candidates]
SET [Status] = 1, [ClaimOwner] = @Owner, [ClaimExpiresAt] = @ClaimExpiresAt, ...
OUTPUT inserted.*;
```

Four details do all the work:

- **`READPAST`** skips rows another transaction has locked instead of waiting for them. Replica B
  does not block on replica A's batch; it walks past it and takes the next 20 rows.
- **`UPDLOCK`** takes the update lock during the read, closing the window where both replicas read
  the same row as `Pending` before either writes.
- **`ClaimExpiresAt`** is what makes a crashed replica recoverable. The claim is a lease, not
  ownership: the third `WHERE` clause re-admits rows still marked `Processing` whose lease has
  passed. That is exactly the behaviour the restart test depends on, and the reason that test
  needs a 90-second window.
- **Every later transition is conditional on the claim owner and the `rowversion`**, so a replica
  whose claim expired and was stolen cannot overwrite the new owner's result when it comes back.

`ClaimOwner` is set on claim and **cleared by `CompleteAsync`**, so a delivered row does not
remember which replica sent it. That is why the work-sharing evidence in §6 comes from the
dispatcher's log line rather than from a column.

### `InstanceId` is the replica name

```csharp
var replicaName =
    Environment.GetEnvironmentVariable("CONTAINER_APP_REPLICA_NAME")
    ?? Environment.GetEnvironmentVariable("HOSTNAME")
    ?? Environment.MachineName;
```

`CONTAINER_APP_REPLICA_NAME` is the name `az containerapp replica list` prints, so a claim owner
in the database and a row in the portal are the same string. `HOSTNAME` is the fallback for a
plain `docker run`. Without this the default `InstanceId` is a machine name that is unique but
meaningless.

The dispatcher logs claims at **Debug**, so `appsettings.json` sets:

```json
"Logging": { "LogLevel": { "DNV.Outbox.Hosting": "Debug" } }
```

### The topic has duplicate detection switched OFF, deliberately

Sample 09's queue has `requiresDuplicateDetection: true` with a 10-minute window, and that is the
right production setting. Here it would destroy the test. Broker-side dedup would swallow a
genuine double dispatch and the verifier would print PASS — the sample would be incapable of
detecting the one defect it exists to detect.

`scaleout-events` therefore has no dedup, and every message the dispatchers emit reaches the
subscription. Any duplicate is the outbox's fault and the verifier says so.

### No placeholder image

`main.bicep` has `needsContainerApps = contains(samples, '10') && !empty(containerImage)`. The
first `provision.ps1` run creates the registry but no app; `deploy.ps1` pushes an image and
re-runs provisioning with the tag.

The alternative — create the app with a placeholder image and update it later — produces a first
revision that fails its health probe, and a revision failing a health probe for a benign reason
is indistinguishable from one failing for a real one.

### A user-assigned identity, not a system-assigned one

A system-assigned identity does not exist until the container app is created, so `AcrPull`
cannot be granted before the app's first image pull — and the first revision dies pulling the
image it was just created to run. A user-assigned identity is created first, granted `AcrPull`
and `Azure Service Bus Data Sender` up front, and then attached. It also gives the Dapr component
an explicit `azureClientId`.

### Connecting to SQL with that identity

Two things must both be right, and each fails at runtime with a message that does not obviously
point at the cause.

**1. The connection string must name the identity:**

```
Authentication=Active Directory Managed Identity;User Id=<client-id>
```

`Active Directory Default` looks for a **system-assigned** identity, which does not exist here,
and fails with a generic authentication error.

**2. The app must reference `Microsoft.Data.SqlClient.Extensions.Azure`:**

```xml
<PackageReference Include="Microsoft.Data.SqlClient.Extensions.Azure" Version="7.1.1" />
```

`Microsoft.Data.SqlClient` 7 moved the Entra authentication providers into that package. Without
it the connection string parses fine and then throws at connect time:

```
Cannot find an authentication provider for 'ActiveDirectoryDefault'
```

The version must match the `Microsoft.Data.SqlClient` pin in `src\Directory.Packages.props`.

### `disableEntityManagement: 'true'` on the Dapr component

The identity holds **Data Sender** only. Dapr's default behaviour is to create the topic and
subscription if they are missing, which needs **Manage**. Leaving entity management on makes the
component fail at init with what reads like an RBAC misconfiguration. The topic is created by
Bicep, so Dapr has nothing to manage.

### `OUTBOX_SMOKE`

```csharp
if (Environment.GetEnvironmentVariable("OUTBOX_SMOKE") == "1")
{
    Console.WriteLine($"smoke ok: {Environment.Version} on {RuntimeInformation.OSArchitecture}");
    return 0;
}
```

Proves the image starts, on the right architecture, without needing a database.

> Adding any `return N;` to a top-level-statements program makes the entry point `int`-returning,
> so an explicit `return 0;` after `app.Run()` is required or you get `CS0161`.

---

## 8. Troubleshooting

| Symptom | Cause |
| --- | --- |
| `ResourceGroupNotFound` for a group you can see in the portal | The CLI's active subscription drifted. `az account set --subscription <id>`, or pass `-SubscriptionId`. |
| Revision crash-loops with `Cannot find an authentication provider for 'ActiveDirectoryDefault'` | `Microsoft.Data.SqlClient.Extensions.Azure` is missing, or the connection string says `Active Directory Default` instead of `Active Directory Managed Identity`. |
| Verifier reports `0 received` after a replica restart | The 60-second claims have not expired yet. Use `--idle 90`. |
| Verifier reports `0 received` otherwise | The dispatcher is not running, or a stray verifier terminal is draining the subscription. Check `GET /outbox/stats`. |
| Verifier says PASS but you expected messages | You forgot `--expect`. A run with `--expect 0` that receives nothing now fails, but pass the real number. |
| Only one replica ever appears in the Log Analytics query | Logs take 1–3 minutes to land. Widen `ago()` and retry. |
| `MSB3027`/`MSB3021` building the solution | A sample from an earlier session is still running and holding `bin\`. Stop it. |
| `az containerapp` output has warnings mixed into it | Pass `--only-show-errors`; the extension writes warnings to stderr. |
| Image runs locally but fails opaquely in Azure | It was built for Windows. `-r linux-x64 --self-contained false` is mandatory for `/t:PublishContainer`. |

---

## 9. Teardown

```powershell
cd samples\Outbox
.\infra\teardown.ps1 -ResourceGroup rg-outbox-samples
```

This deletes the Container Apps environment, the registry **and every image in it**, the SQL
server and the Service Bus namespace. Until you run it, the container app bills for two replicas
around the clock.
