# Sample 02 — Entity Framework Core producer

Sample 01 wrote the outbox row with ADO.NET inside a transaction the application opened by hand.
This sample does the same thing through the application's own `DbContext`, so the atomic boundary
becomes an ordinary `SaveChangesAsync`.

Read [sample 01](../01-SqlServer-Http/README.md) first.

## 1. What this demonstrates

- **`ApplyOutboxConfiguration`** putting the outbox table into *your* EF model, so one migration
  creates the business tables and the outbox table together.
- **Enqueue inside `SaveChangesAsync`.** The producer only stages entities in the change tracker.
  There is no `SavingChanges` interceptor and no library-owned transaction, so the application
  keeps full control of when and how it commits.
- **A producer and a dispatcher that disagree about technology but agree about a table.** Rows are
  written by EF Core and claimed by the ADO.NET `SqlOutboxStore`. `verify.ps1` asserts this.
- **Adopting an existing outbox table** that script `001` created outside EF, using the manual
  `002` baseline script.

See the [library README](../../../../SolutionPackage/src/Outbox/README.md) for the full API.

## 2. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| .NET SDK | 10.0 or later | `dotnet --list-sdks` |
| SQL Server | any local edition | SQL Express is fine; LocalDB works with a changed connection string |
| `sqlcmd` | any | ships with the SQL Server Client SDK |
| PowerShell | 7.0 or later | `verify.ps1` requires `pwsh`, not Windows PowerShell |
| `dotnet-ef` | 10.0.12 | **local** tool, restored by `dotnet tool restore` — see below |

The `SolutionPackage` repository must sit next to `SolutionPackageDoc`. If it does not, pass
`-p:SolutionPackageRoot=<path>` to `dotnet build`.

Ports **5002** (this sample) and **5100** (the shared receiver) must be free.

### The `dotnet-ef` version matters

EF Core tooling refuses to work with a runtime newer than itself, and many machines still have a
global `dotnet-ef` 8.x. This samples tree therefore pins the tool locally in
[`dotnet-tools.json`](../dotnet-tools.json). Restore it once:

```powershell
cd samples\Outbox
dotnet tool restore
dotnet ef --version     # Entity Framework Core .NET Command-line Tools / 10.0.12
```

You only need the tool to *create* migrations. Running the sample does not require it — the
migration is already checked in and is applied by the application at startup.

## 3. Cost

None. Everything runs locally.

## 4. Setup

Create the empty database. Unlike sample 01, the **tables** come from an EF migration that the
application applies on startup, not from `SqlOutboxSchemaInitializer`.

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample02') IS NULL CREATE DATABASE OutboxSample02;"
```

If your instance is not `.\SQLEXPRESS`, set `OUTBOX_SAMPLES_SQL` to its name and update
`ConnectionStrings:Sales` in [`appsettings.json`](appsettings.json). `verify.ps1` reads the same
environment variable, so set it once and both agree.

## 5. Run

The quickest path is the smoke test, which starts everything, asserts the result and cleans up:

```powershell
cd samples\Outbox
pwsh .\02-EntityFrameworkCore\verify.ps1
```

To run it by hand instead, use two terminals:

```powershell
# Terminal 1 — the destination
dotnet run --project shared\Outbox.Samples.Receiver --urls http://localhost:5100
```

```powershell
# Terminal 2 — the sample
dotnet run --project 02-EntityFrameworkCore --urls http://localhost:5002
```

Both apps serve a browsable index at their root that lists their endpoints, so you can confirm
each one is up by opening it in a browser:

- <http://localhost:5002> — the sample
- <http://localhost:5100> — the receiver

Then place an order, either from [`sample.http`](sample.http) or with curl. Note `/orders` is
POST-only, so it cannot be exercised from the browser address bar:

```powershell
curl -X POST http://localhost:5002/orders -H "Content-Type: application/json" `
  -d '{"tenantId":"acme","customerId":"cust-1","total":99.50}'
```

## 6. What you should see

`verify.ps1` places five orders and asserts both halves of the story — five deliveries arrived,
and the rows behind them really are in the dispatcher's table:

```text
Checking SQL Server...
Starting receiver...
Starting sample API...
Placing 5 orders...
Waiting for the dispatcher to deliver...
Checking the EF-written rows are in the dispatcher table...
PASS: 5 orders produced exactly 5 deliveries; 5 order rows and 5 delivered outbox rows agree.
```

Placing an order by hand returns the identifiers that make a retry idempotent:

```json
{
  "id": "01a1816a-ab2f-7b6e-860a-0a3183371f70",
  "outboxIds": ["01a1816a-ab9e-7c88-8797-ad2dc365a5be"],
  "eventId": "01a1816a-ab98-71ca-a55a-19162b41939e"
}
```

The sample's console shows the migration being checked, then the dispatcher doing its work:

```text
info: Microsoft.EntityFrameworkCore.Migrations[20411]
      Acquiring an exclusive lock for migration application. See https://aka.ms/efcore-docs-migrations-lock for more information if this takes too long.
info: Microsoft.EntityFrameworkCore.Migrations[20405]
      No migrations were applied. The database is already up to date.
info: DNV.Outbox.Hosting.OutboxDispatcher[3101]
      Outbox dispatcher CNSGHL25100648:32492:5f0cc61a started with a batch size of 20.
info: Microsoft.Hosting.Lifetime[14]
      Now listening on: http://localhost:5002
dbug: DNV.Outbox.Hosting.OutboxDispatcher[3103]
      Claimed 1 deliveries for CNSGHL25100648:32492:5f0cc61a.
info: System.Net.Http.HttpClient.outbox-http.ClientHandler[101]
      Received HTTP response headers after 2108.784ms - 204
dbug: DNV.Outbox.Hosting.OutboxDeliveryProcessor[3001]
      Delivered 01a1816a-ab9e-7c88-8797-ad2dc365a5be to receiver on attempt 1.
```

On the first run against a fresh database you will instead see `Applying migration
'20261028072659_InitialCreate'`.

`GET http://localhost:5100/deliveries` shows the trace context survived the hop from the enqueueing
request to the much later delivery:

```json
[{
  "outboxId": "01a1816a-ab9e-7c88-8797-ad2dc365a5be",
  "eventId": "01a1816a-ab98-71ca-a55a-19162b41939e",
  "eventType": "OrderPlaced",
  "eventVersion": "1",
  "destination": "receiver",
  "attempt": "1",
  "traceParent": "00-4dcccce5c82d20d06897cf77edd7038d-0e42d1339d5b241a-00",
  "body": "{\"orderId\":\"01a1816a-ab2f-7b6e-860a-0a3183371f70\",\"tenantId\":\"acme\",\"customerId\":\"cust-1\",\"total\":99.50,\"currency\":\"USD\",\"placedAt\":\"2026-10-28T07:30:13.9359731+00:00\"}",
  "receivedAt": "2026-10-28T07:30:16.5268169+00:00"
}]
```

## 7. How it works

### The atomic boundary moved

| | Sample 01 | This sample |
| --- | --- | --- |
| Who opens the transaction | the application, explicitly | EF Core, inside `SaveChangesAsync` |
| How the outbox joins it | `sessionFactory.ForTransaction(connection, transaction)` | the outbox entity is in the change tracker |
| What commits it | `await transaction.CommitAsync()` | `await context.SaveChangesAsync()` |
| Who owns the schema | `SqlOutboxSchemaInitializer` (script `001`) | an EF migration |

Both are atomic. The difference is only who holds the transaction, which is why the library
offers both: an application that already uses EF should not have to drop to ADO.NET to get an
outbox, and an application that does not use EF should not have to adopt it.

### Two halves, one table

```csharp
builder.Services.AddOutbox()
    .UseSqlServer(...)                  // dispatcher side: claims and completes rows
    .UseEntityFrameworkCore<SalesContext>()  // producer side: stages rows in the change tracker
    .AddHttpDestination("receiver", ...)
    .AddDispatcher(...);
```

`UseEntityFrameworkCore` registers the scoped `IOutbox`; `UseSqlServer` registers the singleton
`IOutboxStore`. They never talk to each other — they agree because both are pointed at
`outbox.OutboxMessages`. Change the schema or table name in one and you must change it in the
other, or the dispatcher will poll an empty table forever.

### The endpoint

```csharp
context.Orders.Add(new OrderRecord { ... });

var messages = await outbox.EnqueueAsync(
    order.ToIntegrationEvent(),
    new OutboxEnqueueRequest(["receiver"], eventType: nameof(OrderPlaced), eventVersion: 1),
    cancellationToken);

// Business rows and outbox rows in one transaction.
await context.SaveChangesAsync(cancellationToken);
```

Note the ordering is irrelevant: `EnqueueAsync` only calls `context.Add`. Nothing reaches the
database until `SaveChangesAsync`, so there is no window in which one write exists without the
other.

### The table EF generates

The migration produces the same columns the ADO.NET store expects, including the `rowversion`
concurrency token that makes every dispatcher state transition conditional. It does **not**
reproduce the hand-written extras from script `001` — the clustered index on `CreatedAt`, the
filtered claim and retention indexes, and the `CHECK` constraints on `Status` and `EventVersion`.
Everything works without them; at scale, add them in a follow-up migration.

### Adopting a table EF did not create

`GET /baseline-script` prints the `002` script for the opposite situation: the outbox table already
exists because script `001` created it, and you now want EF migrations to own further changes.

```sql
IF OBJECT_ID(N'[outbox].[OutboxMessages]', N'U') IS NULL
BEGIN
    THROW 51001, N'The outbox table does not exist. Apply 001_CreateOutbox.sql before baselining EF Core history.', 1;
END;
...
INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
VALUES (N'20260101000000_AdoptExistingOutbox', N'10.0.12');
```

Two things are deliberate:

- **It is never applied automatically.** `SqlOutboxSchemaInitializer.EnsureCreatedAsync` explicitly
  skips it. Writing to `__EFMigrationsHistory` is a decision about *your* migration history, not
  about the outbox, so the library will not make it for you. You fetch the text and your
  deployment pipeline runs it once.
- **It fails loudly rather than lying.** `THROW 51001` if the table is missing, `THROW 51002` if
  its columns do not match what EF expects. A baseline row that does not reflect reality would
  make the *next* migration generate a wrong diff, which is far more expensive to discover later.

Re-running it is a no-op, so pipelines stay idempotent.

## 8. Troubleshooting

**`The model for context 'SalesContext' has pending changes. Add a new migration before updating the database.`**
Thrown at **startup**, from `MigrateAsync`. The model and the checked-in migration disagree. The
usual cause while learning this sample is removing or altering `ApplyOutboxConfiguration` — that
changes the model, so EF demands a matching migration. Either restore the call, or run
`dotnet ef migrations add <Name>`.

**`SalesContext does not map OutboxEntity.`**
The full message is:

```text
DNV.Outbox.Abstractions.OutboxTransactionException: SalesContext does not map OutboxEntity. Call
ApplyOutboxConfiguration in OnModelCreating so outbox rows participate in the same transaction as
business data.
```

Thrown at **enqueue** time, by `EfOutboxProducer.PersistAsync`. You will see this rather than the
pending-changes error when the application is not using migrations. The fix is the same: call
`modelBuilder.ApplyOutboxConfiguration()` in `OnModelCreating`. The producer checks the model up
front precisely so that a missing mapping is a loud failure instead of silently dropped events.

**`The Entity Framework tools version '8.0.7' is older than that of the runtime`**
Your global `dotnet-ef` is being used instead of the local one. Run `dotnet tool restore` from
`samples\Outbox`, and run `dotnet ef` from inside that tree so the local manifest applies.

**`Cannot reach SQL Server using 'Server=...'`**
SQL Server is not running or the database does not exist. Check the service, then re-run the
Setup step. Note this sample needs only the empty *database* — the tables are created by the
migration.

**The browser shows 404**
ASP.NET Core returns 404 for any path that is not mapped. Both apps map a root index, so
<http://localhost:5002> and <http://localhost:5100> return JSON. A 404 or 405 on
<http://localhost:5002/orders> is expected: that route is POST-only and the browser address bar
issues a GET. Use `sample.http` or curl instead.

**`Timed out waiting for http://localhost:5100/health`**
Usually one of three things:

- A proxy. If `HTTP_PROXY` is set and `NO_PROXY` does not exclude localhost, `Invoke-RestMethod`
  tunnels loopback traffic through the proxy and hangs. `verify.ps1` passes `-NoProxy` for this
  reason; if you write your own scripts against these samples, do the same.
- A cold build. The first run after changing dependencies has to restore and compile before the
  server listens. Run `dotnet build` once beforehand.
- Port 5100 already in use. `Get-NetTCPConnection -LocalPort 5100` names the owner.

**The dispatcher never claims anything**
Check that `UseSqlServer` and `ApplyOutboxConfiguration` name the same schema and table. The
defaults agree (`outbox` / `OutboxMessages`); if you override one, override both.

## 9. Teardown

```powershell
$server = $env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'
sqlcmd -S $server -Q "IF DB_ID('OutboxSample02') IS NOT NULL ALTER DATABASE OutboxSample02 SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE OutboxSample02;"
```

Nothing else to clean up — no cloud resources are involved.
