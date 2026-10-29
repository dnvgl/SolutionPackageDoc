#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 01. Exits non-zero on failure.

.DESCRIPTION
    Starts the dependencies it owns (the shared receiver and this sample's API), places five
    orders, and asserts that exactly five deliveries arrive with five distinct outbox ids.

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
    [int]    $ApiPort = 5001
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$connectionString = "Server=$SqlServer;Database=OutboxSample01;Trusted_Connection=True;TrustServerCertificate=True"
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

    Write-Host 'PASS: 5 orders produced exactly 5 deliveries.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
