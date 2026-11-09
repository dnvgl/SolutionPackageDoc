#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 06. Exits non-zero on failure.

.DESCRIPTION
    Asserts the one thing this sample exists to prove: in Cosmos DB, atomicity is confined to a
    single container and a single logical partition, and the outbox has to live inside that
    boundary to be transactional.

    Three phases:

      1. Colocation - business documents and outbox documents share one container, told apart by
                      the 'recordType' discriminator rather than by living in separate containers.
      2. Delivery   - 5 orders in one partition produce 5 deliveries with 5 distinct outbox ids.
      3. Atomicity  - a batch containing a doomed operation writes NOTHING. Not the order, not
                      the outbox record. This is the assertion that makes the sample worth having.

    It does NOT start the Cosmos emulator. It probes for it and fails fast with a clear message,
    because a missing emulator otherwise surfaces as an opaque startup timeout.

.PARAMETER CosmosEndpoint
    The Cosmos account endpoint. Defaults to the local emulator.

.PARAMETER ReceiverPort
    Port for the shared HTTP receiver.

.PARAMETER ApiPort
    Port for this sample's API.
#>
[CmdletBinding()]
param(
    [string] $CosmosEndpoint = ($env:OUTBOX_SAMPLES_COSMOS ?? 'https://localhost:8081/'),
    [int]    $ReceiverPort = 5100,
    [int]    $ApiPort = 5006,
    [int]    $OrderCount = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$receiver = "http://localhost:$ReceiverPort"
$api = "http://localhost:$ApiPort"
$tenant = 'acme'
$processes = @()

function Stop-Everything {
    foreach ($process in $processes) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
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
# so piping it straight into Where-Object filters NOTHING. Materialising it first is what makes
# the filters real.
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

# The emulator answers the data plane with 401 when unauthenticated, which is itself proof that
# it is up. Treat any HTTP response as reachable; only a transport failure means "not running".
function Test-CosmosEmulator([string] $Endpoint) {
    try {
        Invoke-WebRequest -Uri $Endpoint -SkipCertificateCheck -NoProxy -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        return $null -ne $_.Exception.Response
    }
}

try {
    Assert-PortFree $ReceiverPort 'receiver'
    Assert-PortFree $ApiPort 'sample API'

    # A dependency this script does NOT own: probe, never start or stop.
    Write-Host 'Checking the Cosmos emulator...' -ForegroundColor Cyan
    if (-not (Test-CosmosEmulator $CosmosEndpoint)) {
        throw @"
Cannot reach a Cosmos account at '$CosmosEndpoint'.

Start the Azure Cosmos DB Emulator in an ELEVATED PowerShell window - it requires administrator
rights and takes a minute or two to become ready:

    & 'C:\Program Files\Azure Cosmos DB Emulator\Microsoft.Azure.Cosmos.Emulator.exe' /NoExplorer /DisableRateLimiting /PartitionCount=10

Then re-run this script. To target a different account, pass -CosmosEndpoint or set the
OUTBOX_SAMPLES_COSMOS environment variable.
"@
    }

    Write-Host 'Building...' -ForegroundColor Cyan
    dotnet build (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver') --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the shared receiver.' }
    dotnet build $root --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the sample.' }

    Write-Host 'Starting receiver...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--no-launch-profile', '--project',
        (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'), '--urls', $receiver)
    Wait-ForHttp "$receiver/health"

    Write-Host 'Starting sample API...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--no-launch-profile', '--project', $root, '--urls', $api)
    # Generous: the first run provisions the database and container.
    Wait-ForHttp "$api/health" -TimeoutSeconds 180

    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null

    # -------------------------------------------------------------------------------------------
    # Phase 1 and 2: orders commit with their outbox records, and are delivered.
    # -------------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host "Phase 1: placing $OrderCount orders in partition '$tenant'..." -ForegroundColor Cyan

    $placed = @()
    for ($i = 1; $i -le $OrderCount; $i++) {
        $placed += Invoke-RestMethod -Method Post -NoProxy -Uri "$api/orders" -ContentType 'application/json' `
            -Body (@{ tenantId = $tenant; customerId = "cust-$i"; total = 10.0 + $i } | ConvertTo-Json)
    }

    $submittedOutboxIds = @($placed | ForEach-Object { $_.outboxId })
    if ($submittedOutboxIds.Count -ne $OrderCount) {
        throw "Expected $OrderCount outbox ids from $OrderCount orders, got $($submittedOutboxIds.Count)."
    }

    Write-Host '  Checking both document kinds share one container...' -ForegroundColor DarkGray

    $documents = Invoke-RestMethod -NoProxy -Uri "$api/container/$tenant"
    if ($documents.orders -lt $OrderCount) {
        throw "Expected at least $OrderCount business documents in the container, found $($documents.orders)."
    }
    if ($documents.outboxRecords -lt $OrderCount) {
        throw "Expected at least $OrderCount outbox documents in the SAME container, found $($documents.outboxRecords). In Cosmos the outbox cannot live in its own container and still be transactional."
    }

    Write-Host "  $($documents.orders) orders and $($documents.outboxRecords) outbox records in container '$($documents.container)'." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Phase 2: waiting for delivery...' -ForegroundColor Cyan

    $delivered = Wait-For `
        -Produce { @(Get-Collection "$receiver/deliveries") } `
        -Condition { param($d) $d.Count -ge $OrderCount } `
        -TimeoutSeconds 120 `
        -Description "$OrderCount deliveries to reach the receiver"

    $deliveredIds = @($delivered | ForEach-Object { $_.outboxId })
    $missing = @($submittedOutboxIds | Where-Object { $_ -notin $deliveredIds })
    if ($missing.Count -ne 0) {
        throw "$($missing.Count) submitted outbox ids never arrived: $($missing -join ', ')"
    }

    $distinct = @($deliveredIds | Select-Object -Unique).Count
    if ($distinct -ne $OrderCount) {
        throw "Expected $OrderCount distinct outbox ids at the receiver, got $distinct (from $($deliveredIds.Count) deliveries)."
    }

    Write-Host "  $($deliveredIds.Count) deliveries, $distinct distinct outbox ids." -ForegroundColor DarkGray

    # -------------------------------------------------------------------------------------------
    # Phase 3: the point of the sample. A failed batch writes nothing at all.
    # -------------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 3: a doomed batch must write NOTHING...' -ForegroundColor Cyan

    $before = Invoke-RestMethod -NoProxy -Uri "$api/container/$tenant"

    $doomed = Invoke-RestMethod -Method Post -NoProxy -Uri "$api/orders/doomed" -ContentType 'application/json' `
        -Body (@{ tenantId = $tenant; customerId = 'cust-doomed'; total = 99.0 } | ConvertTo-Json) `
        -SkipHttpErrorCheck -StatusCodeVariable doomedStatus

    if ($doomedStatus -ne 409) {
        throw "Expected the doomed batch to be rejected with HTTP 409, got $doomedStatus. The sample must not report success for a batch Cosmos refused."
    }
    if ([string]::IsNullOrWhiteSpace($doomed.orderId)) {
        throw 'The doomed endpoint did not report which order id it attempted, so its absence cannot be asserted.'
    }

    # The business document must not exist...
    Invoke-RestMethod -NoProxy -Uri "$api/orders/$tenant/$($doomed.orderId)" `
        -SkipHttpErrorCheck -StatusCodeVariable lookupStatus | Out-Null
    if ($lookupStatus -ne 404) {
        throw "Order $($doomed.orderId) exists (HTTP $lookupStatus) after its batch was rejected. The business write was NOT rolled back - atomicity is broken."
    }

    # ...and neither must the outbox record that was staged alongside it.
    $after = Invoke-RestMethod -NoProxy -Uri "$api/container/$tenant"
    if ($after.orders -ne $before.orders) {
        throw "Business document count changed from $($before.orders) to $($after.orders) after a rejected batch."
    }
    if ($after.outboxRecords -ne $before.outboxRecords) {
        throw "Outbox document count changed from $($before.outboxRecords) to $($after.outboxRecords) after a rejected batch. The outbox record survived a failed business write, which is exactly what the outbox pattern must never allow."
    }

    # Belt and braces: nothing extra reached the receiver either.
    Start-Sleep -Seconds 5
    $finalDeliveries = @(Get-Collection "$receiver/deliveries")
    if ($finalDeliveries.Count -ne $OrderCount) {
        throw "Receiver saw $($finalDeliveries.Count) deliveries, expected $OrderCount. A rejected batch must not produce a delivery."
    }

    Write-Host "  Rejected with HTTP 409. Order absent, outbox unchanged at $($after.outboxRecords) records, no extra delivery." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "PASS: $OrderCount orders and their outbox records committed atomically in one Cosmos container and partition and were delivered exactly $OrderCount times, and a rejected batch wrote neither the order nor its outbox record." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
