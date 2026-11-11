#requires -Version 7
<#
.SYNOPSIS
    Provisions the shared Azure infrastructure for the Outbox samples. Exits non-zero on failure.

.DESCRIPTION
    Deploys only what the requested samples need, after showing a what-if diff. Everything it
    creates is billable, so it prints an estimated monthly cost and the teardown command before
    it finishes.

    Authentication is Entra throughout: no connection strings, no SAS keys. The signed-in
    developer is granted the Service Bus data-plane roles, because samples that run on your own
    machine authenticate as you.

.PARAMETER Samples
    Sample numbers to provision, e.g. 09. Pass only what you intend to run.

.EXAMPLE
    .\provision.ps1 -Samples 09
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('09', '10')]
    [string[]] $Samples,

    [string] $ResourceGroup = 'rg-outbox-samples',
    [string] $Location = 'southeastasia',
    [int]    $BudgetAmount = 50,

    [switch] $SkipWhatIf
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

# Rates verified against the Azure retail pricing API for southeastasia on 2026-10-23.
$hourlyRates = @{
    '09' = @{ Resource = 'Service Bus Standard namespace'; Hourly = 0.013441 }
    '10' = @{ Resource = 'Container Apps + registry';      Hourly = 0.0069 }
}

function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $Arguments, [switch] $Raw)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    if ($Raw) { return $output }
    return ($output | Out-String).Trim()
}

try {
    Write-Host 'Checking the Azure CLI session...' -ForegroundColor Cyan
    try {
        $account = Invoke-Az @('account', 'show', '-o', 'json') | ConvertFrom-Json
    } catch {
        throw "Not signed in. Run 'az login', then 'az account set --subscription <id>', and try again."
    }

    Write-Host "  subscription: $($account.name) ($($account.id))"
    Write-Host "  signed in as: $($account.user.name)"

    # Everything below bills to the subscription above. Say so before creating anything, because
    # the wrong subscription is the single most expensive mistake available here.
    $developerObjectId = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
    $developerMail = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'mail', '-o', 'tsv')
    if ([string]::IsNullOrWhiteSpace($developerMail)) { $developerMail = $account.user.name }

    Write-Host "Creating resource group '$ResourceGroup' in $Location..." -ForegroundColor Cyan
    Invoke-Az @('group', 'create', '--name', $ResourceGroup, '--location', $Location, '-o', 'none') | Out-Null

    $template = Join-Path $root 'main.bicep'

    # A parameters file rather than inline `name=value` pairs: array values have to be JSON, and
    # getting JSON through cmd.exe quoting intact is a losing game on Windows.
    $parameterFile = Join-Path ([System.IO.Path]::GetTempPath()) "outbox-samples-$([guid]::NewGuid()).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            samples             = @{ value = @($Samples) }
            developerObjectIds  = @{ value = @($developerObjectId) }
            budgetContactEmails = @{ value = @($developerMail) }
            budgetAmount        = @{ value = $BudgetAmount }
            location            = @{ value = $Location }
        }
    } | ConvertTo-Json -Depth 6 | Set-Content $parameterFile -Encoding utf8

    if (-not $SkipWhatIf) {
        # Not optional by default. This is the only thing standing between a typo and a surprise
        # bill, and it is cheap.
        Write-Host 'Previewing changes (what-if)...' -ForegroundColor Cyan
        Invoke-Az -Raw -Arguments @('deployment', 'group', 'what-if',
            '--resource-group', $ResourceGroup,
            '--template-file', $template,
            '--parameters', $parameterFile) | Write-Host
    }

    Write-Host 'Deploying...' -ForegroundColor Cyan
    $deployment = Invoke-Az -Arguments @('deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name', "outbox-samples-$(Get-Date -Format 'yyyyMMddHHmmss')",
        '--template-file', $template,
        '--parameters', $parameterFile,
        '-o', 'json') | ConvertFrom-Json

    $outputs = $deployment.properties.outputs

    Write-Host ''
    Write-Host 'Provisioned:' -ForegroundColor Green
    if ($outputs.serviceBusNamespace.value) {
        Write-Host "  Service Bus namespace : $($outputs.serviceBusNamespace.value)"
        Write-Host "  queue                 : $($outputs.serviceBusQueue.value)  (duplicate detection: 10 minutes)"
        Write-Host "  topic                 : $($outputs.serviceBusTopic.value)"
    }

    # Role assignments propagate asynchronously. Saying so here saves the reader from concluding
    # the sample is broken when a token minted 10 seconds later is still missing the role.
    Write-Host ''
    Write-Host "Granted 'Azure Service Bus Data Sender' and 'Data Receiver' to $($account.user.name)." -ForegroundColor Green
    Write-Host 'Role assignments can take a minute or two to propagate. If the sample reports 401' -ForegroundColor Yellow
    Write-Host 'or "Unauthorized access", wait a moment and try again.' -ForegroundColor Yellow

    $hourly = ($Samples | ForEach-Object { $hourlyRates[$_].Hourly } | Measure-Object -Sum).Sum
    Write-Host ''
    Write-Host ('Estimated cost: {0:N4} USD/hour, about {1:N2} USD/month if left running.' -f $hourly, ($hourly * 730)) -ForegroundColor Yellow
    Write-Host "A budget of $BudgetAmount USD/month alerts $developerMail at 80 percent actual and 100 percent forecast."
    Write-Host ''
    Write-Host 'Delete everything when you are done:' -ForegroundColor Yellow
    Write-Host "  .\teardown.ps1 -ResourceGroup $ResourceGroup"
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($parameterFile -and (Test-Path $parameterFile)) {
        Remove-Item $parameterFile -ErrorAction SilentlyContinue
    }
}
