#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Signs in to Microsoft Graph once for the whole Cloud Shell session, so the preflight,
  -Fix, the demo and the cleanup don't each ask for a device code.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), before the other scripts. It signs in with the
  one scope set every script uses (decision 0016) and checks the sign-in with a real
  request. The scripts that run after it in the same session reuse the sign-in.

  With the AVD Landing Zone Operator app (scripts/ops/Initialize-AvdGraphApp.ps1), pass
  its client ID or set $env:AVD_GRAPH_CLIENT_ID: no consent prompts, and the sign-ins are
  logged under that app. Without it, Microsoft's default Graph app is used, which needs
  consent for the scopes (an administrator's, for the ReadWrite ones).

.EXAMPLE
  ./scripts/ops/Connect-AvdLandingZone.ps1

.EXAMPLE
  ./scripts/ops/Connect-AvdLandingZone.ps1 -ClientId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
  # The operator app's client ID; defaults to $env:AVD_GRAPH_CLIENT_ID. Kept in $env for the scripts run after this one.
  [string] $ClientId,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$null = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
if ($ClientId) { $env:AVD_GRAPH_CLIENT_ID = Get-AvdGraphClientId -ClientId $ClientId }

Write-AvdSection 'Microsoft Graph'
try { Connect-AvdGraph -Purpose SignIn }
catch {
  Add-AvdCheckResult 'Microsoft Graph' 'Signed in to Microsoft Graph' 'Fail' -Detail $_.Exception.Message -Remediation 'Run this again; the device code lasts 120 seconds. Open https://microsoft.com/devicelogin first.'
  $null = Write-AvdSummary
  exit 1
}

# A sign-in is only trusted after a real request (lesson 0007).
$ctx = Get-MgContext
$app = if ($ctx.ClientId -and $ctx.ClientId -eq $env:AVD_GRAPH_CLIENT_ID) { "the AVD Landing Zone Operator app ($($ctx.ClientId))" }
elseif ($ctx.ClientId -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { "Microsoft's default app (Microsoft Graph Command Line Tools); set AVD_GRAPH_CLIENT_ID to use the operator app" }
else { "app $($ctx.ClientId)" }
try {
  $me = Invoke-AvdGraph -Uri 'v1.0/me?$select=id,userPrincipalName'
  Add-AvdCheckResult 'Microsoft Graph' "Signed in as $($me.userPrincipalName)" 'Pass' -Detail "Through $app. The scripts run after this in this session reuse the sign-in."
}
catch {
  Add-AvdCheckResult 'Microsoft Graph' 'Signed in to Microsoft Graph' 'Fail' -Detail "GET v1.0/me failed: $($_.Exception.Message)" -Remediation 'Sign in as a user (not a service principal): Disconnect-MgGraph, then run this again.'
}
# The token can come back with fewer scopes than asked for when consent is incomplete.
$missing = @(Get-AvdGraphScope -Purpose SignIn | Where-Object { $_ -notin $ctx.Scopes })
if ($missing.Count) {
  Add-AvdCheckResult 'Microsoft Graph' 'The sign-in has every scope the scripts use' 'Warn' -Detail "Missing: $($missing -join ', ')" -Remediation 'Run scripts/ops/Initialize-AvdGraphApp.ps1 again as an administrator to grant consent, then Disconnect-MgGraph and sign in again.'
}
else { Add-AvdCheckResult 'Microsoft Graph' 'The sign-in has every scope the scripts use' 'Pass' }
Test-AvdSignInMatch

$summary = Write-AvdSummary
if ($summary.Failed) { exit 1 }
exit 0
