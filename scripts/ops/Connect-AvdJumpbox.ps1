#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Gets the operator jumpbox ready to connect to through Azure Bastion Developer, or stops it
  (build/decisions/0018-jumpbox-bastion-developer.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), or any PowerShell signed in to Azure as an AVD operator
  (the landing zone gives the AVD Admins group Reader and Virtual Machine Contributor on the jumpbox).

  Connect (default)
    1. Starts the jumpbox if it isn't running (it stops daily on its own schedule).
    2. Sets a new one-time password on its local account through the VM access extension (management
       plane; the protected settings are encrypted to the VM). Bastion Developer offers no Microsoft
       Entra sign-in, so the OS account is local; the password changes on every connect, so nobody has
       to remember it and an old one is worth nothing.
    3. Prints the account, the password once, and the portal link to Connect > Bastion.

  -Stop deallocates the jumpbox now (a shutdown from inside the VM leaves compute billing).

  The jumpbox has no roles of its own: sign in as yourself there (az login --use-device-code,
  Connect-AzAccount -UseDeviceAuthentication) and run the same scripts as in Cloud Shell.

.EXAMPLE
  ./scripts/ops/Connect-AvdJumpbox.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Connect-AvdJumpbox.ps1 -NamePrefix avdlz -Environment dev -Stop
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  [string] $SubscriptionId,
  # Deallocate the jumpbox instead of preparing a connection.
  [switch] $Stop
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
Clear-AvdCheckResult
Write-Host "AVD jumpbox - $($lz.BaseName) in '$($ctx.Subscription.Name)'" -ForegroundColor White
if (-not $lz.Jumpbox) {
  throw "No jumpbox in $($lz.ResourceGroups.Jumpbox). Deploy it with: bash ./scripts/deploy/deploy.sh -p parameters/$Environment.bicepparam -l <region> --users-group '<AVD Users>' --admins-group '<AVD Admins>' --jumpbox"
}
$vmId = $lz.Jumpbox.ResourceId
$vmName = $lz.Jumpbox.Name
$api = 'api-version=2024-07-01'

function Get-JumpboxPowerState {
  $view = Invoke-AvdArm -Path "$vmId/instanceView?$api"
  @($view.statuses | Where-Object { $_.code -like 'PowerState/*' } | ForEach-Object code) | Select-Object -First 1
}

# Waits on a VM power state, bounded (lesson 0008).
function Wait-JumpboxPowerState([string] $Want, [int] $Minutes = 10) {
  $deadline = (Get-Date).AddMinutes($Minutes)
  do {
    $state = Get-JumpboxPowerState
    if ($state -eq $Want) { return $state }
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  throw "The jumpbox did not reach $Want in $Minutes minutes (last state: $state)."
}

# The VM access extension needs the guest agent: after a start it reports Ready a minute or two later.
function Wait-JumpboxAgent([int] $Minutes = 10) {
  $deadline = (Get-Date).AddMinutes($Minutes)
  do {
    $agent = (Invoke-AvdArm -Path "$vmId/instanceView?$api").vmAgent
    $ready = @($agent.statuses | Where-Object { $_.displayStatus -eq 'Ready' }).Count
    if ($ready) { return }
    Start-Sleep -Seconds 10
  } while ((Get-Date) -lt $deadline)
  throw "The jumpbox's VM agent was not Ready in $Minutes minutes: $($agent.statuses | ConvertTo-Json -Depth 5 -Compress)"
}

$power = Get-JumpboxPowerState
if ($Stop) {
  if ($power -eq 'PowerState/deallocated') { Write-Host "  $vmName is already deallocated: only its disk bills." -ForegroundColor Green; return }
  if ($PSCmdlet.ShouldProcess($vmName, 'Deallocate')) {
    Write-Host "  Deallocating $vmName (about a minute)..." -ForegroundColor DarkGray
    Invoke-AvdArm -Method POST -Path "$vmId/deallocate?$api" | Out-Null
    $null = Wait-JumpboxPowerState 'PowerState/deallocated'
    Write-Host "  $vmName is deallocated: only its disk bills." -ForegroundColor Green
  }
  return
}

if ($power -ne 'PowerState/running' -and $PSCmdlet.ShouldProcess($vmName, 'Start')) {
  Write-Host "  Starting $vmName ($($power -replace '^PowerState/', '')); this takes a minute or two..." -ForegroundColor DarkGray
  Invoke-AvdArm -Method POST -Path "$vmId/start?$api" | Out-Null
  $null = Wait-JumpboxPowerState 'PowerState/running'
}

if (-not $WhatIfPreference) {
  Write-Host '  Waiting for the VM agent (needed to set the password)...' -ForegroundColor DarkGray
  Wait-JumpboxAgent
}

$vm = Invoke-AvdArm -Path "$($vmId)?$api"
$user = $vm.properties.osProfile.adminUsername
$secure = Get-AvdRandomPassword
$password = ConvertFrom-SecureString -SecureString $secure -AsPlainText
if ($PSCmdlet.ShouldProcess("$user on $vmName", 'Set a one-time password (VM access extension)')) {
  Write-Host "  Setting a one-time password for $user (VM access extension, usually under a minute, up to 10)..." -ForegroundColor DarkGray
  $ext = "$vmId/extensions/enablevmaccess?$api"
  Invoke-AvdArm -Method PUT -Path $ext -Body @{
    location   = $vm.location
    properties = @{
      publisher               = 'Microsoft.OSTCExtensions'
      type                    = 'VMAccessForLinux'
      typeHandlerVersion      = '1.5'
      autoUpgradeMinorVersion = $true
      settings                = @{}
      protectedSettings       = @{ username = $user; password = $password }
    }
  } | Out-Null
  # "Done" means the extension succeeded, not that the request was accepted.
  $state = $null
  for ($i = 0; $i -lt 60; $i++) {
    $state = (Invoke-AvdArm -Path $ext).properties.provisioningState
    if ($state -in 'Succeeded', 'Failed', 'Canceled') { break }
    Start-Sleep -Seconds 10
  }
  if ($state -ne 'Succeeded') {
    $status = Invoke-AvdArm -Path "$vmId/extensions/enablevmaccess?`$expand=instanceView&$api"
    $how = if ($state -in 'Failed', 'Canceled') { "ended '$state'" } else { "is still '$state' after 10 minutes (it may yet finish: run this again to set a new password)" }
    throw "The VM access extension $how`: $($status.properties.instanceView.statuses | ConvertTo-Json -Depth 5 -Compress)"
  }
  $portal = "https://portal.azure.com/#@$($ctx.Tenant.Id)/resource$vmId/bastionHost"
  Write-Host ''
  Write-Host '  Ready. In the Azure portal: open the link, choose SSH, Authentication type Password, and paste:' -ForegroundColor Green
  Write-Host "    Link:     $portal"
  Write-Host "    Username: $user"
  Write-Host "    Password: $password   (one time: the next connect replaces it)"
  Write-Host ''
  Write-Host '  Bastion Developer holds one connection at a time. On the jumpbox, sign in as yourself (az login --use-device-code).' -ForegroundColor DarkGray
}
$password = $null

$schedule = Invoke-AvdArm -Path "$($lz.ResourceGroupIds.Jumpbox)/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$vmName`?api-version=2018-09-15" -AllowNotFound
$meter = Get-AvdJumpboxMeterState -PowerState (Get-JumpboxPowerState) -Tags $vm.tags -Schedule $schedule
Add-AvdCheckResult 'Jumpbox' "Jumpbox $vmName meter" $meter.Status -Id 'jumpbox-meter' -Detail $meter.Detail -Remediation $meter.Remediation
Write-AvdSummary | Out-Null
