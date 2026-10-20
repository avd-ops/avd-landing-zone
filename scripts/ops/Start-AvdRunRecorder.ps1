#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Opens a recorded run: its run ID, run.json and the expected cost (cost.json), checked against the
  cap before anything is deployed (build/specs/run-recorder-spec.md sections 6, 9.3a and 13a).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), before the pre-deployment preflight. Read-only in Azure
  except for the run folder it writes in the run store (Initialize-AvdRunStore.ps1 sets that up once).

  1. Prices the run from the parameter file at retail list prices (Get-AvdCostEstimate): the session
     hosts (and the demo's) for -Hours, everything else prorated from the month. A line with no single
     matching meter stays unpriced, never guessed.
  2. The gate: the expected total must be at most half of -Cap, with every line priced. If not, the
     run should not start; the cost record says which line is missing or high.
  3. Writes run.json and cost.json (avd-second-brain contract C17) to the run folder: the run store's
     runs/<runId>/ and the local copy in ~/clouddrive/avdlz-runs/<runId>/.
  4. Prints the two lines that turn the journal on for the rest of the run.

  With -Local, nothing is written to Azure: the folder is local only.

.EXAMPLE
  ./scripts/ops/Start-AvdRunRecorder.ps1 -ParameterFile parameters/dev.bicepparam -Hours 3 -Cap 10

.EXAMPLE
  ./scripts/ops/Start-AvdRunRecorder.ps1 -Local
#>
[CmdletBinding()]
param(
  [string] $ParameterFile = 'parameters/dev.bicepparam',
  [ValidateRange(0.5, 24)][double] $Hours = 3,
  [ValidateRange(1, 1000)][double] $Cap = 10,
  # Session hosts the demo adds on top of the landing zone's own.
  [ValidateRange(0, 10)][int] $DemoHostCount = 1,
  [string] $Location = $env:AVD_LOCATION,
  [string] $RunId = $env:AVDLZ_RUN_ID,
  [switch] $Local,
  # Where the local copy of the run folder goes (default: your home, clouddrive when it is mounted).
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
if (-not $RunId) { $RunId = Get-AvdRunId }
Write-Host "Run recorder - $RunId in '$($ctx.Subscription.Name)'" -ForegroundColor White

$storeName = Get-AvdRunStoreName -SubscriptionId $ctx.Subscription.Id
if (-not $Local) {
  $store = Invoke-AvdArm -Path "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/$($storeName)?api-version=2023-05-01" -AllowNotFound
  if (-not $store) {
    Add-AvdCheckResult 'Run' 'Run store' 'Fail' -Id 'runstore-missing' -Detail "No run store ($storeName in avdlz-runs-rg) in this subscription." `
      -Remediation 'Run ./scripts/ops/Initialize-AvdRunStore.ps1 once, or record locally with -Local.'
    $null = Write-AvdSummary
    exit 1
  }
}

Write-AvdSection 'Expected cost'
Write-Host '  Reading the parameter file and retail prices...' -ForegroundColor DarkGray
$plan = Get-AvdDeploymentPlan -ParameterFile $ParameterFile -Location $Location
$hostCount = [int]$plan.sessionHostCount + $DemoHostCount
$estimate = Get-AvdCostEstimate -Plan $plan
$cost = Get-AvdRunCostExpected -Estimate $estimate -Hours $Hours -HostCount $hostCount -RunId $RunId -Cap $Cap
foreach ($l in $cost.expected.lines) {
  $line = if ($null -ne $l.cost) { '{0,-55} {1,8:N2} {2}' -f $l.item, $l.cost, $cost.currency } else { '{0,-55} {1,8} ({2})' -f $l.item, 'unpriced', $l.match }
  Write-Host "  $line"
}
Write-Host ('  {0,-55} {1,8:N2} {2} for {3} h, {4} session host(s)' -f 'Expected total', $cost.expected.total, $cost.currency, $Hours, $hostCount) -ForegroundColor White
$excluded = @($estimate.excluded) -join '; '
if ($cost.gate.passed) {
  Add-AvdCheckResult 'Run' "Expected cost $($cost.expected.total) $($cost.currency) is within $($cost.gate.limit) (half the $Cap cap)" 'Pass' -Id 'run-cost-gate' `
    -Detail "Not included: $excluded." -Data @{ expected = $cost.expected.total; limit = $cost.gate.limit; cap = $Cap }
}
else {
  $why = if ($cost.expected.unpriced) { "$($cost.expected.unpriced) line(s) could not be priced, so the total is incomplete" } else { "the expected $($cost.expected.total) $($cost.currency) is over $($cost.gate.limit)" }
  Add-AvdCheckResult 'Run' 'Expected cost is within half the cap, every line priced' 'Fail' -Id 'run-cost-gate' -Detail "$why." `
    -Remediation 'Do not start the run. Lower -Hours or the sizing, or fix the unpriced line, and run this again.' `
    -Data @{ expected = $cost.expected.total; limit = $cost.gate.limit; cap = $Cap; unpriced = $cost.expected.unpriced }
}

Write-AvdSection 'Run folder'
$commit = $null
if (Get-Command git -ErrorAction SilentlyContinue) { $commit = git -C $PSScriptRoot rev-parse --short HEAD 2>$null; if ($LASTEXITCODE) { $commit = $null } }
if (-not $commit) { $commit = '0000000' }
$record = Get-AvdRunRecord -RunId $RunId -Commit $commit -Entry 'Start-AvdRunRecorder.ps1' -Region $plan.location `
  -Extension @{ parameterFile = $ParameterFile; sessionHostCount = $hostCount; sessionHostVmSize = $plan.sessionHostVmSize }
$folder = (Get-AvdJournalSetting -Record on -RunId $RunId -HomePath $LocalRoot -CloudDriveExists (Test-Path (Join-Path $LocalRoot 'clouddrive'))).Folder
$null = New-Item -ItemType Directory -Path $folder -Force
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'run.json') -Encoding utf8
$cost | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'cost.json') -Encoding utf8
if ($Local) {
  Add-AvdCheckResult 'Run' "Run folder $folder" 'Pass' -Id 'run-folder' -Detail 'Local only (-Local).'
}
else {
  Write-Host "  Writing run.json and cost.json to $storeName/runs/$RunId/..." -ForegroundColor DarkGray
  $sc = New-AzStorageContext -StorageAccountName $storeName -UseConnectedAccount
  foreach ($f in 'run.json', 'cost.json') {
    $null = Set-AzStorageBlobContent -File (Join-Path $folder $f) -Container 'runs' -Blob "$RunId/$f" -Context $sc -Force -ErrorAction Stop
  }
  Add-AvdCheckResult 'Run' "Run folder runs/$RunId in $storeName" 'Pass' -Id 'run-folder' -Detail "Local copy: $folder."
}

$mode = if ($Local) { 'on' } else { 'azure' }
Write-Host ''
Write-Host 'Turn the journal on for this run (paste into this Cloud Shell session, and again after a reconnect):' -ForegroundColor White
Write-Host "  `$env:AVDLZ_RECORD = '$mode'"
Write-Host "  `$env:AVDLZ_RUN_ID = '$RunId'"

$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
