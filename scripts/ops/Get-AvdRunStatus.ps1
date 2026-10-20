#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Where did I leave off? Reads where a landing zone run stands from Azure and tells the deployment
  portal the next step (build/specs/run-recorder-spec.md section 4).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), for example after Cloud Shell reset or on another device.
  Read-only. It reads the subscription's deployment records (deploy.sh names them
  avdlz-<parameter file>-<date>-<time>), the landing zone's resource groups and the demo's deployment
  record, and ends with the portal state line (stage resume).

  A deployment that is still running wins over everything: the next step is to wait, never to deploy
  again. Anything it can't classify is reported as unknown with what it saw.

  Without -NamePrefix it uses the only landing zone in the subscription; with none, the next step is the
  pre-deployment preflight; with several, it lists them and asks for -NamePrefix.

.EXAMPLE
  ./scripts/ops/Get-AvdRunStatus.ps1

.EXAMPLE
  ./scripts/ops/Get-AvdRunStatus.ps1 -NamePrefix avdlz -Environment dev
#>
[CmdletBinding()]
param(
  [ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
Write-Host "Where did I leave off - '$($ctx.Subscription.Name)'" -ForegroundColor White

if (-not $NamePrefix) {
  $found = @(Find-AvdLandingZone)
  if ($found.Count -eq 1) { $NamePrefix = $found[0].NamePrefix; $Environment = $found[0].Environment }
  elseif ($found.Count -gt 1) {
    $list = ($found | ForEach-Object { "$($_.NamePrefix)-$($_.Environment)" }) -join ', '
    Add-AvdCheckResult 'Run' 'One landing zone in the subscription' 'Fail' -Id 'several-landing-zones' -Detail "Found $list." `
      -Remediation 'Run this again with -NamePrefix and -Environment.' -Data @{ landingZones = @($found | ForEach-Object { "$($_.NamePrefix)-$($_.Environment)" }) }
    $state = Get-AvdPortalState -Stage resume -Status unknown -Context ([ordered]@{ basis = "Several landing zones: $list." })
    Write-AvdPortalState $state
    exit 1
  }
}

Write-Host '  Reading the deployment records and resource groups...' -ForegroundColor DarkGray
$deployments = @(Get-AvdArmList -Path "/subscriptions/$($ctx.Subscription.Id)/providers/Microsoft.Resources/deployments?api-version=2021-04-01")
if ($NamePrefix) {
  $lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
  $rgExists = $lz.RgExists
  $demo = $deployments | Where-Object { $_.name -eq "avdlz-demo-$($lz.BaseName)" } | Select-Object -First 1
}
else {
  $rgExists = @{ Network = $false; Management = $false; Storage = $false; ControlPlane = $false; Hosts = $false; Demo = $false }
  $demo = $null
}

$pos = Get-AvdRunPosition -Environment $Environment -Deployment $deployments -RgExists $rgExists -DemoDeployment $demo
Write-AvdSection 'Run'
$headline = if ($pos.Status -eq 'unknown') { "Couldn't tell where the run stands" } else { "Next: $($pos.NextStage)" }
Add-AvdCheckResult 'Run' $headline $(if ($pos.Status -eq 'unknown') { 'Warn' } else { 'Pass' }) -Id "resume-$($pos.Status)" -Detail $pos.Basis

$context = [ordered]@{ namePrefix = $NamePrefix; environment = $Environment; lastStage = $pos.LastStage; lastStatus = $pos.LastStatus; nextStage = $pos.NextStage; deploymentName = $pos.DeploymentName; basis = $pos.Basis }
$state = Get-AvdPortalState -Stage resume -Status $pos.Status -Context $context
$null = Write-AvdSummary
Write-AvdPortalState $state
exit $(if ($pos.Status -eq 'unknown') { 1 } else { 0 })
