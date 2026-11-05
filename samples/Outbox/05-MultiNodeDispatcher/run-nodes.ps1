#requires -Version 7
<#
.SYNOPSIS
    Starts the receiver and three dispatcher nodes in separate windows, so you can watch the
    dispatch logs interleave in real time.

.DESCRIPTION
    verify.ps1 starts the same processes headlessly and asserts on the result. This script is for
    watching it happen: four windows, each labelled, left running until you close them.

    The nodes start one at a time, and each is healthy before the next begins. That is NOT about
    dispatch - it is about schema bootstrap. See README section 7.

.PARAMETER NodePorts
    The three node ports. Pass different values if any are occupied on your machine.

.EXAMPLE
    .\run-nodes.ps1
    Then: curl http://localhost:5005/orders ... and watch all three node windows.
#>
[CmdletBinding()]
param(
    [string] $SqlServer = ($env:OUTBOX_SAMPLES_SQL ?? '.\SQLEXPRESS'),
    [int]    $ReceiverPort = 5100,
    [int[]]  $NodePorts = @(5005, 5006, 5007)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $root '..')
$receiverProject = Join-Path $repoRoot 'shared\Outbox.Samples.Receiver'
$connectionString = "Server=$SqlServer;Database=OutboxSample05;Trusted_Connection=True;TrustServerCertificate=True"

function Assert-PortFree([int] $Port, [string] $Role) {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($listener) {
        $owner = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port ($Role) is already in use by process '$owner' (PID $($listener.OwningProcess)). Stop it, or pass a different port - see the parameters at the top of this script."
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

Assert-PortFree $ReceiverPort 'receiver'
for ($i = 0; $i -lt $NodePorts.Count; $i++) {
    Assert-PortFree $NodePorts[$i] "node $($i + 1)"
}

Write-Host 'Checking SQL Server...' -ForegroundColor Cyan
try {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $connection.Open()
    $connection.Close()
} catch {
    throw "Cannot reach SQL Server using '$connectionString'. Start SQL Server and create the database (see README Setup). Underlying error: $($_.Exception.Message)"
}

# Build once, up front. Three `dotnet run` invocations of the SAME project race on the build
# output and one reliably fails to start, so every window below uses --no-build.
Write-Host 'Building...' -ForegroundColor Cyan
dotnet build $receiverProject --nologo -v quiet | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the shared receiver.' }
dotnet build $root --nologo -v quiet | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the sample.' }

Write-Host "Starting receiver on http://localhost:$ReceiverPort..." -ForegroundColor Cyan
Start-Process pwsh -ArgumentList @(
    '-NoExit', '-Command',
    "`$Host.UI.RawUI.WindowTitle = 'outbox receiver'; dotnet run --no-build --project '$receiverProject' --urls 'http://localhost:$ReceiverPort'")
Wait-ForHttp "http://localhost:$ReceiverPort/health"

for ($i = 0; $i -lt $NodePorts.Count; $i++) {
    $nodeId = "node-$($i + 1)"
    $url = "http://localhost:$($NodePorts[$i])"

    Write-Host "Starting $nodeId on $url..." -ForegroundColor Cyan
    # --no-launch-profile matters: without it `dotnet run` applies the first profile in
    # launchSettings.json, whose OUTBOX__NODEID would override the one set here and leave all
    # three windows calling themselves node-1.
    Start-Process pwsh -ArgumentList @(
        '-NoExit', '-Command',
        "`$Host.UI.RawUI.WindowTitle = 'outbox $nodeId'; `$env:OUTBOX__NODEID = '$nodeId'; dotnet run --no-build --no-launch-profile --project '$root' --urls '$url'")
    Wait-ForHttp "$url/health"
}

Write-Host ''
Write-Host 'All four processes are up.' -ForegroundColor Green
Write-Host ''
Write-Host '  Receiver   http://localhost:' -NoNewline; Write-Host $ReceiverPort
for ($i = 0; $i -lt $NodePorts.Count; $i++) {
    Write-Host "  node-$($i + 1)     http://localhost:$($NodePorts[$i])"
}
Write-Host ''
Write-Host 'Place some orders and watch the three node windows:' -ForegroundColor Cyan
Write-Host ''
Write-Host "  1..30 | ForEach-Object { Invoke-RestMethod -NoProxy -Method Post -Uri `"http://localhost:$($NodePorts[0])/orders`" -ContentType 'application/json' -Body (@{ tenantId = 'acme'; customerId = `"cust-`$_`"; total = 10 } | ConvertTo-Json) } | Out-Null"
Write-Host ''
Write-Host 'Every order goes in on node-1, but all three nodes dispatch. Then try closing one' -ForegroundColor DarkGray
Write-Host 'node window mid-run: the remaining two finish the work.' -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Close the windows when you are done.' -ForegroundColor DarkGray
