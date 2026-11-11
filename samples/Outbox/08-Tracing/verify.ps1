#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 08. Exits non-zero on failure.

.DESCRIPTION
    Asserts that a trace survives the outbox: the hand-off is asynchronous and happens in another
    process, but it stays part of the trace that caused it.

    Three phases:

      1. Ambient  - a request arrives carrying a traceparent. The outbox captures Activity.Current
                    and the receiver, reached seconds later by the dispatcher, sees the SAME
                    trace id.
      2. Explicit - an OutboxTraceContext supplied on the enqueue request overrides the ambient
                    one, verbatim. This is the escape hatch for when Activity.Current is not the
                    parent you want.
      3. Exported - the library's "DNV.Outbox" ActivitySource really produces a span, under the
                    originating trace id, and the console exporter shows it.

    It does NOT start SQL Server. It probes for it and fails fast with a clear message.

.PARAMETER SqlServer
    The SQL Server instance. Defaults to the OUTBOX_SAMPLES_SQL environment variable, then to
    .\SQLEXPRESS. Use the same value when creating the database with sqlcmd.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $ReceiverPort = 5100,
    [int]    $ApiPort = 5008
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$connectionString = "Server=$SqlServer;Database=OutboxSample08;Trusted_Connection=True;TrustServerCertificate=True"
$receiver = "http://localhost:$ReceiverPort"
$api = "http://localhost:$ApiPort"
$processes = @()

# The sample's console exporter writes to stdout, which is redirected here so the exported spans
# can be asserted on rather than merely admired.
$traceLog = Join-Path $root 'traces.log'

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

function New-TraceId { -join ((1..32) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }
function New-SpanId { -join ((1..16) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }

# "00-<32 hex trace id>-<16 hex span id>-<2 hex flags>". The 01 flag is "sampled": without it the
# default parent-based sampler drops the span and the console exporter stays silent.
function New-TraceParent([string] $TraceId, [string] $SpanId) { "00-$TraceId-$SpanId-01" }

function Get-TraceId([string] $TraceParent) {
    if ($TraceParent -notmatch '^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$') {
        throw "'$TraceParent' is not a W3C traceparent."
    }
    return $Matches[1]
}

function Get-SpanId([string] $TraceParent) {
    if ($TraceParent -notmatch '^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$') {
        throw "'$TraceParent' is not a W3C traceparent."
    }
    return $Matches[2]
}

function Get-Delivery([string] $OutboxId) {
    $all = Get-Collection "$receiver/deliveries"
    return @($all | Where-Object { $_.outboxId -eq $OutboxId })
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

    Remove-Item $traceLog -ErrorAction SilentlyContinue

    Write-Host 'Starting receiver...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--no-launch-profile', '--project', (Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'),
        '--urls', $receiver)
    Wait-ForHttp "$receiver/health"

    Write-Host 'Starting sample API (console exporter -> traces.log)...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -RedirectStandardOutput $traceLog -ArgumentList @(
        'run', '--no-build', '--no-launch-profile', '--project', $root, '--urls', $api)
    Wait-ForHttp "$api/health"

    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null

    # ---------------------------------------------------------------------------------------
    # Phase 1: the ambient trace is captured and replayed.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 1: the ambient trace survives the hand-off...' -ForegroundColor Cyan

    $callerTraceId = New-TraceId
    $callerSpanId = New-SpanId
    $callerTraceParent = New-TraceParent $callerTraceId $callerSpanId

    $ambient = Invoke-RestMethod -Method Post -NoProxy -Uri "$api/orders" -ContentType 'application/json' `
        -Headers @{ traceparent = $callerTraceParent } `
        -Body (@{ tenantId = 'acme'; customerId = 'cust-ambient'; total = 42.00 } | ConvertTo-Json)

    $ambientOutboxId = $ambient.outboxId

    # What was persisted, before anything has been delivered. This is the producer side.
    $stored = Invoke-RestMethod -NoProxy -Uri "$api/outbox/$ambientOutboxId"
    if ([string]::IsNullOrWhiteSpace($stored.traceParent)) {
        throw "The outbox record has no traceparent. Activity.Current was not captured at enqueue time - check that OpenTelemetry (or at least an ActivityListener) is registered."
    }
    if ((Get-TraceId $stored.traceParent) -ne $callerTraceId) {
        throw "The outbox persisted trace id $(Get-TraceId $stored.traceParent) but the caller sent $callerTraceId."
    }
    if ((Get-SpanId $stored.traceParent) -eq $callerSpanId) {
        throw "The outbox persisted the caller's span id verbatim. It should capture the server span created for the incoming request, which is a child of the caller's span."
    }

    $ambientDelivery = Wait-For `
        -Produce { Get-Delivery $ambientOutboxId } `
        -Condition { param($d) $d.Count -ge 1 } `
        -TimeoutSeconds 60 `
        -Description "outbox $ambientOutboxId to reach the receiver"

    $receivedTraceParent = $ambientDelivery[0].traceParent
    if ([string]::IsNullOrWhiteSpace($receivedTraceParent)) {
        throw 'The receiver saw no traceparent header. The trace did not survive the outbox.'
    }
    if ((Get-TraceId $receivedTraceParent) -ne $callerTraceId) {
        throw "The receiver saw trace id $(Get-TraceId $receivedTraceParent) but the caller started trace $callerTraceId. The trace did not survive the database round trip."
    }

    # NOT asserted: that the receiver sees the persisted traceparent verbatim. It does when
    # nothing instruments HttpClient (sample 01), but here OpenTelemetry's HttpClient
    # instrumentation creates a client span and the HTTP stack re-injects traceparent from it.
    # The span id therefore moves on by a link in the chain - which is correct, and is what
    # phase 3 verifies. The trace id is the invariant.

    Write-Host "  trace ${callerTraceId}: caller span $callerSpanId -> persisted span $(Get-SpanId $stored.traceParent) -> receiver span $(Get-SpanId $receivedTraceParent)." -ForegroundColor DarkGray

    # ---------------------------------------------------------------------------------------
    # Phase 2: an explicit context wins over the ambient one.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 2: an explicit trace context overrides the ambient one...' -ForegroundColor Cyan

    $explicitTraceId = New-TraceId
    $explicitSpanId = New-SpanId
    $explicitTraceParent = New-TraceParent $explicitTraceId $explicitSpanId

    # Sent WITH an ambient traceparent as well, so the assertion proves precedence rather than
    # merely proving that something was persisted.
    $ambientTraceId = New-TraceId
    $explicit = Invoke-RestMethod -Method Post -NoProxy -Uri "$api/orders" -ContentType 'application/json' `
        -Headers @{ traceparent = (New-TraceParent $ambientTraceId (New-SpanId)) } `
        -Body (@{ tenantId = 'acme'; customerId = 'cust-explicit'; total = 7.00; traceParent = $explicitTraceParent } | ConvertTo-Json)

    if ($explicit.traceParent -ne $explicitTraceParent) {
        throw "Expected the explicit traceparent '$explicitTraceParent' to be persisted verbatim, got '$($explicit.traceParent)'. An explicit OutboxTraceContext must win over Activity.Current, span id included."
    }

    $explicitDelivery = Wait-For `
        -Produce { Get-Delivery $explicit.outboxId } `
        -Condition { param($d) $d.Count -ge 1 } `
        -TimeoutSeconds 60 `
        -Description "outbox $($explicit.outboxId) to reach the receiver"

    $deliveredTraceId = Get-TraceId $explicitDelivery[0].traceParent
    if ($deliveredTraceId -ne $explicitTraceId) {
        throw "The receiver saw trace $deliveredTraceId; the explicit context named $explicitTraceId."
    }
    if ($deliveredTraceId -eq $ambientTraceId) {
        throw "The ambient trace $ambientTraceId reached the receiver. The explicit OutboxTraceContext was ignored."
    }

    Write-Host "  trace $explicitTraceId was persisted verbatim and delivered, in spite of the ambient trace $ambientTraceId." -ForegroundColor DarkGray

    # ---------------------------------------------------------------------------------------
    # Phase 3: the library's own span is exported under the originating trace.
    # ---------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host 'Phase 3: the dispatch span is exported as a child of the persisted span...' -ForegroundColor Cyan

    # The exporter batches, so the span may lag the delivery by a second or two.
    $null = Wait-For `
        -Produce { if (Test-Path $traceLog) { Get-Content $traceLog -Raw } else { '' } } `
        -Condition { param($t) $t -match 'outbox publish receiver' -and $t -match $callerTraceId } `
        -TimeoutSeconds 60 `
        -Description 'the console exporter to emit the outbox publish span'

    # The console exporter writes one block per span, starting with Activity.TraceId and ending at
    # a blank line, with DisplayName a few lines INTO the block. So find the block, then read its
    # first line - not the other way round.
    $blocks = ((Get-Content $traceLog -Raw) -split '(?m)^Activity\.TraceId:') |
        Where-Object { $_ -match 'outbox publish receiver' }

    if ($blocks.Count -eq 0) {
        throw 'The console exporter never emitted a span named ''outbox publish receiver''. The DNV.Outbox ActivitySource is not being subscribed to - check AddSource("DNV.Outbox").'
    }

    $exported = @($blocks | Where-Object { $_ -match "^\s+$callerTraceId\b" })
    if ($exported.Count -eq 0) {
        $seen = @($blocks | ForEach-Object { if ($_ -match '^\s+([0-9a-f]{32})') { $Matches[1] } })
        throw "The order was placed in trace $callerTraceId, but the exported dispatch spans belong to $($seen -join ', '). The dispatcher is not restoring the persisted parent."
    }

    # The claim, stated precisely: the dispatch span's parent is the span the producer persisted,
    # even though it was started minutes later by a background service that never saw it.
    $persistedSpanId = Get-SpanId $stored.traceParent
    if ($exported[0] -notmatch "Activity\.ParentSpanId:\s+$persistedSpanId") {
        $actual = if ($exported[0] -match 'Activity\.ParentSpanId:\s+([0-9a-f]{16})') { $Matches[1] } else { '<none>' }
        throw "The dispatch span's parent is $actual, but the outbox persisted span $persistedSpanId. The persisted trace context was not restored as the parent."
    }

    if ($exported[0] -notmatch 'outbox\.id:\s+' + $ambientOutboxId) {
        throw "The exported dispatch span does not carry outbox.id $ambientOutboxId."
    }

    Write-Host "  'outbox publish receiver' was exported under trace $callerTraceId, parented on the persisted span $persistedSpanId." -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "PASS: the trace started by the caller survived a database round trip and an asynchronous hand-off in another process - the receiver saw the same trace id, the explicit override was honoured, and the dispatch span was exported as a child of the span that was persisted with the order." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything
}
