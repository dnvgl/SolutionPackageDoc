#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 04. Exits non-zero on failure.

.DESCRIPTION
    Asserts the three phases of the failure path, in order:

      1. Retry       - a transient failure is retried with backoff, as the SAME record.
      2. Dead-letter - retries stop at MaxAttempts and the record becomes terminal.
      3. Requeue     - an operator replays it, preserving both identifiers.

    This is the most valuable script in the suite, because it is the only one that asserts what
    happens when delivery does NOT work. The receiver is told to fail on demand, so the failures
    are deliberate rather than simulated by breaking something.

    It does NOT start SQL Server. It probes for it and fails fast with a clear message.

.PARAMETER SqlServer
    The SQL Server instance. Defaults to the OUTBOX_SAMPLES_SQL environment variable, then to
    .\SQLEXPRESS. Use the same value when creating the database with sqlcmd.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $ReceiverPort = 5100,
    [int]    $ApiPort = 5004
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$connectionString = "Server=$SqlServer;Database=OutboxSample04;Trusted_Connection=True;TrustServerCertificate=True"
$receiver = "http://localhost:$ReceiverPort"
$api = "http://localhost:$ApiPort"
$processes = @()

# MaxAttempts in Program.cs. Attempt 4 is the one that dead-letters, so three forced failures
# leave exactly one attempt to succeed on.
$maxAttempts = 4

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
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($listener) {
        $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port ($Role) is already in use by process '$owner' (PID $($listener.OwningProcess)). Stop it, or pass a different port - see the parameters at the top of this script."
    }
}

# Reads a JSON array endpoint and enumerates it properly.
#
# Invoke-RestMethod writes a JSON array to the pipeline as ONE object rather than enumerating it.
# Piping it straight into Where-Object therefore filters NOTHING: `$_.outboxId -eq $id` evaluates
# against the whole array, returns a non-empty (truthy) array, and the entire collection sails
# through as a single item. Materialising the response first is what makes the filters real.
function Get-Collection([string] $Url) {
    $response = Invoke-RestMethod -NoProxy -Uri $Url
    return @($response)
}

# Polls until $Condition returns true, then returns the last value produced by $Produce.
function Wait-For([scriptblock] $Produce, [scriptblock] $Condition, [int] $TimeoutSeconds, [string] $Description) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $value = & $Produce
        if (& $Condition $value) { return $value }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
}

function Submit-Order([string] $CustomerId) {
    Invoke-RestMethod -Method Post -NoProxy -Uri "$api/orders" -ContentType 'application/json' `
        -Body (@{ tenantId = 'acme'; customerId = $CustomerId; total = 42.00 } | ConvertTo-Json)
}

try {
    Assert-PortFree $ReceiverPort 'receiver'
    Assert-PortFree $ApiPort 'sample API'

    # SQL Server itself is a dependency this script does NOT own: probe it, never start it.
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

    Write-Host 'Building...' -ForegroundColor Cyan
    dotnet build (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver') --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the shared receiver.' }
    dotnet build $root --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the sample.' }

    Write-Host 'Starting receiver...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--project', (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'),
        '--urls', $receiver)
    Wait-ForHttp "$receiver/health"

    Write-Host 'Starting sample API...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--project', $root, '--urls', $api)
    Wait-ForHttp "$api/health"

    # ---------------------------------------------------------------------------------------
    # Phase 1: a transient failure is retried, as the same record.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 1: retry after transient failures...' -ForegroundColor Cyan

    # DELETE also resets the failure budget, so set the budget after clearing, never before.
    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null
    Invoke-RestMethod -Method Post -NoProxy -Uri "$receiver/fail-next/3" | Out-Null

    $retried = Submit-Order 'cust-retry'
    $retriedOutboxId = $retried.outboxIds[0]

    $attempts = Wait-For `
        -Produce { @(Get-Collection "$receiver/deliveries" | Where-Object { $_.outboxId -eq $retriedOutboxId }) } `
        -Condition { param($a) $a.Count -ge $maxAttempts } `
        -TimeoutSeconds 90 `
        -Description "$maxAttempts attempts of outbox $retriedOutboxId (3 rejected, 1 accepted)"

    if ($attempts.Count -ne $maxAttempts) {
        throw "Expected exactly $maxAttempts attempts for outbox $retriedOutboxId, got $($attempts.Count)."
    }

    # The point of the phase: a retry is the SAME record, not a new one.
    $distinctOutboxIds = ($attempts.outboxId | Select-Object -Unique).Count
    if ($distinctOutboxIds -ne 1) {
        throw "Expected 1 distinct outbox id across $maxAttempts attempts, got $distinctOutboxIds - a retry must reuse the original record."
    }
    $distinctEventIds = ($attempts.eventId | Select-Object -Unique).Count
    if ($distinctEventIds -ne 1) {
        throw "Expected 1 distinct event id across $maxAttempts attempts, got $distinctEventIds - a retry must reuse the original event id."
    }

    # The attempt header must increase, which is how a consumer tells a retry from a first try.
    $attemptNumbers = @($attempts | ForEach-Object { [int] $_.attempt } | Sort-Object)
    $expectedNumbers = 1..$maxAttempts
    if ("$attemptNumbers" -ne "$expectedNumbers") {
        throw "Expected attempt headers $expectedNumbers, got $attemptNumbers."
    }

    $delivered = Wait-For `
        -Produce { Invoke-RestMethod -NoProxy -Uri "$api/outbox/$retriedOutboxId" } `
        -Condition { param($m) $m.status -eq 'Delivered' } `
        -TimeoutSeconds 30 `
        -Description "outbox $retriedOutboxId to reach Delivered"

    if ($delivered.attemptCount -ne $maxAttempts) {
        throw "Expected the delivered record to show $maxAttempts attempts, got $($delivered.attemptCount)."
    }

    Write-Host "  3 rejections, then delivered on attempt $maxAttempts as the same record." -ForegroundColor DarkGray

    # ---------------------------------------------------------------------------------------
    # Phase 2: retries are bounded. Exhausting them dead-letters the record.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 2: dead-letter after exhausting attempts...' -ForegroundColor Cyan

    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null
    # More forced failures than the record has attempts, so it can only ever dead-letter.
    Invoke-RestMethod -Method Post -NoProxy -Uri "$receiver/fail-next/50" | Out-Null

    $doomed = Submit-Order 'cust-deadletter'
    $doomedOutboxId = $doomed.outboxIds[0]

    $deadLettered = Wait-For `
        -Produce { @(Get-Collection "$api/outbox/dead-lettered" | Where-Object { $_.outboxId -eq $doomedOutboxId }) } `
        -Condition { param($d) $d.Count -eq 1 } `
        -TimeoutSeconds 120 `
        -Description "outbox $doomedOutboxId to be dead-lettered"

    if ($deadLettered[0].attemptCount -ne $maxAttempts) {
        throw "Expected dead-lettering at exactly $maxAttempts attempts, got $($deadLettered[0].attemptCount) - retries must be bounded by MaxAttempts."
    }
    if ([string]::IsNullOrWhiteSpace($deadLettered[0].lastError)) {
        throw 'The dead-lettered record has no LastError. An operator needs to know why it failed.'
    }

    # It must STAY dead. A terminal record is invisible to the dispatcher.
    $before = @(Get-Collection "$receiver/deliveries" | Where-Object { $_.outboxId -eq $doomedOutboxId }).Count
    Start-Sleep -Seconds 10
    $after = @(Get-Collection "$receiver/deliveries" | Where-Object { $_.outboxId -eq $doomedOutboxId }).Count
    if ($after -ne $before) {
        throw "A dead-lettered record is still being retried: attempts went from $before to $after. Dead-lettering must stop the dispatcher from picking it up."
    }

    Write-Host "  Stopped at $maxAttempts attempts and stayed stopped." -ForegroundColor DarkGray

    # ---------------------------------------------------------------------------------------
    # Phase 3: an operator replays it, and the replay is idempotent for the consumer.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 3: operator requeues the dead-lettered record...' -ForegroundColor Cyan

    # Clears the forced-failure budget, so this time the receiver accepts.
    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null

    Invoke-RestMethod -Method Post -NoProxy -Uri "$api/outbox/$doomedOutboxId/requeue" | Out-Null

    $replayed = Wait-For `
        -Produce { @(Get-Collection "$receiver/deliveries" | Where-Object { $_.outboxId -eq $doomedOutboxId }) } `
        -Condition { param($d) $d.Count -ge 1 } `
        -TimeoutSeconds 60 `
        -Description "requeued outbox $doomedOutboxId to be delivered"

    # The whole reason requeue is safe: the consumer sees identifiers it has seen before, so it
    # can recognise the replay as a duplicate rather than treating it as a second event.
    if ($replayed[0].outboxId -ne $doomedOutboxId) {
        throw "Requeue changed the outbox id from $doomedOutboxId to $($replayed[0].outboxId) - a replay must keep it, or consumer deduplication breaks."
    }
    if ($replayed[0].eventId -ne $doomed.eventId) {
        throw "Requeue changed the event id from $($doomed.eventId) to $($replayed[0].eventId) - a replay must keep it, or consumer deduplication breaks."
    }

    $final = Wait-For `
        -Produce { Invoke-RestMethod -NoProxy -Uri "$api/outbox/$doomedOutboxId" } `
        -Condition { param($m) $m.status -eq 'Delivered' } `
        -TimeoutSeconds 30 `
        -Description "requeued outbox $doomedOutboxId to reach Delivered"

    $stillDead = @(Get-Collection "$api/outbox/dead-lettered" | Where-Object { $_.outboxId -eq $doomedOutboxId })
    if ($stillDead.Count -ne 0) {
        throw "Outbox $doomedOutboxId is still listed as dead-lettered after a successful requeue."
    }

    Write-Host "  Replayed with the original outbox id and event id, then delivered on attempt $($final.attemptCount)." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "PASS: transient failures retried as one record, dead-lettered at $maxAttempts attempts, then requeued and delivered with both identifiers preserved." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
