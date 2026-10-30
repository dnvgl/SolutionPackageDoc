#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 03. Exits non-zero on failure.

.DESCRIPTION
    Starts two independent HTTP receivers and this sample's API, places three orders, and asserts
    that every order fanned out to all three destinations.

    The assertion that matters is the identifier rule: one logical event produces ONE EventId
    shared by every delivery, and one distinct OutboxId per delivery. Everything else in this
    sample follows from that, so it is asserted rather than merely described in the README.

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
    [int]    $ReceiverAPort = 5101,
    [int]    $ReceiverBPort = 5102,
    [int]    $ApiPort = 5003
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$connectionString = "Server=$SqlServer;Database=OutboxSample03;Trusted_Connection=True;TrustServerCertificate=True"
$auditDirectory = Join-Path $root 'audit'
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

function Assert-PortFree([int] $Port, [string] $Role) {
    # Without this, a port squatted on by something unrelated surfaces 90 seconds later as a
    # mystery timeout. This sample needs three ports, so the odds of a collision are three times
    # those of the earlier samples.
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($listener) {
        $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port ($Role) is already in use by process '$owner' (PID $($listener.OwningProcess)). Stop it, or pass a different port - see the parameters at the top of this script."
    }
}

try {
    Assert-PortFree $ReceiverAPort 'receiver A'
    Assert-PortFree $ReceiverBPort 'receiver B'
    Assert-PortFree $ApiPort 'sample API'

    # Dependencies this script does NOT own: probe, never start or stop.
    Write-Host 'Checking SQL Server...' -ForegroundColor Cyan
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $connection.Open()
        $connection.Close()
    } catch {
        throw "Cannot reach SQL Server using '$connectionString'. Start SQL Server and create the database (see README Setup), or set OUTBOX_SAMPLES_SQL to a reachable instance. Underlying error: $($_.Exception.Message)"
    }

    # The file destination appends to a directory. Start from empty so the count assertion means
    # something.
    if (Test-Path $auditDirectory) {
        Remove-Item $auditDirectory -Recurse -Force
    }

    # Build once, up front. Two 'dotnet run' instances of the SAME project race on the build
    # output and one of them loses, so every multi-instance sample must build first and then
    # start its processes with --no-build.
    Write-Host 'Building...' -ForegroundColor Cyan
    dotnet build (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver') --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the shared receiver.' }
    dotnet build $root --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the sample.' }

    # Dependencies this script DOES own: start them, and stop them in the finally block.
    Write-Host 'Starting receiver A and receiver B...' -ForegroundColor Cyan
    foreach ($port in @($ReceiverAPort, $ReceiverBPort)) {
        $processes += Start-Process dotnet -PassThru -ArgumentList @(
            'run', '--no-build', '--project', (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'),
            '--urls', "http://localhost:$port")
    }
    Wait-ForHttp "http://localhost:$ReceiverAPort/health"
    Wait-ForHttp "http://localhost:$ReceiverBPort/health"

    Write-Host 'Starting sample API...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--project', $root, '--urls', "http://localhost:$ApiPort")
    Wait-ForHttp "http://localhost:$ApiPort/health"

    Invoke-RestMethod -Method Delete -NoProxy -Uri "http://localhost:$ReceiverAPort/deliveries" | Out-Null
    Invoke-RestMethod -Method Delete -NoProxy -Uri "http://localhost:$ReceiverBPort/deliveries" | Out-Null

    Write-Host 'Placing 3 orders...' -ForegroundColor Cyan
    $placed = @()
    for ($i = 1; $i -le 3; $i++) {
        $placed += Invoke-RestMethod -Method Post -NoProxy -Uri "http://localhost:$ApiPort/orders" `
            -ContentType 'application/json' `
            -Body (@{ tenantId = 'acme'; customerId = "cust-$i"; total = 10 * $i } | ConvertTo-Json)
    }

    # One enqueue, three destinations, three rows.
    foreach ($order in $placed) {
        if ($order.outboxIds.Count -ne 3) {
            throw "Expected 3 outbox ids for order $($order.id), got $($order.outboxIds.Count)."
        }
        $distinct = ($order.outboxIds | Select-Object -Unique).Count
        if ($distinct -ne 3) {
            throw "Expected 3 DISTINCT outbox ids for order $($order.id), got $distinct - each delivery must be its own row."
        }
    }

    $distinctEventIds = ($placed.eventId | Select-Object -Unique).Count
    if ($distinctEventIds -ne 3) {
        throw "Expected 3 distinct event ids across 3 orders, got $distinctEventIds."
    }

    Write-Host 'Waiting for the dispatcher to deliver to all three destinations...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $summaryA = Invoke-RestMethod -NoProxy -Uri "http://localhost:$ReceiverAPort/deliveries/summary"
        $summaryB = Invoke-RestMethod -NoProxy -Uri "http://localhost:$ReceiverBPort/deliveries/summary"
        $auditCount = (Get-ChildItem $auditDirectory -Filter *.json -ErrorAction SilentlyContinue).Count
    } while (($summaryA.total -lt 3 -or $summaryB.total -lt 3 -or $auditCount -lt 3) -and (Get-Date) -lt $deadline)

    if ($summaryA.total -ne 3) { throw "Receiver A expected 3 deliveries, got $($summaryA.total)." }
    if ($summaryB.total -ne 3) { throw "Receiver B expected 3 deliveries, got $($summaryB.total)." }
    if ($auditCount -ne 3) { throw "Expected 3 audit files in '$auditDirectory', found $auditCount." }

    # The heart of the sample. For each order, the SAME EventId must appear at every destination,
    # carried by three DIFFERENT OutboxIds.
    Write-Host 'Checking the identifier rule across all three destinations...' -ForegroundColor Cyan
    $deliveriesA = Invoke-RestMethod -NoProxy -Uri "http://localhost:$ReceiverAPort/deliveries"
    $deliveriesB = Invoke-RestMethod -NoProxy -Uri "http://localhost:$ReceiverBPort/deliveries"

    foreach ($order in $placed) {
        $eventId = $order.eventId
        $outboxIds = @($order.outboxIds)

        $atA = @($deliveriesA | Where-Object { $_.eventId -eq $eventId })
        $atB = @($deliveriesB | Where-Object { $_.eventId -eq $eventId })

        if ($atA.Count -ne 1) { throw "Receiver A expected exactly 1 delivery for event $eventId, got $($atA.Count)." }
        if ($atB.Count -ne 1) { throw "Receiver B expected exactly 1 delivery for event $eventId, got $($atB.Count)." }

        if ($atA[0].outboxId -eq $atB[0].outboxId) {
            throw "Receiver A and receiver B received the SAME outbox id $($atA[0].outboxId) for event $eventId - each destination must get its own row."
        }

        foreach ($received in @($atA[0].outboxId, $atB[0].outboxId)) {
            if ($outboxIds -notcontains $received) {
                throw "Delivered outbox id $received was not among the ids returned by the enqueue for event $eventId."
            }
        }

        # The audit file is named after the third outbox id and records the shared event id.
        $auditId = $outboxIds | Where-Object { $_ -ne $atA[0].outboxId -and $_ -ne $atB[0].outboxId }
        $auditPath = Join-Path $auditDirectory "$auditId.json"
        if (-not (Test-Path $auditPath)) {
            throw "Expected an audit file at '$auditPath' for event $eventId."
        }
        if (-not ((Get-Content $auditPath -Raw) -match [regex]::Escape($eventId))) {
            throw "Audit file '$auditPath' does not record event id $eventId."
        }
    }

    Write-Host 'PASS: 3 orders each fanned out to 2 HTTP receivers and 1 file, sharing one event id per order with three distinct outbox ids.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
