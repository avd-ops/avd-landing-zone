#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Removes the demo host pool deployed by Deploy-AvdDemo.ps1, and optionally the
  whole landing zone.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Supports -WhatIf.

  Default (demo only)
    - rg-<prefix>-<env>-demo: host pool, app group, workspace, session hosts,
      disks, NICs, the host pool's private endpoint and the demo RBAC
    - the subscription deployment record avdlz-demo-<prefix>-<env>
    - the demo hosts' Entra ID and Intune device objects (skip with -KeepDevices)

  -IncludeLandingZone (everything; asks you to type the landing zone name)
    - profile backup: turns vault immutability and soft delete off, stops
      protection deleting recovery points, unregisters the storage account
      (which releases the AzureBackupProtectionLock)
    - resource groups hosts, avd, storage, management, network (in that order)
    - policy assignments avdlz-* and their role assignments, the budget,
      the activity-log diagnostic setting, avdlz-* deployment records
      (with another landing zone in the subscription, only this one's budget,
      deployment records and an activity-log export to its own workspace)
    - Entra ID / Intune device objects of the landing zone hosts
    - the storage account's Entra app, purged from Entra's deleted items (the next
      deployment reuses the account name)
    - -ResetDefender also sets the Defender plans the landing zone enabled back to Free

  The Log Analytics workspace is deleted permanently first (a soft-deleted one is
  recovered by the next deployment and breaks it; lesson 0023).
  Key Vault is left soft-deleted with purge protection (90 days). To redeploy with
  the same name prefix, run the pre-deployment preflight with -Fix: it recovers
  the vault. See docs/gotchas.md.

.EXAMPLE
  ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -IncludeLandingZone -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  [string] $SubscriptionId,
  [switch] $IncludeLandingZone,
  [switch] $KeepDevices,
  [switch] $ResetDefender,
  # Skip confirmations (including the typed confirmation for -IncludeLandingZone).
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
if ($Force) { $ConfirmPreference = 'None' }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$sub = "/subscriptions/$($lz.SubscriptionId)"
Clear-AvdCheckResult
Write-Host "AVD cleanup - $($lz.BaseName) in '$($ctx.Subscription.Name)'$(if ($IncludeLandingZone) { ' (DEMO + LANDING ZONE)' } else { ' (demo only)' })" -ForegroundColor White

if ($IncludeLandingZone -and -not $Force -and -not $WhatIfPreference) {
  Write-Host "This permanently deletes the landing zone '$($lz.BaseName)', its profiles and their backups." -ForegroundColor Red
  $typed = Read-Host "Type '$($lz.BaseName)' to continue"
  if ($typed -ne $lz.BaseName) { throw 'Confirmation did not match; nothing was removed.' }
  $ConfirmPreference = 'None'
}

function Remove-AvdDevice {
  <# Deletes Entra ID and Intune device objects for the given computer names. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([string[]] $ComputerName)
  if (-not $ComputerName) { return }
  $left = "Delete these devices in Entra ID and Intune: $($ComputerName -join ', '). For the demo, running this script again also finishes it."
  try { Connect-AvdGraph -Purpose Cleanup }
  catch { $script:DeviceCleanupIncomplete = $true; Add-AvdCheckResult 'Devices' 'Microsoft Graph sign-in' 'Warn' -Detail $_.Exception.Message -Remediation $left -Id 'devices-left' -Data @{ devices = @($ComputerName) }; return }
  foreach ($name in $ComputerName) {
    try {
      $found = 0; $removed = 0
      $managed = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection 'deviceManagement/managedDevices' -Filter "deviceName eq '$name'" -Select 'id,deviceName')
      foreach ($d in @($managed)) {
        $found++
        if ($PSCmdlet.ShouldProcess("Intune device $name", 'Delete')) { Invoke-AvdGraph -Method DELETE -Uri "v1.0/deviceManagement/managedDevices/$($d.id)" | Out-Null; $removed++ }
      }
      $devices = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection devices -Filter "displayName eq '$name'" -Select 'id,displayName')
      foreach ($d in @($devices)) {
        $found++
        if ($PSCmdlet.ShouldProcess("Entra ID device $name", 'Delete')) { Invoke-AvdGraph -Method DELETE -Uri "v1.0/devices/$($d.id)" | Out-Null; $removed++ }
      }
      if ($removed) { Add-AvdCheckResult 'Devices' "Device objects for $name" 'Fixed' -Detail "Removed $removed of $found object(s)." }
      elseif (-not $found) { Add-AvdCheckResult 'Devices' "Device objects for $name" 'Pass' -Detail 'None found.' }
    }
    catch { $script:DeviceCleanupIncomplete = $true; Add-AvdCheckResult 'Devices' "Device objects for $name" 'Warn' -Detail $_.Exception.Message -Id 'devices-left' -Data @{ devices = @($name) } }
  }
}

function Remove-AvdStorageAppLeftover {
  <#
    Enabling Entra Kerberos creates the app '[Storage Account] <account>.file.core.windows.net'.
    Deleting the storage account moves the app and its service principal to Entra's deleted items
    for 30 days, still listing the account's names. The account name is deterministic, so the next
    deployment's app would claim the same names: purge the leftovers (build/specs/rebuild-spec.md, rule 26).
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string] $StorageFqdn)
  $name = "[Storage Account] $StorageFqdn"
  $check = "Storage app '$name' in Entra deleted items"
  if (-not $PSCmdlet.ShouldProcess($name, 'Purge from Entra deleted items (after the storage account is deleted)')) { return }
  try { Connect-AvdGraph -Purpose Cleanup }
  catch { Add-AvdCheckResult 'Entra ID' $check 'Warn' -Detail $_.Exception.Message -Remediation 'Purge it in Entra ID > App registrations > Deleted applications.'; return }
  $filter = "displayName eq '$($name.Replace("'", "''"))'"
  Write-Host '  waiting for the storage app to reach Entra''s deleted items (up to 2 minutes)' -ForegroundColor DarkGray
  $found = @()
  try {
    for ($i = 1; $i -le 8 -and -not $found.Count; $i++) {
      $found = @(foreach ($type in 'application', 'servicePrincipal') {
          Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection "directory/deletedItems/microsoft.graph.$type" -Filter $filter -Select 'id,displayName')
        })
      if (-not $found.Count) { Start-Sleep -Seconds 15 }
    }
    if (-not $found.Count) {
      $active = @(Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection applications -Filter $filter -Select 'id,appId'))
      if ($active.Count) { Add-AvdCheckResult 'Entra ID' $check 'Warn' -Detail 'The app is still active, not deleted.' -Remediation 'Rerun the cleanup in a few minutes, or purge it in Entra ID > App registrations > Deleted applications once it is there.' }
      else { Add-AvdCheckResult 'Entra ID' $check 'Pass' -Detail 'None found.' }
      return
    }
    foreach ($o in $found) {
      # Purging the app can take its service principal with it: a 404 on the second delete means it is gone.
      try { Invoke-AvdGraph -Method DELETE -Uri "v1.0/directory/deletedItems/$($o.id)" | Out-Null }
      catch { if ("$_" -notmatch '404|NotFound|does not exist') { throw } }
    }
    Add-AvdCheckResult 'Entra ID' $check 'Fixed' -Detail "Purged $($found.Count) deleted object(s) (app and service principal)."
  }
  catch { Add-AvdCheckResult 'Entra ID' $check 'Warn' -Detail $_.Exception.Message -Remediation 'Purge it in Entra ID > App registrations > Deleted applications.' }
}

function Remove-AvdResourceGroupIfPresent {
  [CmdletBinding(SupportsShouldProcess)]
  param([string] $Name)
  if (-not (Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue)) { Add-AvdCheckResult 'Resource groups' $Name 'Pass' -Detail 'Not present.'; return }
  if ($PSCmdlet.ShouldProcess($Name, 'Delete resource group')) {
    Write-Host "  deleting $Name (this can take several minutes)" -ForegroundColor DarkGray
    Remove-AzResourceGroup -Name $Name -Force | Out-Null
    Add-AvdCheckResult 'Resource groups' $Name 'Fixed' -Detail 'Deleted.'
  }
}

# ---------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------
Write-AvdSection 'Demo host pool'
$demoHosts = @()
if ($lz.RgExists.Demo) {
  $demoHosts = @(Get-AzVM -ResourceGroupName $lz.ResourceGroups.Demo -ErrorAction SilentlyContinue | ForEach-Object { $_.OSProfile.ComputerName })
}
$demoDeployment = "avdlz-demo-$($lz.BaseName)"
$demoRecord = Get-AzDeployment -Name $demoDeployment -ErrorAction SilentlyContinue
# Once the hosts are gone, only the deployment record still names them, so a rerun can finish
# a device cleanup that failed (a Graph sign-in that timed out, build/lessons/0029).
if (-not $demoHosts.Count -and $demoRecord -and -not $KeepDevices) {
  $record = Invoke-AvdArm -Path "$sub/providers/Microsoft.Resources/deployments/$demoDeployment`?api-version=2021-04-01" -AllowNotFound
  $demoHosts = @($record.properties.outputs.sessionHostNames.value | Where-Object { $_ })
}
Remove-AvdResourceGroupIfPresent -Name $lz.ResourceGroups.Demo
$script:DeviceCleanupIncomplete = $false
if (-not $KeepDevices) { Remove-AvdDevice -ComputerName $demoHosts }
if ($demoRecord -and $script:DeviceCleanupIncomplete) {
  Add-AvdCheckResult 'Deployments' $demoDeployment 'Warn' -Detail 'Kept: it names the demo hosts whose device objects are left.' -Remediation 'Run this script again to finish the device cleanup.'
}
elseif ($demoRecord -and $PSCmdlet.ShouldProcess($demoDeployment, 'Delete deployment record')) {
  Remove-AzDeployment -Name $demoDeployment | Out-Null
  Add-AvdCheckResult 'Deployments' $demoDeployment 'Fixed' -Detail 'Deleted.'
}

if (-not $IncludeLandingZone) {
  Write-AvdSummary | Out-Null
  if (-not $WhatIfPreference) { Write-AvdPortalState (Get-AvdPortalState -Stage cleanup -Context @{ namePrefix = $NamePrefix; environment = $Environment; includeLandingZone = [bool]$IncludeLandingZone }) }
  return
}

# ---------------------------------------------------------------------
# Landing zone
# ---------------------------------------------------------------------
$lzHosts = @()
if ($lz.RgExists.Hosts) {
  $lzHosts = @(Get-AzVM -ResourceGroupName $lz.ResourceGroups.Hosts -ErrorAction SilentlyContinue | ForEach-Object { $_.OSProfile.ComputerName })
}

Write-AvdSection 'Profile backup'
if ($lz.RecoveryVault) {
  $vault = Get-AzRecoveryServicesVault -ResourceGroupName $lz.RecoveryVault.ResourceGroupName -Name $lz.RecoveryVault.Name
  if ($PSCmdlet.ShouldProcess($vault.Name, 'Disable immutability and soft delete, stop protection and delete recovery points')) {
    # Immutability blocks "stop protection and delete data"; soft delete would keep
    # the items for 14 days and block deleting the vault.
    Update-AzRecoveryServicesVault -ResourceGroupName $vault.ResourceGroupName -Name $vault.Name -ImmutabilityState Disabled | Out-Null
    Set-AzRecoveryServicesVaultProperty -VaultId $vault.ID -SoftDeleteFeatureState Disable | Out-Null
    $items = @(Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $vault.ID)
    foreach ($item in $items) {
      Disable-AzRecoveryServicesBackupProtection -Item $item -RemoveRecoveryPoints -VaultId $vault.ID -Force | Out-Null
    }
    foreach ($c in @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -VaultId $vault.ID)) {
      Unregister-AzRecoveryServicesBackupContainer -Container $c -VaultId $vault.ID -Force | Out-Null
    }
    Add-AvdCheckResult 'Backup' "Stopped protection on $($items.Count) share(s) and unregistered the storage account" 'Fixed'
  }
}
else { Add-AvdCheckResult 'Backup' 'Recovery Services vault' 'Pass' -Detail 'Not present.' }

if ($lz.StorageAccount) {
  foreach ($lock in @(Get-AzResourceLock -Scope $lz.StorageAccount.Id -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("lock $($lock.Name) on $($lz.StorageAccount.StorageAccountName)", 'Remove')) {
      Remove-AzResourceLock -LockId $lock.LockId -Force | Out-Null
      Add-AvdCheckResult 'Backup' "Removed lock $($lock.Name) from the storage account" 'Fixed'
    }
  }
}

# Deleting a resource group only soft-deletes its Log Analytics workspace (14 days). A redeploy
# under the same name recovers it, and the AVD Insights data collection rule can then fail
# before the recovered tables are back (InvalidOutputTable; lesson 0023). Delete it permanently.
if ($lz.LogAnalyticsId) {
  $lawName = ($lz.LogAnalyticsId -split '/')[-1]
  if ($PSCmdlet.ShouldProcess($lawName, 'Delete the Log Analytics workspace permanently (skip the 14-day soft delete)')) {
    Invoke-AvdArm -Method DELETE -Path "$($lz.LogAnalyticsId)?api-version=2023-09-01&force=true" | Out-Null
    Add-AvdCheckResult 'Monitoring' "Log Analytics workspace $lawName" 'Fixed' -Detail 'Deleted permanently, so a redeploy creates a new one.'
  }
}

Write-AvdSection 'Landing zone resource groups'
foreach ($k in 'Hosts', 'ControlPlane', 'Storage', 'Management', 'Network') {
  Remove-AvdResourceGroupIfPresent -Name $lz.ResourceGroups[$k]
}

Write-AvdSection 'Subscription-level resources'
# Another landing zone in the subscription (e.g. test beside dev, docs/demo.md) still relies on the
# subscription-wide pieces, so only this landing zone's own are removed then.
$others = @(Find-AvdLandingZone | Where-Object { "$($_.NamePrefix)-$($_.Environment)" -ne $lz.BaseName } | ForEach-Object { "$($_.NamePrefix)-$($_.Environment)" })
$keptFor = "Kept: landing zone $($others -join ', ') still uses it."
$assignments = Invoke-AvdArm -Path "$sub/providers/Microsoft.Authorization/policyAssignments?api-version=2024-04-01&`$filter=atScope()"
foreach ($pa in @($assignments.value | Where-Object name -like 'avdlz-*')) {
  if ($others.Count) { Add-AvdCheckResult 'Subscription' "Policy assignment $($pa.name)" 'Skip' -Detail $keptFor; continue }
  if (-not $PSCmdlet.ShouldProcess("policy assignment $($pa.name)", 'Delete (and its role assignments)')) { continue }
  if ($pa.identity -and $pa.identity.principalId) {
    Get-AzRoleAssignment -ObjectId $pa.identity.principalId -Scope $sub -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-AzRoleAssignment -InputObject $_ | Out-Null }
  }
  Invoke-AvdArm -Method DELETE -Path "$($pa.id)?api-version=2024-04-01" | Out-Null
  Add-AvdCheckResult 'Subscription' "Policy assignment $($pa.name)" 'Fixed' -Detail 'Deleted.'
}

$budgetPath = "$sub/providers/Microsoft.Consumption/budgets/budget-$($lz.BaseName)?api-version=2023-11-01"
if ((Invoke-AvdArm -Path $budgetPath -AllowNotFound) -and $PSCmdlet.ShouldProcess("budget-$($lz.BaseName)", 'Delete budget')) {
  Invoke-AvdArm -Method DELETE -Path $budgetPath | Out-Null
  Add-AvdCheckResult 'Subscription' "Budget budget-$($lz.BaseName)" 'Fixed' -Detail 'Deleted.'
}

$diagPath = "$sub/providers/Microsoft.Insights/diagnosticSettings/avdlz-activity-log?api-version=2021-05-01-preview"
$diag = Invoke-AvdArm -Path $diagPath -AllowNotFound
# The export belongs to the landing zone whose workspace it sends to; one sending to this landing
# zone's (deleted) workspace goes even when another landing zone remains.
$diagIsOurs = $diag -and ([string]$diag.properties.workspaceId) -match "/resourceGroups/rg-$([regex]::Escape($lz.BaseName))-"
if ($diag -and $others.Count -and -not $diagIsOurs) { Add-AvdCheckResult 'Subscription' 'Activity log diagnostic setting' 'Skip' -Detail $keptFor }
elseif ($diag -and $PSCmdlet.ShouldProcess('avdlz-activity-log', 'Delete activity log diagnostic setting')) {
  Invoke-AvdArm -Method DELETE -Path $diagPath | Out-Null
  Add-AvdCheckResult 'Subscription' 'Activity log diagnostic setting' 'Fixed' -Detail 'Deleted.'
}

# Deployment records: this landing zone's own when another remains (deploy.sh names them
# avdlz-<parameter file>-<time>; module deployments carry <prefix>-<env>), otherwise every avdlz-* record.
$records = @(Get-AzDeployment -ErrorAction SilentlyContinue | Where-Object DeploymentName -like 'avdlz-*')
if ($others.Count) { $records = @($records | Where-Object { $_.DeploymentName -like "*$($lz.BaseName)*" -or $_.DeploymentName -like "avdlz-$($lz.Environment)-*" }) }
foreach ($d in $records) {
  if ($PSCmdlet.ShouldProcess($d.DeploymentName, 'Delete deployment record')) {
    Remove-AzDeployment -Name $d.DeploymentName | Out-Null
    Add-AvdCheckResult 'Subscription' "Deployment record $($d.DeploymentName)" 'Fixed' -Detail 'Deleted.'
  }
}

if ($ResetDefender) {
  foreach ($plan in 'VirtualMachines', 'StorageAccounts', 'KeyVaults') {
    if ($PSCmdlet.ShouldProcess("Defender plan $plan", 'Set to Free')) {
      Invoke-AvdArm -Method PUT -Path "$sub/providers/Microsoft.Security/pricings/$plan`?api-version=2024-01-01" -Body @{ properties = @{ pricingTier = 'Free' } } | Out-Null
      Add-AvdCheckResult 'Subscription' "Defender plan $plan set to Free" 'Fixed'
    }
  }
}

if (-not $KeepDevices) { Remove-AvdDevice -ComputerName $lzHosts }

if ($lz.StorageFqdn) {
  Write-AvdSection 'Entra ID'
  Remove-AvdStorageAppLeftover -StorageFqdn $lz.StorageFqdn
}

if ($lz.KeyVault) {
  # Under -WhatIf nothing was deleted yet: say what will happen, not what has.
  $kvState = if ($WhatIfPreference) { 'will be soft-deleted' } else { 'is soft-deleted' }
  Add-AvdCheckResult 'Subscription' "Key Vault $($lz.KeyVault.Name) $kvState with purge protection" 'Warn' -Detail 'Its name is reserved for 90 days after deletion.' -Remediation 'To redeploy with the same namePrefix, run the pre-deployment preflight with -Fix: it recovers the vault.'
}
Write-AvdSummary | Out-Null
if (-not $WhatIfPreference) { Write-AvdPortalState (Get-AvdPortalState -Stage cleanup -Context @{ namePrefix = $NamePrefix; environment = $Environment; includeLandingZone = [bool]$IncludeLandingZone }) }
