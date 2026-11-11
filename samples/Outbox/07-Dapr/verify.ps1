#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 07. Exits non-zero on failure.

.DESCRIPTION
    Asserts that the outbox delivers through Dapr pub/sub to a separate subscriber process, and
    that the delivery carries the identifiers a subscriber needs in order to deduplicate.

    Three phases:

      1. Publish    - 3 orders are committed with their outbox records in one SQL transaction.
      2. Subscribe  - the subscriber, in its own process behind its own sidecar, receives 3
                      messages with 3 distinct outbox ids.
      3. Idempotency- each CloudEvent id equals the outbox id that produced it. That is what makes
                      a Dapr-level redelivery safe, so it is asserted rather than described.

    This script OWNS the `dapr run -f dapr.yaml` process and stops it in the finally block. It does
    NOT own SQL Server, Docker or the Dapr control plane: those are probed, and a clear message is
    produced if they are missing.

.PARAMETER SqlServer
    The SQL Server instance. Defaults to the OUTBOX_SAMPLES_SQL environment variable, then to
    .\SQLEXPRESS.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $PublisherPort = 5007,
    [int]    $SubscriberPort = 5017,
    [int]    $PublisherDaprPort = 3507,
    [int]    $SubscriberDaprPort = 3517,
    [int]    $OrderCount = 3
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$connectionString = "Server=$SqlServer;Database=OutboxSample07;Trusted_Connection=True;TrustServerCertificate=True"
$publisher = "http://localhost:$PublisherPort"
$subscriber = "http://localhost:$SubscriberPort"
$daprProcess = $null

function Stop-Everything {
    # `dapr stop` is the documented clean shutdown: it stops the apps AND their sidecars. Killing
    # the `dapr run` process alone can orphan daprd and dotnet children.
    Push-Location $root
    try {
        dapr stop -f .\dapr.yaml 2>&1 | Out-Null
    } catch {
        # Best effort - the hard kill below is the backstop.
    } finally {
        Pop-Location
    }

    if ($daprProcess -and -not $daprProcess.HasExited) {
        Stop-Process -Id $daprProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PortFree([int] $Port, [string] $Role) {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($listener) {
        $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port ($Role) is already in use by process '$owner' (PID $($listener.OwningProcess)). Stop it, or pass a different port - see the parameters at the top of this script."
    }
}

function Wait-ForHttp([string] $Url, [int] $TimeoutSeconds = 120) {
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

# Reads a JSON array endpoint and enumerates it properly.
#
# Invoke-RestMethod writes a JSON array to the pipeline as ONE object rather than enumerating it,
# so piping it straight into Where-Object filters NOTHING. Materialising it first makes the
# filters real.
function Get-Collection([string] $Url) {
    $response = Invoke-RestMethod -NoProxy -Uri $Url
    return @($response)
}

function Wait-For([scriptblock] $Produce, [scriptblock] $Condition, [int] $TimeoutSeconds, [string] $Description) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $value = & $Produce
        if (& $Condition $value) { return $value }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
}

try {
    Assert-PortFree $PublisherPort 'publisher'
    Assert-PortFree $SubscriberPort 'subscriber'
    Assert-PortFree $PublisherDaprPort 'publisher sidecar'
    Assert-PortFree $SubscriberDaprPort 'subscriber sidecar'

    # ---- Dependencies this script does NOT own: probe, never start or stop. -------------------

    Write-Host 'Checking the Dapr CLI and runtime...' -ForegroundColor Cyan
    $daprVersion = (dapr --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "The Dapr CLI is not installed or not on PATH. Install it from https://docs.dapr.io/getting-started/install-dapr-cli/ and then run 'dapr init'."
    }
    if ($daprVersion -notmatch 'Runtime version:\s*(\d|\w)') {
        throw "The Dapr CLI is installed but the runtime is not initialised (got: $daprVersion). Run 'dapr init' - it needs Docker running."
    }
    Write-Host "  $($daprVersion -replace "`n", ' | ')" -ForegroundColor DarkGray

    Write-Host 'Checking Redis (the pub/sub component backing store)...' -ForegroundColor Cyan
    if (-not (Test-NetConnection -ComputerName localhost -Port 6379 -WarningAction SilentlyContinue).TcpTestSucceeded) {
        throw @"
Nothing is listening on localhost:6379, so the 'order-pubsub' component cannot start.

'dapr init' runs Redis in a Docker container named dapr_redis. Start Docker Desktop, then:

    docker start dapr_redis dapr_placement dapr_scheduler

Re-run this script once 'docker ps' lists dapr_redis as Up.
"@
    }

    Write-Host 'Checking SQL Server...' -ForegroundColor Cyan
    try {
        # Connect to master rather than to the sample database: on a clean machine the sample
        # database does not exist yet, and connecting to it would fail with "Cannot open database".
        # Create it if it is missing - the outbox schema inside it is created by the sample at
        # startup, so an empty database is all that is needed.
        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $connectionString
        $database = $builder.get_InitialCatalog()
        if ($database -notmatch '^OutboxSample\d+$') { throw "Unexpected database name '$database'." }
        $builder.set_InitialCatalog('master')

        $master = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
        $master.Open()
        try {
            $command = $master.CreateCommand()
            $command.CommandText = "IF DB_ID('$database') IS NULL CREATE DATABASE [$database];"
            $command.ExecuteNonQuery() | Out-Null
        } finally {
            $master.Close()
        }
    } catch {
        throw "Cannot reach SQL Server using '$connectionString'. Start SQL Server, or set OUTBOX_SAMPLES_SQL to a reachable instance. Underlying error: $($_.Exception.Message)"
    }

    # ---- Build before running, because `dapr run` starts both apps at once. -------------------

    Write-Host 'Building...' -ForegroundColor Cyan
    dotnet build (Join-Path $root 'Publisher') --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the publisher.' }
    dotnet build (Join-Path $root 'Subscriber') --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the subscriber.' }

    Write-Host 'Starting both apps and their sidecars (dapr run -f dapr.yaml)...' -ForegroundColor Cyan
    $daprProcess = Start-Process dapr -PassThru -WorkingDirectory $root -ArgumentList @('run', '-f', '.\dapr.yaml')

    # Generous: two sidecars plus two apps, and the publisher creates its schema on first start.
    Wait-ForHttp "$subscriber/health" -TimeoutSeconds 180
    Wait-ForHttp "$publisher/health" -TimeoutSeconds 180

    # The sidecar must have finished reading /dapr/subscribe before the first publish, otherwise
    # the message is published to a topic nobody is subscribed to yet and is simply dropped.
    Write-Host 'Waiting for the subscription to be registered...' -ForegroundColor Cyan
    $null = Wait-For `
        -Produce { (Invoke-RestMethod -NoProxy "$subscriber/subscription-status").subscribed } `
        -Condition { param($s) $s -eq $true } `
        -TimeoutSeconds 60 `
        -Description 'the sidecar to fetch /dapr/subscribe'

    Invoke-RestMethod -Method Delete -NoProxy -Uri "$subscriber/received" | Out-Null

    # ---- Phase 1: publish ---------------------------------------------------------------------

    Write-Host ''
    Write-Host "Phase 1: placing $OrderCount orders..." -ForegroundColor Cyan

    $placed = @()
    for ($i = 1; $i -le $OrderCount; $i++) {
        $placed += Invoke-RestMethod -Method Post -NoProxy -Uri "$publisher/orders" -ContentType 'application/json' `
            -Body (@{ tenantId = 'acme'; customerId = "cust-$i"; total = 10.0 + $i } | ConvertTo-Json)
    }

    $submittedOutboxIds = @($placed | ForEach-Object { $_.outboxId })
    if ($submittedOutboxIds.Count -ne $OrderCount) {
        throw "Expected $OrderCount outbox ids from $OrderCount orders, got $($submittedOutboxIds.Count)."
    }

    Write-Host "  $OrderCount orders committed with their outbox records." -ForegroundColor DarkGray

    # ---- Phase 2: the subscriber receives them ------------------------------------------------

    Write-Host ''
    Write-Host 'Phase 2: waiting for the subscriber...' -ForegroundColor Cyan

    $received = Wait-For `
        -Produce { @(Get-Collection "$subscriber/received") } `
        -Condition { param($r) $r.Count -ge $OrderCount } `
        -TimeoutSeconds 120 `
        -Description "$OrderCount messages to reach the subscriber through Dapr"

    $receivedOutboxIds = @($received | ForEach-Object { $_.cloudEventId })
    $distinct = @($receivedOutboxIds | Select-Object -Unique).Count
    if ($distinct -ne $OrderCount) {
        throw "Expected $OrderCount distinct outbox ids at the subscriber, got $distinct (from $($receivedOutboxIds.Count) messages)."
    }

    Write-Host "  $($received.Count) messages, $distinct distinct outbox ids." -ForegroundColor DarkGray

    # ---- Phase 3: the identifiers that make a redelivery safe ---------------------------------

    Write-Host ''
    Write-Host 'Phase 3: checking the CloudEvent carries the outbox identity...' -ForegroundColor Cyan

    $missing = @($submittedOutboxIds | Where-Object { $_ -notin $receivedOutboxIds })
    if ($missing.Count -ne 0) {
        throw "$($missing.Count) submitted outbox ids never arrived as a CloudEvent id: $($missing -join ', '). SendCloudEventId is not reaching the broker."
    }

    foreach ($message in $received) {
        if ($message.cloudEventType -ne 'OrderPlaced') {
            throw "Expected CloudEvent type 'OrderPlaced', got '$($message.cloudEventType)'. The cloudevent.type metadata is not being applied."
        }
        if ([string]::IsNullOrWhiteSpace($message.orderId)) {
            throw "A message arrived with no orderId in its data. The published body should be the event itself, not a JSON string containing it. Body was: $($message.rawData)"
        }
        if ([string]::IsNullOrWhiteSpace($message.traceParent)) {
            throw "Message $($message.cloudEventId) arrived without a traceparent. The trace context did not survive the outbox."
        }
    }

    Write-Host "  Every CloudEvent id equals its outbox id, typed 'OrderPlaced', with a traceparent and a parsed body." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "PASS: $OrderCount orders committed transactionally in SQL Server were published through Dapr pub/sub and received by a separate subscriber process as $distinct distinct CloudEvents, each carrying its outbox id so a redelivery can be deduplicated." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
