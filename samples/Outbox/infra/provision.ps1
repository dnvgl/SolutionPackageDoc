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

    [Parameter(HelpMessage = 'Image for the sample 10 container app. deploy.ps1 supplies this on the second pass.')]
    [string] $ContainerImage = '',

    [Parameter(HelpMessage = 'Provision Azure SQL on paid compute because the subscription free database is already taken.')]
    [switch] $NoSqlFreeLimit,

    [switch] $SkipWhatIf
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

# Rates verified against the Azure retail pricing API for southeastasia on 2026-10-23.
#
# Sample 10 is the expensive one and the number below is not a rounding error. Two always-on
# replicas at 0.25 vCPU / 0.5 GiB consume about 1.3M vCPU-seconds and 2.6M GiB-seconds a month
# against free grants of 180k and 360k. What is left bills at the active rate whenever the
# dispatcher is doing anything, and at the much cheaper idle rate when it is not - so real
# spend lands somewhere between about 11 and 38 USD/month. The figure here assumes the
# pessimistic end, plus 5.06 USD/month for a Basic registry. Azure SQL is on the free offer and
# contributes nothing.
$hourlyRates = @{
    '09' = @{ Resource = 'Service Bus Standard namespace'; Hourly = 0.013441 }
    '10' = @{ Resource = 'Container Apps (2 replicas) + ACR Basic + Azure SQL free'; Hourly = 0.0590 }
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
    $developerUpn = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'userPrincipalName', '-o', 'tsv')

    # No IP lookup here. An address discovered over HTTP is the address your HTTP traffic leaves
    # from, which a proxy or split-tunnel VPN makes different from the one port 1433 leaves from -
    # so the rule it produces can be confidently wrong. The firewall rule for this machine is
    # instead created further down, from the address SQL itself reports rejecting.
    $developerIp = ''

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
            sqlAdminObjectId    = @{ value = $developerObjectId }
            sqlAdminLogin       = @{ value = $developerUpn }
            developerIpAddress  = @{ value = $developerIp }
            useSqlFreeLimit     = @{ value = (-not $NoSqlFreeLimit.IsPresent) }
            containerImage      = @{ value = $ContainerImage }
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
    if ($outputs.scaleOutTopic.value) {
        Write-Host "  scale-out topic       : $($outputs.scaleOutTopic.value)  (duplicate detection: OFF, on purpose)"
        Write-Host "  scale-out subscription: $($outputs.scaleOutSubscription.value)"
    }
    if ($outputs.sqlServerFqdn.value) {
        Write-Host "  Azure SQL server      : $($outputs.sqlServerFqdn.value)"
        Write-Host "  Azure SQL database    : $($outputs.sqlDatabaseName.value)"
    }
    if ($outputs.registryLoginServer.value) {
        Write-Host "  container registry    : $($outputs.registryLoginServer.value)"
    }
    if ($outputs.containerAppFqdn.value) {
        Write-Host "  container app         : https://$($outputs.containerAppFqdn.value)"
    }

    # ------------------------------------------------------------------------------------------
    # Read the cost controls back off the live database.
    #
    # The template asks for the free offer; this checks it was granted. The subscription allows
    # exactly one free database, so a second one - or a redeploy after someone created a free
    # database elsewhere - silently lands on paid serverless at roughly 450 USD/month. The
    # template would still say the right thing. Only the resource knows.
    # ------------------------------------------------------------------------------------------
    if ($outputs.sqlServerFqdn.value) {
        Write-Host ''
        Write-Host 'Verifying the Azure SQL cost controls...' -ForegroundColor Cyan
        $serverName = ($outputs.sqlServerFqdn.value -split '\.')[0]
        $db = Invoke-Az @('sql', 'db', 'show',
            '--resource-group', $ResourceGroup,
            '--server', $serverName,
            '--name', $outputs.sqlDatabaseName.value,
            '-o', 'json') | ConvertFrom-Json

        Write-Host ("  sku                         : {0}" -f $db.currentServiceObjectiveName)
        Write-Host ("  useFreeLimit                : {0}" -f $db.useFreeLimit)
        Write-Host ("  freeLimitExhaustionBehavior : {0}" -f $db.freeLimitExhaustionBehavior)
        Write-Host ("  autoPauseDelay (minutes)    : {0}" -f $db.autoPauseDelay)

        if (-not $NoSqlFreeLimit -and (-not $db.useFreeLimit -or $db.freeLimitExhaustionBehavior -ne 'AutoPause')) {
            throw "The database is NOT on the free offer with AutoPause. It will bill at the serverless rate. Delete it with .\teardown.ps1 before going any further."
        }
    }

    # ------------------------------------------------------------------------------------------
    # Give the container app's identity a database user.
    #
    # The server is Entra-only, and Entra-only servers do not take ARM role assignments for data
    # plane access - 'SQL DB Contributor' lets you manage the database and not read a single row.
    # Access is a contained database user created from the directory, which can only be done over
    # a SQL connection, which is why this is here and not in the template. db_ddladmin is needed
    # because the sample creates its own schema on startup.
    # ------------------------------------------------------------------------------------------
    if ($outputs.containerAppIdentityName.value) {
        $identityName = $outputs.containerAppIdentityName.value
        Write-Host ''
        Write-Host "Granting the managed identity '$identityName' access to the database..." -ForegroundColor Cyan

        $grant = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$identityName')
    CREATE USER [$identityName] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$identityName];
ALTER ROLE db_datawriter ADD MEMBER [$identityName];
ALTER ROLE db_ddladmin  ADD MEMBER [$identityName];
"@

        # An access token from the CLI rather than sqlcmd -G.
        #
        # sqlcmd's -G with no user name resolves to ActiveDirectoryIntegrated, which cannot
        # satisfy a conditional-access MFA policy and fails with AADSTS50076 on any tenant that
        # has one. `az login` has already done that interactive dance, so reusing its token is
        # both simpler and the only thing that works unattended. It also removes the dependency
        # on sqlcmd being installed at all.
        $accessToken = Invoke-Az @('account', 'get-access-token',
            '--resource', 'https://database.windows.net/', '--query', 'accessToken', '-o', 'tsv')

        $connectionString = "Server=tcp:$($outputs.sqlServerFqdn.value),1433;Database=$($outputs.sqlDatabaseName.value);Encrypt=True;Connect Timeout=120"
        $serverShortName = ($outputs.sqlServerFqdn.value -split '\.')[0]

        # Two attempts, because the first one is also how the firewall gets configured.
        #
        # The template opens the firewall for whatever address an IP lookup returned, and that is
        # not reliably the address SQL sees: an HTTP proxy, a split-tunnel VPN or corporate egress
        # will answer the lookup from one address and carry port 1433 from another. Rather than
        # guess better, let the server say which address it rejected and add that one.
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $connection = New-Object System.Data.SqlClient.SqlConnection
            $connection.ConnectionString = $connectionString
            $connection.AccessToken = $accessToken
            try {
                $connection.Open()
                $command = $connection.CreateCommand()
                $command.CommandText = $grant
                $command.CommandTimeout = 120
                $command.ExecuteNonQuery() | Out-Null
                Write-Host '  db_datareader, db_datawriter, db_ddladmin granted.'
                break
            } catch {
                $message = $_.Exception.Message
                if ($attempt -eq 1 -and $message -match "Client with IP address '([0-9\.]+)'") {
                    $blockedIp = $Matches[1]
                    Write-Host "  SQL rejected this machine's real address $blockedIp; adding a firewall rule..." -ForegroundColor Yellow
                    Invoke-Az @('sql', 'server', 'firewall-rule', 'create',
                        '--resource-group', $ResourceGroup,
                        '--server', $serverShortName,
                        '--name', "AllowDeveloper-$($blockedIp -replace '\.', '-')",
                        '--start-ip-address', $blockedIp,
                        '--end-ip-address', $blockedIp, '-o', 'none') | Out-Null
                    Start-Sleep -Seconds 10
                    continue
                }
                throw "Granting database access failed: $message"
            } finally {
                $connection.Dispose()
            }
        }
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
