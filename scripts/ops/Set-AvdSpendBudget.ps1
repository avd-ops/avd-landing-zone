#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Creates or updates a sandbox subscription's standing cost budget, named sandbox-spend, so Azure
  emails you even when no landing zone is deployed (docs/sandbox-runs.md).

.DESCRIPTION
  A write: run it yourself in Azure Cloud Shell (PowerShell). Remove-AvdDemo.ps1 deletes only the
  landing zone's own budget-<name>, never this one. Supports -WhatIf.

.EXAMPLE
  ./scripts/ops/Set-AvdSpendBudget.ps1 -Amount 150 -Email you@contoso.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateRange(1, 100000)][double] $Amount,
  [Parameter(Mandatory)][string[]] $Email,
  [string] $SubscriptionId,
  [string] $Name = 'sandbox-spend'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$now = (Get-Date).ToUniversalTime()
$notify = { param($pct, $type) @{ enabled = $true; operator = 'GreaterThan'; threshold = $pct; thresholdType = $type; contactEmails = @($Email) } }
$body = @{
  properties = @{
    category      = 'Cost'
    amount        = $Amount
    timeGrain     = 'Monthly'
    timePeriod    = @{ startDate = [datetime]::new($now.Year, $now.Month, 1).ToString('yyyy-MM-ddT00:00:00Z') }
    notifications = @{
      actual50    = & $notify 50 'Actual'
      actual80    = & $notify 80 'Actual'
      actual100   = & $notify 100 'Actual'
      forecast100 = & $notify 100 'Forecasted'
    }
  }
}
$path = "/subscriptions/$($ctx.Subscription.Id)/providers/Microsoft.Consumption/budgets/$($Name)?api-version=2023-11-01"
if ($PSCmdlet.ShouldProcess("budget $Name", "Set to $Amount a month, alerts at 50/80/100% actual and 100% forecast")) {
  Write-Host "Writing budget $Name ..." -ForegroundColor DarkGray
  $r = Invoke-AvdSpendArm -Method PUT -Path $path -Body $body
  Write-Host "Budget $($r.name): $($r.properties.amount) a month, alerts to $(@($Email).Count) address(es)." -ForegroundColor Green
}
