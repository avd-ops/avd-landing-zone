#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Confirms from Azure telemetry that a user's sign-in reached the landing zone's desktop: the
  deployment portal's Verify access step (decision 0014, build/specs/verify-access-spec.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) after opening the desktop. It reads WVDConnections,
  WVDErrors and WVDCheckpoints in the landing zone's Log Analytics workspace (the host pool,
  application group and workspace already send them there) for one user in a recent window, using
  scripts/ops/kql/user-connection.kql.

  Log Analytics has connection data a few minutes after it happens (resource logs usually take
  3 to 10 minutes), so the script checks again every -PollSeconds until -TimeoutMinutes.

  It fails closed. The result is one of:
    verified     a connection by the user reached Connected
    failed       none did, and AVD logged errors (shown with their code and message)
    notverified  nothing for the user yet, a connection that hasn't reached Connected, or the
                 query failed. Never a pass.

  It reports connection setup time (Started to Connected). That is not AVD Insights' "time to
  connect" and not the time to a usable desktop. A first connection to a stopped host includes the
  host starting, so it isn't steady state.

  Exit code 0 = verified; 1 = failed or not verified.

.EXAMPLE
  ./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev -UserPrincipalName alex@contoso.com -TimeoutMinutes 30

.EXAMPLE
  ./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev -Demo
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  # Whose connection to look for. Default: you (the signed-in Azure user).
  [ValidatePattern('^[^\s''"\\@]+@[^\s''"\\@]+\.[^\s''"\\@]+$')][string] $UserPrincipalName,
  # How far back to look for the connection.
  [ValidateRange(5, 1440)][int] $SinceMinutes = 60,
  # How long to wait for data to arrive; 0 checks once.
  [ValidateRange(0, 60)][int] $TimeoutMinutes = 15,
  [ValidateRange(10, 600)][int] $PollSeconds = 60,
  # Check the demo host pool's desktop (Deploy-AvdDemo.ps1) instead of the landing zone's.
  [switch] $Demo,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
# The Azure user, not a Graph sign-in (lesson 0007).
if (-not $UserPrincipalName) { $UserPrincipalName = (Get-AzADUser -SignedIn -ErrorAction Stop).UserPrincipalName }
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$rgKey = if ($Demo) { 'Demo' } else { 'ControlPlane' }
$rgId = $lz.ResourceGroupIds[$rgKey]
Write-Host "AVD access check - $UserPrincipalName on $($lz.BaseName)$(if ($Demo) { ' (demo)' }) in '$($ctx.Subscription.Name)'" -ForegroundColor White

$context = [ordered]@{ namePrefix = $NamePrefix; environment = $Environment; user = $UserPrincipalName; windowMinutes = $SinceMinutes; resourceGroup = $lz.ResourceGroups[$rgKey]; demo = [bool]$Demo; waitedSeconds = 0 }
$outcome = $null
Write-AvdSection 'Connection'
if (-not $lz.RgExists[$rgKey] -or -not $lz.LogAnalyticsId) {
  $what = if (-not $lz.RgExists[$rgKey]) { "resource group $($lz.ResourceGroups[$rgKey])" } else { "Log Analytics workspace in $($lz.ResourceGroups.Management)" }
  Add-AvdCheckResult 'Connection' "Landing zone $($lz.BaseName) has its $what" 'Fail' -Id 'no-landing-zone' `
    -Remediation "Check -NamePrefix and -Environment (and -Demo), or run the post-deployment setup first."
}
else {
  try {
    $customerId = (Invoke-AvdArm -Path "$($lz.LogAnalyticsId)?api-version=2023-09-01").properties.customerId
    if (-not $customerId) { throw "The workspace $($lz.LogAnalyticsId) has no customerId." }
    # Values are validated above; quote them for KQL anyway.
    $q = { param($v) "$v".Replace('\', '\\').Replace("'", "\'") }
    $kql = (Get-Content -Raw (Join-Path $PSScriptRoot 'kql/user-connection.kql')).
      Replace('{{UserPrincipalName}}', (& $q $UserPrincipalName)).Replace('{{ResourceGroupId}}', (& $q $rgId)).Replace('{{WindowMinutes}}', "$SinceMinutes")
    # A bounded number of checks, not a wall clock (lesson 0008): one now, then one every PollSeconds.
    $polls = [math]::Floor($TimeoutMinutes * 60 / $PollSeconds) + 1
    Write-Host "  Looking for connections in the last $SinceMinutes minutes$(if ($polls -gt 1) { "; waiting up to $TimeoutMinutes minutes for the data to arrive (usually 3 to 10)" })..." -ForegroundColor DarkGray
    $failedChecks = 0
    for ($i = 1; $i -le $polls; $i++) {
      $outcome = Get-AvdUserConnectionOutcome -Row @(Invoke-AvdLogQuery -WorkspaceCustomerId $customerId -Query $kql)
      if ($outcome.Status -eq 'verified') { break }
      # Errors without a Connected row: check once more in case the rest of the connection is still arriving.
      if ($outcome.Status -eq 'failed') { $failedChecks++; if ($failedChecks -ge 2) { break } } else { $failedChecks = 0 }
      if ($i -lt $polls) {
        $seen = @{ none = 'nothing yet'; inprogress = 'a connection started, not connected yet'; failed = 'errors, no connection yet' }[$outcome.Status]
        Write-Host "  [$i/$polls] $seen; checking again in $PollSeconds seconds" -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSeconds
        $context.waitedSeconds += $PollSeconds
      }
    }
  }
  catch {
    $outcome = $null
    $code = if ($_.Exception.Message -match '\((\d{3})\)') { [int]$Matches[1] } else { 0 }
    Add-AvdCheckResult 'Connection' "Query the connection logs in $(Split-Path $lz.LogAnalyticsId -Leaf)" 'Fail' -Id 'query-failed' -Data @{ status = $code } `
      -Detail $_.Exception.Message `
      -Remediation $(if ($code -eq 403) { "You need read access to the workspace's data: Log Analytics Reader on $($lz.ResourceGroups.Management) (or the workspace), then run this again." } else { 'Run it again. If it keeps failing, report the problem with this output.' })
  }
}

if ($outcome) {
  $describe = { param($c)
    $client = @($c.clientType, $c.clientOS | Where-Object { $_ }) -join ' on '
    @("$($c.sessionHost)", $(if ($client) { "client $client" }), $(if ($c.gatewayRegion) { "gateway $($c.gatewayRegion)" }), $(if ($c.transportType) { "transport $($c.transportType)" }) | Where-Object { $_ }) -join ', '
  }
  $errorText = { param($c) (@($c.errors) | ForEach-Object { "$($_.code): $($_.message)" }) -join ' | ' }
  switch ($outcome.Status) {
    'verified' {
      $c = $outcome.Connected[0]
      $setup = if ($null -ne $c.connectionSetupSeconds) { "Connection setup (Started to Connected): $($c.connectionSetupSeconds) s. That's connection setup, not time to a usable desktop; a first connection to a stopped host includes it starting." } else { 'No Started row to time it from.' }
      Add-AvdCheckResult 'Connection' "$UserPrincipalName connected ($(& $describe $c))" 'Pass' -Detail $setup
      foreach ($e in $outcome.Errored | Where-Object { -not $_.connectedAt }) {
        Add-AvdCheckResult 'Connection' 'Another attempt in the window failed' 'Warn' -Id 'connect-errors' -Detail (& $errorText $e) -Data @{ codes = @($e.errors | ForEach-Object { $_.code }) }
      }
    }
    'failed' {
      $e = $outcome.Errored[0]
      $service = @($e.errors | Where-Object { "$($_.serviceError)" -eq 'True' }).Count -gt 0
      Add-AvdCheckResult 'Connection' "$UserPrincipalName didn't connect: AVD logged errors" 'Fail' -Id 'connect-errors' -Detail (& $errorText $e) `
        -Data @{ codes = @($e.errors | ForEach-Object { $_.code }); serviceError = $service } `
        -Remediation $(if ($service) { 'AVD marked it a service error: try again in a few minutes and check Azure Service Health.' } else { 'Run the post-deployment check (Test-AvdLandingZoneReadiness.ps1) for the host pool and your group membership, then try again.' })
    }
    'inprogress' {
      Add-AvdCheckResult 'Connection' "$UserPrincipalName's connection started but hasn't reached Connected" 'Fail' -Id 'in-progress' `
        -Detail "No errors logged yet. The host may still be starting, or the rest of the connection hasn't reached Log Analytics." -Remediation 'Run this again with a longer -TimeoutMinutes.'
    }
    default {
      Add-AvdCheckResult 'Connection' "A connection by $UserPrincipalName in the last $SinceMinutes minutes" 'Fail' -Id 'no-connection' `
        -Detail "Nothing logged for this user$(if ($context.waitedSeconds) { " after waiting $([math]::Round($context.waitedSeconds / 60)) minutes" })." `
        -Remediation 'Open the desktop and sign in as this user, then run this again (with a longer -TimeoutMinutes if it was only just now). If it stays empty, the sign-in never reached AVD.'
    }
  }
  $context.connections = @($outcome.Connections | Select-Object -First 5)
}

$summary = Write-AvdSummary
$status = if ($outcome -and $outcome.Status -eq 'verified') { 'verified' } elseif ($outcome -and $outcome.Status -eq 'failed') { 'failed' } else { 'notverified' }
$portalState = Get-AvdPortalState -Stage verify -Status $status -Context $context
switch ($status) {
  'verified' { Write-Host 'Verified: AVD recorded the connection.' -ForegroundColor Green }
  'failed' { Write-Host 'Failed: AVD logged errors and no connection.' -ForegroundColor Red }
  default { Write-Host "Not verified: $(if ($outcome) { 'no connection reached Connected' } else { "the check couldn't run" }). This is not a pass." -ForegroundColor Yellow }
}
Write-AvdPortalState $portalState
if ($status -eq 'verified' -and -not $summary.Failed) { exit 0 }
exit 1
