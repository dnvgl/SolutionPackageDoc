#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 02. Exits non-zero on failure.

.DESCRIPTION
    Starts the dependencies it owns (the shared receiver and this sample's API), places five
    orders, and asserts that exactly five deliveries arrive with five distinct outbox ids.

    It adds one assertion specific to this sample: the outbox rows written by Entity Framework
    Core land in the very same table the ADO.NET dispatcher reads from. That shared table is the
    whole reason an EF producer and a SQL store can be mixed.

    It does NOT start SQL Server. It probes for it and fails fast with a clear message, because
    silently starting or stopping a developer's database engine is not acceptable behaviour for
    a sample script.

.PARAMETER SqlServer
    The SQL Server instance. Defaults to the OUTBOX_SAMPLES_SQL environment variable, then to
    .\SQLEXPRESS. Use the same value when creating the database with sqlcmd.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $ReceiverPort = 5100,
    [int]    $ApiPort = 5002
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$connectionString = "Server=$SqlServer;Database=OutboxSample02;Trusted_Connection=True;TrustServerCertificate=True"
$processes = @()

function Stop-Everything {
    foreach ($process in $processes) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-ForHttp([string] $Url, [int] $TimeoutSeconds = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri $Url -TimeoutSec 2 -NoProxy | Out-Null
            return
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    throw "Timed out waiting for $Url"
}

try {
    # Dependencies this script does NOT own: probe, never start or stop.
    Write-Host 'Checking SQL Server...' -ForegroundColor Cyan
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        $connection.Close()
    } catch {
        throw "Cannot reach SQL Server using '$connectionString'. Start SQL Server and create the database (see README Setup), or set OUTBOX_SAMPLES_SQL to a reachable instance. Underlying error: $($_.Exception.Message)"
    }

    # Dependencies this script DOES own: start them, and stop them in the finally block.
    Write-Host 'Starting receiver...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--project', (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'),
        '--urls', "http://localhost:$ReceiverPort")
    Wait-ForHttp "http://localhost:$ReceiverPort/health"

    Write-Host 'Starting sample API...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--project', $root, '--urls', "http://localhost:$ApiPort")
    Wait-ForHttp "http://localhost:$ApiPort/health"

    Invoke-RestMethod -Method Delete -NoProxy -Uri "http://localhost:$ReceiverPort/deliveries" | Out-Null

    Write-Host 'Placing 5 orders...' -ForegroundColor Cyan
    for ($i = 1; $i -le 5; $i++) {
        Invoke-RestMethod -Method Post -NoProxy -Uri "http://localhost:$ApiPort/orders" `
            -ContentType 'application/json' `
            -Body (@{ tenantId = 'acme'; customerId = "cust-$i"; total = 10 * $i } | ConvertTo-Json) | Out-Null
    }

    Write-Host 'Waiting for the dispatcher to deliver...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 2
        $summary = Invoke-RestMethod -NoProxy -Uri "http://localhost:$ReceiverPort/deliveries/summary"
    } while ($summary.total -lt 5 -and (Get-Date) -lt $deadline)

    if ($summary.total -ne 5) {
        throw "Expected 5 deliveries, got $($summary.total)."
    }
    if ($summary.distinctOutboxIds -ne 5) {
        throw "Expected 5 distinct outbox ids, got $($summary.distinctOutboxIds) - the dispatcher delivered a record twice."
    }

    # Specific to this sample: EF wrote into the same table the SQL store dispatches from.
    # Had EF mapped the outbox elsewhere, the dispatcher above would have found nothing, so this
    # assertion is really about the two halves agreeing on one table.
    Write-Host 'Checking the EF-written rows are in the dispatcher table...' -ForegroundColor Cyan
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT COUNT(*) FROM outbox.OutboxMessages'
        $rowCount = [int]$command.ExecuteScalar()

        # Status 3 is Delivered. EF produced these rows; the ADO.NET store moved them to terminal state.
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT COUNT(*) FROM outbox.OutboxMessages WHERE Status = 3'
        $deliveredCount = [int]$command.ExecuteScalar()

        # The business rows EF saved in the very same SaveChangesAsync.
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT COUNT(*) FROM dbo.Orders'
        $orderCount = [int]$command.ExecuteScalar()
    } finally {
        $connection.Close()
    }

    if ($rowCount -lt 5) {
        throw "Expected at least 5 rows in outbox.OutboxMessages, found $rowCount."
    }
    if ($deliveredCount -lt 5) {
        throw "Expected at least 5 delivered rows in outbox.OutboxMessages, found $deliveredCount."
    }
    if ($orderCount -lt 5) {
        throw "Expected at least 5 rows in dbo.Orders, found $orderCount - the business write did not commit with the outbox write."
    }

    Write-Host "PASS: 5 orders produced exactly 5 deliveries; $orderCount order rows and $deliveredCount delivered outbox rows agree." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
