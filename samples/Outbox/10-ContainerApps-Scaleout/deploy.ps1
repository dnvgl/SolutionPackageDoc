#requires -Version 7
<#
.SYNOPSIS
    Builds the sample 10 image, pushes it to the registry and rolls it out to Container Apps.

.DESCRIPTION
    Four steps, in this order and for a reason:

      1. publish the image with the .NET SDK container support (no Dockerfile)
      2. run it locally and require it to start
      3. push it
      4. hand the tag to provision.ps1, which creates or updates the container app

    Step 2 is the point of this script existing rather than being three commands in the README.
    An image built on Windows that targets the wrong architecture, or whose entrypoint is wrong,
    fails in Azure as a revision that crash-loops with almost no diagnostics. Locally it fails in
    two seconds with a readable message.

.PARAMETER ResourceGroup
    Resource group holding the infrastructure created by infra\provision.ps1.

.EXAMPLE
    .\deploy.ps1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-outbox-samples',
    [string] $Tag = (Get-Date -Format 'yyyyMMddHHmmss'),

    [Parameter(HelpMessage = 'Subscription holding the infrastructure. Defaults to the CLI''s current one.')]
    [string] $SubscriptionId = '',

    [switch] $SkipLocalRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$repository = 'outbox-scaleout'

function Invoke-Native {
    param([Parameter(Mandatory)] [string] $Executable, [Parameter(Mandatory)] [string[]] $Arguments)

    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable $($Arguments -join ' ') failed:`n$($output | Out-String)"
    }
    return $output
}

try {
    # The CLI's active subscription is global state that anything can change between runs. Say
    # which one this is using, because "resource group not found" when the group is plainly there
    # is otherwise a genuinely confusing five minutes.
    if ($SubscriptionId) {
        Invoke-Native az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    }
    $subscription = (Invoke-Native az @('account', 'show', '--query', '[name, id]', '-o', 'tsv') | Out-String).Trim()
    Write-Host "Subscription: $($subscription -replace '\s+', ' ')" -ForegroundColor Cyan

    Write-Host 'Locating the container registry...' -ForegroundColor Cyan
    $loginServer = (Invoke-Native az @('acr', 'list', '--resource-group', $ResourceGroup,
        '--query', '[0].loginServer', '-o', 'tsv') | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($loginServer)) {
        throw "No container registry in '$ResourceGroup'. Run ..\infra\provision.ps1 -Samples '10' first."
    }
    Write-Host "  $loginServer"

    $localImage = "${repository}:$Tag"
    $remoteImage = "$loginServer/${repository}:$Tag"

    # ------------------------------------------------------------------------------------------
    # -r linux-x64 is not optional.
    #
    # Without it the SDK builds for the host runtime identifier, so a build on Windows produces a
    # Windows container. Container Apps runs Linux, and the resulting revision fails to start with
    # an error that says nothing about architecture.
    # ------------------------------------------------------------------------------------------
    Write-Host "Publishing $localImage..." -ForegroundColor Cyan
    Invoke-Native dotnet @('publish', (Join-Path $root 'App\App.csproj'),
        '-c', 'Release',
        '-r', 'linux-x64',
        '--self-contained', 'false',
        '/t:PublishContainer',
        "-p:ContainerRepository=$repository",
        "-p:ContainerImageTag=$Tag") | Out-Null
    Write-Host '  built.'

    if (-not $SkipLocalRun) {
        Write-Host 'Starting the image locally to prove it runs...' -ForegroundColor Cyan
        $smoke = & docker run --rm -e OUTBOX_SMOKE=1 $localImage 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "The image does not start. Nothing was pushed.`n$($smoke | Out-String)"
        }
        Write-Host "  $($smoke | Out-String)".TrimEnd()
    }

    Write-Host 'Pushing...' -ForegroundColor Cyan
    Invoke-Native az @('acr', 'login', '--name', ($loginServer -split '\.')[0]) | Out-Null
    Invoke-Native docker @('tag', $localImage, $remoteImage) | Out-Null
    Invoke-Native docker @('push', $remoteImage) | Out-Null
    Write-Host "  $remoteImage"

    # The container app is created by the same template as everything else rather than by an
    # `az containerapp create` here, so that the image is the only thing this script decides.
    Write-Host 'Deploying the container app...' -ForegroundColor Cyan
    & (Join-Path $root '..\infra\provision.ps1') -Samples '09', '10' -ContainerImage $remoteImage -SkipWhatIf -ResourceGroup $ResourceGroup
    if ($LASTEXITCODE -ne 0) { throw 'Provisioning failed.' }

    $fqdn = (Invoke-Native az @('containerapp', 'show', '--only-show-errors',
        '--resource-group', $ResourceGroup, '--name', 'ca-outbox-scaleout',
        '--query', 'properties.configuration.ingress.fqdn', '-o', 'tsv') | Out-String).Trim()

    Write-Host ''
    Write-Host "Deployed: https://$fqdn" -ForegroundColor Green
    Write-Host 'Replicas:' -ForegroundColor Green
    & az containerapp replica list --only-show-errors --resource-group $ResourceGroup --name ca-outbox-scaleout `
        --query '[].{replica:name, created:properties.createdTime}' -o table
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
