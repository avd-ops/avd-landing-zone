#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Sets up the run store once per subscription: durable storage for recorded runs
  (build/specs/run-recorder-spec.md sections 6.3, 9.2 and 9.3).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Deploys bicep/recorder/main.bicep: the resource group
  avdlz-runs-rg, one StorageV2 LRS account with shared keys off and Entra sign-in only, the 'runs'
  container, a lifecycle rule that moves old runs to cooler tiers and never deletes, and the
  Activity Log export to the store. You get Storage Blob Data Contributor on that account only.

  The run store is outside every landing zone, so cleanup never removes it. Running this again
  updates it in place.

  Before deploying it checks:
    - Defender for Storage: if the plan is on, it bills each storage account per month, so this
      refuses without -AcceptDefenderCharge.
    - The private companion repo (-PrivateRepo, or AVD_PRIVATE_REPO): owner/repo, and private.
      Checked with the GitHub CLI when it is signed in (gh auth login, device code).

  Supports -WhatIf: the checks run, nothing is deployed.

.EXAMPLE
  ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus -PrivateRepo <owner>/<repo>

.EXAMPLE
  ./scripts/ops/Initialize-AvdRunStore.ps1 -Location northcentralus -TeardownLogs Ask -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $Location = $env:AVD_LOCATION,
  [ValidateSet('Keep', 'Ask', 'Delete')][string] $TeardownLogs = 'Keep',
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  [switch] $AcceptDefenderCharge,
  [switch] $NoActivityLogExport,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$subId = $ctx.Subscription.Id
$name = Get-AvdRunStoreName -SubscriptionId $subId
Write-Host "Run store - '$($ctx.Subscription.Name)'" -ForegroundColor White
Write-AvdSection 'Checks'

if (-not $Location) {
  Add-AvdCheckResult 'Run store' 'Region' 'Fail' -Id 'runstore-location' -Remediation 'Pass -Location (the region your landing zone uses), or set AVD_LOCATION.'
}

# Defender for Storage bills per storage account per month, which could cost more than the store itself.
Write-Host '  Reading the Defender for Storage plan...' -ForegroundColor DarkGray
$pricing = Invoke-AvdArm -Path "/subscriptions/$subId/providers/Microsoft.Security/pricings/StorageAccounts?api-version=2024-01-01" -AllowNotFound
$defenderOn = $pricing -and $pricing.properties.pricingTier -eq 'Standard'
if (-not $defenderOn) {
  Add-AvdCheckResult 'Run store' 'Defender for Storage plan is off (no per-account charge)' 'Pass' -Id 'runstore-defender'
}
elseif ($AcceptDefenderCharge) {
  Add-AvdCheckResult 'Run store' 'Defender for Storage plan is on: the run store adds one account to it' 'Warn' -Id 'runstore-defender' `
    -Detail 'Accepted with -AcceptDefenderCharge. The cost estimate lists it as its own line.' -Data @{ defender = 'on'; accepted = $true }
}
else {
  Add-AvdCheckResult 'Run store' 'Defender for Storage plan is on' 'Fail' -Id 'runstore-defender' `
    -Detail 'The plan bills each storage account per month, so the run store would add a monthly charge.' `
    -Remediation 'Check the per-account price for your region, then run this again with -AcceptDefenderCharge, or record runs locally only (AVDLZ_RECORD=on).' -Data @{ defender = 'on'; accepted = $false }
}

# The private companion repo (spec section 9.3): owner/repo, and private, checked before anything is copied there.
if (-not $PrivateRepo) {
  Add-AvdCheckResult 'Run store' 'Private companion repo' 'Skip' -Id 'runstore-repo' -Detail 'None set: copies to GitHub are off until you set AVD_PRIVATE_REPO.'
}
elseif (-not (Test-AvdPrivateRepoName $PrivateRepo)) {
  Add-AvdCheckResult 'Run store' 'Private companion repo' 'Fail' -Id 'runstore-repo' -Detail "'$PrivateRepo' is not owner/repo." -Remediation 'Set AVD_PRIVATE_REPO to owner/repo.'
}
elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Add-AvdCheckResult 'Run store' 'Private companion repo' 'Warn' -Id 'runstore-repo' -Detail 'The GitHub CLI is not installed, so the repo was not checked.' `
    -Remediation 'Copies check the repo again before every write.'
}
else {
  Write-Host "  Checking $PrivateRepo with the GitHub CLI..." -ForegroundColor DarkGray
  $out = gh api "repos/$PrivateRepo" --jq '.private' 2>&1
  if ($LASTEXITCODE) {
    Add-AvdCheckResult 'Run store' 'Private companion repo' 'Fail' -Id 'runstore-repo' -Detail "gh api repos/$PrivateRepo failed: $out" `
      -Remediation 'Sign in with gh auth login (device code), and check the repo exists and you can see it.'
  }
  elseif ("$out".Trim() -ne 'true') {
    Add-AvdCheckResult 'Run store' 'Private companion repo is private' 'Fail' -Id 'runstore-repo-public' -Detail "$PrivateRepo is public." `
      -Remediation 'Run records hold tenant names and IDs: use a private repository.'
  }
  else {
    Add-AvdCheckResult 'Run store' "Private companion repo $PrivateRepo is private" 'Pass' -Id 'runstore-repo'
  }
}

# Assign before piping: Get-AvdCheckResult emits one array (lesson 0009).
$all = Get-AvdCheckResult
$failed = @($all | Where-Object Status -eq 'Fail').Count
if (-not $failed) {
  Write-AvdSection 'Run store'
  $me = Get-AzADUser -SignedIn -ErrorAction Stop
  $params = @{
    location            = $Location
    storageAccountName  = $name
    operatorPrincipalId = $me.Id
    teardownLogs        = $TeardownLogs
    privateRepo         = $(if ($PrivateRepo) { $PrivateRepo } else { '' })
    exportActivityLog   = -not $NoActivityLogExport
  }
  if ($PSCmdlet.ShouldProcess("avdlz-runs-rg / $name in $Location", 'Deploy the run store')) {
    Write-Host '  Deploying the run store (about a minute)...' -ForegroundColor DarkGray
    # Not avdlz-<...>-<date>-<time>: that shape is a landing zone deployment to Get-AvdRunStatus.ps1.
    $dep = New-AzSubscriptionDeployment -Name "avdlzruns-store-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))" -Location $Location `
      -TemplateFile (Join-Path $PSScriptRoot '../../bicep/recorder/main.bicep') -TemplateParameterObject $params -ErrorAction Stop
    if ($dep.ProvisioningState -ne 'Succeeded') {
      Add-AvdCheckResult 'Run store' 'Run store deployed' 'Fail' -Id 'runstore-deploy' -Detail "Deployment state: $($dep.ProvisioningState)."
    }
    else {
      Add-AvdCheckResult 'Run store' "Run store avdlz-runs-rg / $name" 'Fixed' -Id 'runstore-deploy' `
        -Detail "Teardown keeps run logs: $TeardownLogs. Activity Log export: $(if ($NoActivityLogExport) { 'off' } else { 'on' })." `
        -Data @{ storageAccountName = $name; teardownLogs = $TeardownLogs }
    }
  }
  else {
    Add-AvdCheckResult 'Run store' "Would deploy avdlz-runs-rg / $name" 'Skip' -Id 'runstore-deploy'
  }
}

$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
