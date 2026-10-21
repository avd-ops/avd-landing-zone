#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Before a sandbox run: estimate its cost, check it against your caps, snapshot what exists, and
  open a run record (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). The estimate comes from one of:
    -PreflightOutput  a file holding the pre-deployment preflight's output (its AVDLZ-STATE line),
                      or that line passed as the value
    -Region/-VmSize   priced here with the preflight's own estimator (Get-AvdCostEstimate)
    -ManualAmount     for runs the preflight doesn't price (image builds, experiments)
  The run is refused (exit 1, no record) when the estimate is over -RunCap or what's left of
  -MonthlyCap this month, when a line couldn't be priced, when no cap is set, or when the
  sandbox still has an open run. -EstimateOnly prints the estimate without signing in.

  Records go to the run store's records container (Initialize-AvdRunStore.ps1), which survives
  an ephemeral Cloud Shell, with a local cache in -RecordsPath. -Local keeps them on this disk only.

.EXAMPLE
  ./scripts/ops/Start-AvdSpendRun.ps1 -Sandbox lab -Purpose 'FSLogix retest' -Hours 6 -PreflightOutput ~/preflight.txt -MonthlyCap 150 -RunCap 25

.EXAMPLE
  ./scripts/ops/Start-AvdSpendRun.ps1 -Sandbox lab -Purpose 'sizing check' -Hours 2 -Region northcentralus -VmSize Standard_D2as_v5 -EstimateOnly
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string] $Sandbox,
  [ValidateSet('avd', 'image', 'other')][string] $Kind = 'avd',
  [Parameter(Mandatory)][string] $Purpose,
  # Hours from deploy to finished teardown. Hosts are priced as running all of it.
  [Parameter(Mandatory)][ValidateRange(0.5, 744)][double] $Hours,

  [string] $PreflightOutput,
  [string] $Region,
  [string] $VmSize = 'Standard_E4as_v5',
  [int] $Hosts = 1,
  [int] $ProfileQuotaGiB = 100,
  [string] $ProfileStorageSku = 'Premium_LRS',
  [double] $ManualAmount,
  [string] $ManualNote,

  [double] $UsageAllowancePercent = 20,
  [double] $MonthlyCap = $(if ($env:SPEND_MONTHLY_CAP) { [double]$env:SPEND_MONTHLY_CAP } else { 0 }),
  [double] $RunCap = $(if ($env:SPEND_RUN_CAP) { [double]$env:SPEND_RUN_CAP } else { 0 }),
  # A label for who pays, such as personal or team. Never a card or account number.
  [string] $Funding = $env:SPEND_FUNDING,
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local,
  # Resource groups the run reuses (regex), counted as the run's even though they existed before.
  [string] $ResourceGroupPattern,
  [switch] $AllowUnpriced,
  [switch] $EstimateOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }

# ---- Estimate ----
if ($PSBoundParameters.ContainsKey('ManualAmount')) {
  if (-not $ManualNote) { throw '-ManualNote is required with -ManualAmount: say what the amount covers and how it was worked out.' }
  $estimate = Get-AvdSpendManualEstimate -Amount $ManualAmount -Note $ManualNote -RunHours $Hours
}
elseif ($PreflightOutput) {
  $text = if (Test-Path -LiteralPath $PreflightOutput -PathType Leaf) { Get-Content -LiteralPath $PreflightOutput -Raw } else { $PreflightOutput }
  $monthly = Get-AvdSpendPreflightEstimate -Text $text
  $hostCount = @($monthly.lines | Where-Object { $_ -and $_.key -eq 'compute' } | ForEach-Object { if ($_.item -match '\((\d+) x ') { [int]$Matches[1] } }) | Select-Object -First 1
  $estimate = Get-AvdSpendRunEstimate -Monthly $monthly -RunHours $Hours -Hosts $(if ($hostCount) { $hostCount } else { $Hosts }) -UsageAllowancePercent $UsageAllowancePercent
}
elseif ($Region) {
  $plan = @{
    location = $Region; sessionHostCount = $Hosts; sessionHostVmSize = $VmSize; profileShareQuotaGiB = $ProfileQuotaGiB
    profileStorageSku = $ProfileStorageSku; enableAvdPrivateLink = $true; connectivityMode = 'Standalone'
  }
  Write-Host "Pricing $Hosts x $VmSize in $Region from the Azure retail price API ..." -ForegroundColor DarkGray
  $monthly = Get-AvdCostEstimate -Plan $plan
  $estimate = Get-AvdSpendRunEstimate -Monthly $monthly -RunHours $Hours -Hosts $Hosts -UsageAllowancePercent $UsageAllowancePercent
}
else { throw 'Give an estimate source: -PreflightOutput, -Region, or -ManualAmount with -ManualNote.' }

$cur = $estimate.currency
$md = @("## Spend estimate: $Sandbox / $Kind", '', "**$Purpose**, $Hours h", '', '| Item | Basis | Cost |', '|---|---|---:|')
foreach ($l in $estimate.lines) { $md += "| $($l.item) | $($l.basis) | $(Format-AvdSpendMoney $l.cost $cur) |" }
if ($estimate.usageAllowance) { $md += "| Usage-based allowance ($($estimate.usageAllowancePercent)%) | $(@($estimate.excluded) -join '; ') | $(Format-AvdSpendMoney $estimate.usageAllowance $cur) |" }
$md += "| **Total** | | **$(Format-AvdSpendMoney $estimate.total $cur)** |"
if ($estimate.costPerDayIfLeftUp) { $md += '', "If it isn't torn down, it keeps costing about **$(Format-AvdSpendMoney $estimate.costPerDayIfLeftUp $cur) a day**." }
$unpriced = @($estimate.unpriced | Where-Object { $_ })
if ($unpriced.Count) { $md += '', "Not priced: $($unpriced -join '; ')" }

if ($EstimateOnly) { Write-AvdSpendSummary $md; return }

# ---- Records and gate ----
$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$subId = $ctx.Subscription.Id
$store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local
$runs = @(Get-AvdSpendRun -RecordsPath $RecordsPath -Sandbox $Sandbox)
$open = @($runs | Where-Object { $_.status -in 'open', 'leftovers' })
if ($open.Count) {
  Write-AvdSpendSummary ($md + '', "**Refused:** run $($open[0].runId) is still $($open[0].status). Close it first (Stop-AvdSpendRun.ps1), so each run's cost and teardown stay separate.")
  exit 1
}
$now = (Get-Date).ToUniversalTime()
Write-Host 'Reading month-to-date cost from Cost Management ...' -ForegroundColor DarkGray
$mtd = Get-AvdSpendMonthToDate -SubscriptionId $subId -Now $now
$calibration = Get-AvdSpendCalibration -Runs $runs -Kind $Kind
$gate = Get-AvdSpendGateDecision -Estimate $estimate -MonthlyCap $MonthlyCap -RunCap $RunCap -MonthToDate $mtd -Calibration $calibration -AllowUnpriced:$AllowUnpriced

$md += '', '### Gate', '', "- Month to date: $(Format-AvdSpendMoney $gate.monthToDate $cur); monthly cap $(Format-AvdSpendMoney $gate.monthlyCap $cur); left $(Format-AvdSpendMoney $gate.remaining $cur)", "- Per-run cap: $(Format-AvdSpendMoney $gate.runCap $cur)"
if ($calibration) { $md += "- Past $($calibration.runs) settled $Kind run(s) cost $($calibration.medianActualToEstimate)x their estimate (median); checked $(Format-AvdSpendMoney $gate.checkedCost $cur)" }
if ($gate.decision -ne 'allowed') {
  $md += '', '**Refused.**', ''
  $md += @($gate.reasons | ForEach-Object { "- $_" })
  Write-AvdSpendSummary $md
  exit 1
}

# ---- Baseline and record ----
Write-Host 'Snapshotting the subscription inventory from Resource Graph ...' -ForegroundColor DarkGray
$baseline = Get-AvdSpendBaseline -Inventory @(Get-AvdSpendInventory -SubscriptionId $subId) -Now $now
$runId = Get-AvdSpendRunId -Now $now -Kind $Kind -Existing @($runs | ForEach-Object { $_.runId })
$run = [ordered]@{
  schema               = 'spend-run/v1'
  runId                = $runId
  sandbox              = $Sandbox
  funding              = $Funding
  kind                 = $Kind
  purpose              = $Purpose
  status               = 'open'
  startedAt            = $now.ToString('o')
  plannedHours         = $Hours
  dueBy                = $now.AddHours($Hours).ToString('o')
  startedBy            = $(if ($env:GITHUB_ACTOR) { 'github-actions' } else { 'cloud-shell' })
  resourceGroupPattern = $ResourceGroupPattern
  estimate             = $estimate
  gate                 = $gate
  calibration          = $calibration
  baseline             = $baseline
  closedAt             = $null
  teardown             = $null
  actual               = $null
}
$path = Save-AvdSpendRun -RecordsPath $RecordsPath -Run $run
Save-AvdRunRecordStore -Store $store
$md += '', "**Allowed.** Run **$runId** is open, due down by $($now.AddHours($Hours).ToString('yyyy-MM-dd HH:mm')) UTC. Baseline: $($baseline.resourceCount) resources in $(@($baseline.resourceGroups).Count) resource groups.", '', "Record: ``$path``$(if (-not $store.local) { ' (and the run store)' })", '', "After teardown, close it: ``./scripts/ops/Stop-AvdSpendRun.ps1 -Sandbox $Sandbox``"
Write-AvdSpendSummary $md
if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "run_id=$runId" }
