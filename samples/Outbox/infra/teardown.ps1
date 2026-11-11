#requires -Version 7
<#
.SYNOPSIS
    Deletes the Outbox samples resource group and everything in it.

.DESCRIPTION
    Lists what will be destroyed and asks for confirmation before doing it. This is the last
    section of every Azure sample README, because a namespace left running bills whether or not
    anyone is using it.

.PARAMETER Force
    Skip the confirmation prompt. Intended for scripted cleanup.

.EXAMPLE
    .\teardown.ps1
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-outbox-samples',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

try {
    $exists = (& az group exists --name $ResourceGroup) -eq 'true'
    if (-not $exists) {
        Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Green
        exit 0
    }

    $account = & az account show -o json | ConvertFrom-Json
    Write-Host "Subscription: $($account.name) ($($account.id))"
    Write-Host "About to DELETE resource group '$ResourceGroup' and everything in it:" -ForegroundColor Yellow
    & az resource list --resource-group $ResourceGroup --query '[].{name:name, type:type}' -o table

    if (-not $Force) {
        $answer = Read-Host "`nType the resource group name to confirm"
        if ($answer -ne $ResourceGroup) {
            Write-Host 'Cancelled. Nothing was deleted.' -ForegroundColor Yellow
            exit 1
        }
    }

    # --no-wait returns immediately; deletion continues in Azure. Billing stops as each resource
    # is removed, not when this command returns.
    & az group delete --name $ResourceGroup --yes --no-wait
    if ($LASTEXITCODE -ne 0) { throw "az group delete failed with exit code $LASTEXITCODE." }

    Write-Host ''
    Write-Host "Deletion of '$ResourceGroup' started. It continues in the background." -ForegroundColor Green
    Write-Host "Check progress with:  az group exists --name $ResourceGroup"
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
