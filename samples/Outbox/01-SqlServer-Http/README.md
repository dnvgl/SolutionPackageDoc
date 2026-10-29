# Sample 01 — SQL Server with ADO.NET and an HTTP destination

The smallest complete Outbox setup. Start here: every other sample assumes you have read this one.

## 1. What this demonstrates

- **A caller-owned transaction.** The application opens the `SqlConnection` and the
  `DbTransaction`; the outbox joins the transaction rather than owning one.
- **Transactional enqueue.** The business row in `dbo.Orders` and the outbox row in
  `outbox.OutboxMessages` commit together, or neither does.
- **The background dispatcher** polling the outbox table and delivering over HTTP.
- **W3C trace context** captured at enqueue, persisted in the outbox row, and replayed on the
  outgoing request — even though delivery happens later, in a different operation.
- **Idempotent identifiers.** The same `OutboxId` and `EventId` travel with every attempt, so a
  retry is recognisable to the receiver.

See the [library README](../../../../SolutionPackage/src/Outbox/README.md) for the full API.

## 2. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| .NET SDK | 10.0 or later | `dotnet --list-sdks` |
| SQL Server | any local edition | SQL Express is fine; LocalDB works with a changed connection string |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| PowerShell | 7.0 or later | `verify.ps1` requires `pwsh`, not Windows PowerShell |

The `SolutionPackage` repository must sit next to `SolutionPackageDoc`. If it does not, pass
`-p:SolutionPackageRoot=<path>` to `dotnet build`.

Ports **5001** (this sample) and **5100** (the shared receiver) must be free.

## 3. Cost

None. Everything runs locally.

## 4. Setup

Create the database. The tables are created by the application on startup.

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample01') IS NULL CREATE DATABASE OutboxSample01;"
```

If your instance is not `.\SQLEXPRESS`, set `OUTBOX_SAMPLES_SQL` to its name and update
`ConnectionStrings:Sales` in [`appsettings.json`](appsettings.json). `verify.ps1` reads the same
environment variable, so set it once and both agree.

## 5. Run

The quickest path is the smoke test, which starts everything, asserts the result and cleans up:

```powershell
cd samples\Outbox
pwsh .\01-SqlServer-Http\verify.ps1
```

To run it by hand instead, use two terminals:

```powershell
# Terminal 1 — the destination
dotnet run --project shared\Outbox.Samples.Receiver --urls http://localhost:5100
```

```powershell
# Terminal 2 — the sample
dotnet run --project 01-SqlServer-Http --urls http://localhost:5001
```

Both apps serve a browsable index at their root that lists their endpoints, so you can confirm
each one is up by opening it in a browser:

- <http://localhost:5001> — the sample
- <http://localhost:5100> — the receiver

Then place an order, either from [`sample.http`](sample.http) or with curl. Note `/orders` is
POST-only, so it cannot be exercised from the browser address bar:

```powershell
curl -X POST http://localhost:5001/orders -H "Content-Type: application/json" `
  -d '{"tenantId":"acme","customerId":"cust-1","total":99.50}'
```

## 6. What you should see

`verify.ps1` places five orders and asserts exactly five deliveries with five distinct outbox ids:

```
Checking SQL Server...
Starting receiver...
Starting sample API...
Placing 5 orders...
Waiting for the dispatcher to deliver...
PASS: 5 orders produced exactly 5 deliveries.
```

Placing a single order by hand returns the ids the outbox will use:

```json
{
  "id": "01a176e2-0006-735b-9252-a3f28430b21d",
  "outboxIds": ["01a176e2-0015-7101-bf80-824ef0f38145"],
  "eventId": "01a176e2-0010-7b03-b779-7c512f210bfb"
}
```

The sample's console shows the dispatcher claiming and delivering it:

```
info: DNV.Outbox.Hosting.OutboxDispatcher[3101]
      Outbox dispatcher CNSGHL25100648:5016:566ddd18 started with a batch size of 20.
dbug: DNV.Outbox.Hosting.OutboxDispatcher[3103]
      Claimed 1 deliveries for CNSGHL25100648:5016:566ddd18.
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a176e2-0015-7101-bf80-824ef0f38145 to receiver on attempt 1.
```

The claim owner (`CNSGHL25100648:5016:566ddd18`) is this node's identity. It matters in
[sample 05](../05-MultiNodeDispatcher/), where several nodes compete for the same table.

The receiver's console shows the same identifiers arriving:

```
info: Outbox.Samples.Receiver[0]
      Received outbox 01a176e2-0015-7101-bf80-824ef0f38145 event 01a176e2-0010-7b03-b779-7c512f210bfb type OrderPlaced attempt 1 traceparent 00-0f6f4781ee2dbb815b5383b543e947d1-a235cafd712e8d8d-00
```

And `GET http://localhost:5100/deliveries` returns the delivery in full:

```json
[{
  "outboxId": "01a176e2-0015-7101-bf80-824ef0f38145",
  "eventId": "01a176e2-0010-7b03-b779-7c512f210bfb",
  "eventType": "OrderPlaced",
  "eventVersion": "1",
  "destination": "receiver",
  "attempt": "1",
  "traceParent": "00-0f6f4781ee2dbb815b5383b543e947d1-a235cafd712e8d8d-00",
  "body": "{\"orderId\":\"01a176e2-0006-735b-9252-a3f28430b21d\",\"tenantId\":\"acme\",\"customerId\":\"cust-1\",\"total\":99.50,\"currency\":\"USD\",\"placedAt\":\"2026-10-26T06:24:45.0624694+00:00\"}"
}]
```

In the database, every row ends up delivered on its first attempt:

```powershell
sqlcmd -S $server -d OutboxSample01 -Q "SELECT Status, AttemptCount, COUNT(*) AS Cnt FROM outbox.OutboxMessages GROUP BY Status, AttemptCount;"
```

```
Status  AttemptCount  Cnt
------  ------------  ---
3       1             5
```

`Status = 3` is *delivered*. The `TraceParent` column holds the trace context that was replayed
on the outgoing request.

## 7. How it works

The entire point of the sample is this block in [`Program.cs`](Program.cs):

```csharp
await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync(cancellationToken);
await using DbTransaction transaction = await connection.BeginTransactionAsync(cancellationToken);

// ... INSERT INTO dbo.Orders ... using the same connection and transaction ...

// The producer is bound to the transaction the caller already owns. There is no unbound
// IOutbox, because an outbox write outside the business transaction would break atomicity.
var outbox = sessionFactory.ForTransaction(connection, transaction);

var messages = await outbox.EnqueueAsync(
	order.ToIntegrationEvent(),
	new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
	cancellationToken);

// Business row and outbox row commit together, or neither does.
await transaction.CommitAsync(cancellationToken);
```

`CommitAsync` is the atomic boundary. Before it, nothing is durable; after it, both the order and
its outbox record are. There is no window in which the order exists but the event was never
recorded, and none in which an event was recorded for an order that was rolled back. That is the
guarantee the outbox pattern exists to provide, and it comes entirely from both writes sharing one
transaction.

`EnqueueAsync` only *records* the message. Delivery is a separate concern, handled later by the
dispatcher registered in the same file:

```csharp
builder.Services.AddOutbox()
	.UseSqlServer(options => { /* store */ })
	.AddHttpDestination("receiver", http => { /* destination */ })
	.AddDispatcher(dispatcher =>
	{
		// Aggressive for a demo. Production defaults are far less chatty.
		dispatcher.PollInterval = TimeSpan.FromSeconds(1);
		dispatcher.BatchSize = 20;
	});
```

The `"receiver"` string in `OutboxEnqueueRequest` matches the name given to `AddHttpDestination`.
That is how a message is routed — see [sample 03](../03-MultipleDestinations/) for fan-out to
several destinations at once.

`EnsureCreatedAsync()` creates the outbox table at startup. That is a development convenience;
production applies the versioned scripts from a deployment pipeline. [Sample 02](../02-EntityFrameworkCore/)
shows the migration route.

## 8. Troubleshooting

**The browser shows 404**
ASP.NET Core returns 404 for any path that is not mapped. Both apps now map a root index listing
their endpoints, so <http://localhost:5001> and <http://localhost:5100> should return JSON — if
either 404s, you are running a build from before that index was added, so rebuild. A 404 or 405 on
<http://localhost:5001/orders> is expected regardless: that route is POST-only and the browser
address bar issues a GET. Use `sample.http` or curl instead.

**`Cannot reach SQL Server using 'Server=...'`**
SQL Server is not running or the database does not exist. Check the service, then re-run the
Setup step. `Login failed for user` with a `Cannot open database "OutboxSample01" requested by the
login` prefix means the instance is reachable but the database was never created.

**`Timed out waiting for http://localhost:5100/health`**
Usually one of three things:

- A proxy. If `HTTP_PROXY` is set and `NO_PROXY` does not exclude localhost, `Invoke-RestMethod`
  tunnels loopback traffic through the proxy and hangs. `verify.ps1` passes `-NoProxy` for this
  reason; if you write your own scripts against these samples, do the same.
- A cold build. The first run after changing dependencies has to restore and compile before the
  server listens. Run `dotnet build` once beforehand.
- Port 5100 already in use. `Get-NetTCPConnection -LocalPort 5100` names the owner.

**`CS8805: Program using top-level statements must be an executable`**
The project file lost its `Microsoft.NET.Sdk.Web` SDK attribute. These samples are web apps and
need the Web SDK, not `Microsoft.NET.Sdk`.

**`NU1903: Package 'System.Security.Cryptography.Pkcs' has a known high severity vulnerability`**
`Microsoft.Data.SqlClient` 7.1.1 resolves a vulnerable version transitively, and these samples
build with `TreatWarningsAsErrors`. [`Directory.Build.props`](../Directory.Build.props) pins a
patched version; remove that pin once the driver ships a release that no longer needs it.

**`The DNV Outbox library was not found at '...'`**
`SolutionPackage` is not a sibling of `SolutionPackageDoc`. Pass
`-p:SolutionPackageRoot=<path-to-SolutionPackage>`.

**Orders are accepted but nothing is delivered**
The receiver is not running, or `Outbox:ReceiverEndpoint` does not match its URL. Rows sit in
`outbox.OutboxMessages` with `Status = 0` and a rising `AttemptCount`. [Sample 04](../04-RetryAndDeadLetter/)
covers what happens next.

## 9. Teardown

Stop both processes with Ctrl+C, then drop the database:

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample01') IS NOT NULL DROP DATABASE OutboxSample01;"
```
