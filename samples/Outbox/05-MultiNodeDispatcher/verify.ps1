#requires -Version 7
<#
.SYNOPSIS
    Smoke test for sample 05. Exits non-zero on failure.

.DESCRIPTION
    Asserts the claim is safe under contention: three dispatcher nodes run against ONE outbox
    table, and every record is delivered exactly once anyway.

    The assertion that matters is the negative one. 50 orders must produce exactly 50 deliveries.
    51 would mean two nodes dispatched the same record - the precise failure this sample exists
    to disprove - and that is a far more useful thing to catch than "it worked".

    It also proves the work was genuinely shared, by counting deliveries in each node's own log.
    A run where one node did all 50 would pass the duplicate check while demonstrating nothing,
    so that case fails too.

    It does NOT start SQL Server. It probes for it and fails fast with a clear message.

.PARAMETER SqlServer
    The SQL Server instance. Defaults to the OUTBOX_SAMPLES_SQL environment variable, then to
    .\SQLEXPRESS. Use the same value when creating the database with sqlcmd.

.PARAMETER NodePorts
    The three node ports. Pass different values if any are occupied on your machine.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $ReceiverPort = 5100,
    [int[]]  $NodePorts = @(5005, 5006, 5007),
    [int]    $OrderCount = 50
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$receiverProject = Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'
$connectionString = "Server=$SqlServer;Database=OutboxSample05;Trusted_Connection=True;TrustServerCertificate=True"
$receiver = "http://localhost:$ReceiverPort"
$processes = @()
$logDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "outbox-sample05-$PID"

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

try {
    Assert-PortFree $ReceiverPort 'receiver'
    for ($i = 0; $i -lt $NodePorts.Count; $i++) {
        Assert-PortFree $NodePorts[$i] "node $($i + 1)"
    }

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

    # Build once, up front. Three `dotnet run` invocations of the SAME project race on the build
    # output and one reliably fails to start, so every process below uses --no-build.
    Write-Host 'Building...' -ForegroundColor Cyan
    dotnet build $receiverProject --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the shared receiver.' }
    dotnet build $root --nologo -v quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to build the sample.' }

    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

    Write-Host 'Starting receiver...' -ForegroundColor Cyan
    $processes += Start-Process dotnet -PassThru -ArgumentList @(
        'run', '--no-build', '--project', $receiverProject, '--urls', $receiver)
    Wait-ForHttp "$receiver/health"

    Invoke-RestMethod -Method Delete -NoProxy -Uri "$receiver/deliveries" | Out-Null

    # Nodes start one at a time, and each is healthy before the next begins. Three processes
    # racing to create the same tables is a bootstrap problem, not a dispatch problem, and it
    # would muddy what this sample is actually demonstrating. See README section 7.
    $nodeLogs = @{}
    $nodeUrls = @()
    for ($i = 0; $i -lt $NodePorts.Count; $i++) {
        $nodeId = "node-$($i + 1)"
        $url = "http://localhost:$($NodePorts[$i])"
        $nodeUrls += $url
        $log = Join-Path $logDirectory "$nodeId.log"
        $nodeLogs[$nodeId] = $log

        Write-Host "Starting $nodeId on $url..." -ForegroundColor Cyan
        # --no-launch-profile matters. Without it `dotnet run` applies the FIRST profile in
        # launchSettings.json, whose OUTBOX__NODEID overrides the one set here, and all three
        # nodes report themselves as node-1. Delivery stays correct - safety comes from the row
        # claim, not from the identity - but every log line and ClaimOwner names the wrong node.
        $processes += Start-Process dotnet -PassThru `
            -RedirectStandardOutput $log `
            -RedirectStandardError (Join-Path $logDirectory "$nodeId.err.log") `
            -ArgumentList @('run', '--no-build', '--no-launch-profile', '--project', $root, '--urls', $url) `
            -Environment @{ OUTBOX__NODEID = $nodeId }
        Wait-ForHttp "$url/health"

        # Each node must know which node it is, or the logs and ClaimOwner values are useless
        # for diagnosis. This caught the launch-profile override above.
        $identity = Invoke-RestMethod -NoProxy -Uri "$url/"
        if ($identity.node -ne $nodeId) {
            throw "The node on $url reports its identity as '$($identity.node)' but should be '$nodeId'. Something is overriding OUTBOX__NODEID - check that 'dotnet run' is passed --no-launch-profile."
        }
    }

    # -------------------------------------------------------------------------------------------
    # Place the orders, spread evenly across the three nodes.
    # -------------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host "Placing $OrderCount orders across $($nodeUrls.Count) nodes..." -ForegroundColor Cyan

    $submitted = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $OrderCount; $i++) {
        $target = $nodeUrls[$i % $nodeUrls.Count]
        $response = Invoke-RestMethod -Method Post -NoProxy -Uri "$target/orders" -ContentType 'application/json' `
            -Body (@{ tenantId = 'acme'; customerId = "cust-$i"; total = 10.00 + $i } | ConvertTo-Json)
        $submitted.Add([string] $response.outboxIds[0])
    }

    if ($submitted.Count -ne $OrderCount) {
        throw "Expected to submit $OrderCount orders, submitted $($submitted.Count)."
    }
    $distinctSubmitted = ($submitted | Select-Object -Unique).Count
    if ($distinctSubmitted -ne $OrderCount) {
        throw "Expected $OrderCount distinct outbox ids on submission, got $distinctSubmitted."
    }

    # -------------------------------------------------------------------------------------------
    # Assertion 1: every record arrives, exactly once.
    # -------------------------------------------------------------------------------------------
    Write-Host 'Waiting for deliveries...' -ForegroundColor Cyan

    # Generous: three nodes contending for claims is slower than one node working alone.
    $summary = Wait-For `
        -Produce { Invoke-RestMethod -NoProxy -Uri "$receiver/deliveries/summary" } `
        -Condition { param($s) $s.total -ge $OrderCount } `
        -TimeoutSeconds 120 `
        -Description "$OrderCount deliveries to reach the receiver"

    # Settle, so a duplicate that is merely late still fails the run rather than slipping past.
    Start-Sleep -Seconds 5
    $summary = Invoke-RestMethod -NoProxy -Uri "$receiver/deliveries/summary"

    if ($summary.total -ne $OrderCount) {
        throw "Expected exactly $OrderCount deliveries, got $($summary.total). More than $OrderCount means two nodes dispatched the same record - the claim is not safe under contention."
    }
    if ($summary.distinctOutboxIds -ne $OrderCount) {
        throw "Expected $OrderCount distinct outbox ids, got $($summary.distinctOutboxIds)."
    }
    if ($summary.distinctEventIds -ne $OrderCount) {
        throw "Expected $OrderCount distinct event ids, got $($summary.distinctEventIds)."
    }

    # Every id that was submitted is an id that arrived. Counts alone could match while the
    # contents differed.
    #
    # Note the two statements. Invoke-RestMethod writes a JSON array to the pipeline as ONE
    # object instead of enumerating it, so piping it straight into ForEach-Object or
    # Where-Object silently processes the whole array as a single item. Materialise it first.
    $deliveries = Invoke-RestMethod -NoProxy -Uri "$receiver/deliveries"
    $received = @($deliveries | ForEach-Object { [string] $_.outboxId })
    if ($received.Count -ne $OrderCount) {
        throw "Expected to read back $OrderCount deliveries, got $($received.Count)."
    }

    $missing = @($submitted | Where-Object { $_ -notin $received })
    if ($missing.Count -ne 0) {
        throw "$($missing.Count) submitted outbox ids never arrived, including $($missing[0])."
    }

    Write-Host "  $($summary.total) deliveries, $($summary.distinctOutboxIds) distinct outbox ids." -ForegroundColor DarkGray

    # -------------------------------------------------------------------------------------------
    # Assertion 2: the work was shared. One node doing everything would pass the check above
    # while demonstrating nothing about contention.
    # -------------------------------------------------------------------------------------------
    Write-Host 'Checking the work was shared...' -ForegroundColor Cyan

    $perNode = @{}
    foreach ($nodeId in $nodeLogs.Keys | Sort-Object) {
        $log = $nodeLogs[$nodeId]
        if (-not (Test-Path $log)) {
            throw "No log was captured for $nodeId at $log."
        }
        # Event 3001, logged by OutboxDeliveryProcessor at Debug once a delivery is persisted.
        $perNode[$nodeId] = @(Select-String -Path $log -Pattern 'Delivered [0-9a-f-]{36} to ' -AllMatches).Count
    }

    $idle = @($perNode.Keys | Where-Object { $perNode[$_] -eq 0 } | Sort-Object)
    if ($idle.Count -ne 0) {
        throw "These nodes dispatched nothing: $($idle -join ', '). The work was not shared, so this run does not demonstrate anything about contention. Logs are in $logDirectory."
    }

    $totalDispatched = ($perNode.Values | Measure-Object -Sum).Sum
    if ($totalDispatched -ne $OrderCount) {
        throw "The nodes logged $totalDispatched deliveries between them but $OrderCount were expected. Logs are in $logDirectory."
    }

    $breakdown = ($perNode.Keys | Sort-Object | ForEach-Object { "$_=$($perNode[$_])" }) -join ', '
    Write-Host "  $breakdown" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host "PASS: $OrderCount orders placed across $($nodeUrls.Count) dispatcher nodes sharing one outbox table were delivered exactly $OrderCount times ($breakdown)." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Stop-Everything

    # The nodes hold handles on their log files, so give the OS a moment to release them -
    # otherwise every run litters TEMP with a directory that could not be deleted.
    Start-Sleep -Milliseconds 500
    Remove-Item $logDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
