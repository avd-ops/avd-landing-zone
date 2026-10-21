#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  After teardown: prove the run's resources are gone and close its record (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Compares the subscription's inventory now with the
  baseline taken when the run started. Anything new is a leftover: the record stays 'leftovers'
  and the script exits 1. Run it again after cleaning up. Resource groups kept on purpose (for
  the next run) are named with -Keep; they're recorded as kept and their cost becomes standing.

.EXAMPLE
  ./scripts/ops/Stop-AvdSpendRun.ps1 -Sandbox lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string] $Sandbox,
  # Default: the sandbox's open run.
  [string] $RunId,
  # Resource groups (regex) left in place on purpose.
  [string] $Keep,
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$subId = $ctx.Subscription.Id
$store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local
$runs = @(Get-AvdSpendRun -RecordsPath $RecordsPath -Sandbox $Sandbox)
$run = if ($RunId) { $runs | Where-Object { $_.runId -eq $RunId } | Select-Object -First 1 } else { $runs | Where-Object { $_.status -in 'open', 'leftovers' } | Select-Object -Last 1 }
if (-not $run) { throw "No $(if ($RunId) { "run $RunId" } else { 'open run' }) for sandbox $Sandbox in $RecordsPath." }

Write-Host "Reading the inventory of the subscription from Resource Graph for run $($run.runId) ..." -ForegroundColor DarkGray
$inventory = @(Get-AvdSpendInventory -SubscriptionId $subId)
$found = @(Get-AvdSpendLeftover -Baseline $run.baseline -Inventory $inventory)
$kept = @($found | Where-Object { $Keep -and $_.resourceGroup -match $Keep })
$leftovers = @($found | Where-Object { -not ($Keep -and $_.resourceGroup -match $Keep) })
$now = (Get-Date).ToUniversalTime()
# Every check is kept, so the record shows when leftovers were found and when they were gone.
$checks = @(if ($run.teardown -and $run.teardown.checks) { $run.teardown.checks })
$checks += [ordered]@{ at = $now.ToString('o'); leftovers = $leftovers.Count }

$run.teardown = [ordered]@{
  checkedAt         = $now.ToString('o')
  method            = 'Resource Graph inventory compared with the run baseline (resource ID hashes and resource group names)'
  resourcesNow      = @($inventory | Where-Object { $_.type -ne 'microsoft.resources/subscriptions/resourcegroups' }).Count
  resourcesBaseline = $run.baseline.resourceCount
  leftovers         = $leftovers
  kept              = $kept
  keptPattern       = $Keep
  result            = $(if ($leftovers.Count) { 'leftovers' } else { 'clean' })
  checks            = $checks
}
$run.status = if ($leftovers.Count) { 'leftovers' } else { 'closed' }
if (-not $leftovers.Count) { $run.closedAt = $now.ToString('o') }
$hoursUp = [math]::Round(($now - ([datetime]$run.startedAt).ToUniversalTime()).TotalHours, 1)
$path = Save-AvdSpendRun -RecordsPath $RecordsPath -Run $run
Save-AvdRunRecordStore -Store $store

$md = @("## Teardown evidence: $Sandbox / $($run.runId)", '', "**$($run.purpose)**: open $hoursUp h (planned $($run.plannedHours) h).", '',
  "- Baseline at start: $($run.baseline.resourceCount) resources in $(@($run.baseline.resourceGroups | Where-Object { $_ }).Count) resource groups",
  "- Now: $($run.teardown.resourcesNow) resources")
if ($kept.Count) { $md += "- Kept on purpose ($Keep): $($kept.Count) item(s); their cost from now on is standing cost" }
if ($leftovers.Count) {
  $md += '', "**Leftovers: $($leftovers.Count).** These didn't exist when the run started:", '', '| Type | Resource group | Name |', '|---|---|---|'
  $md += @($leftovers | Select-Object -First 50 | ForEach-Object { "| $($_.type) | $($_.resourceGroup) | $($_.name) |" })
  $md += '', 'Delete them (for a landing zone: `Remove-AvdDemo.ps1 -IncludeLandingZone`), or run again with -Keep for groups you mean to keep, then run this again.'
  if ($run.estimate.costPerDayIfLeftUp) { $md += "Left up, this costs about $(Format-AvdSpendMoney $run.estimate.costPerDayIfLeftUp $run.estimate.currency) a day." }
}
else { $md += '', '**Clean.** Nothing from this run is left in the subscription. Cost Management settles in about 3 days; until then the actual cost is provisional.' }
$md += '', "Record: ``$path``"
# Never delete the last copy (avd-second-brain decision 0016): Cloud Shell's disk doesn't count.
if ($store.local) { $md += '', "**Only copy.** This record is only on this disk ($RecordsPath). Copy it somewhere durable, or set up the run store (Initialize-AvdRunStore.ps1) and run without -Local." }
Write-AvdSpendSummary $md
if ($leftovers.Count) { exit 1 }
