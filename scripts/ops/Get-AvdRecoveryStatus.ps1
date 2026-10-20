#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  If this subscription were gone tomorrow, what would you lose, and is the recovery tier met?
  (build/specs/recovery-spec.md section 6).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Read-only, safe to run any time. For each item the landing
  zone must bring back (code, configuration, profiles, image, Key Vault, AVD groups) it reports where
  the last good copy is and whether the tier's targets are met:

    dr-iac              the deployment names a commit GitHub has
    dr-config           a configuration snapshot with a copy read back, within the RPO
    dr-profile-backup   the profile share's last backup (the post-deployment check's verdict)
    dr-profile-backup-access  whether Azure Backup can reach the profile account
    dr-profile-offsite  (R1 and up) a vaulted, geo-redundant copy with Cross Region Restore
    dr-image            the session host image comes back (replica in the recovery region for R1)
    dr-keyvault         soft delete and purge protection (secrets are regenerated, never copied)
    dr-identity         the AVD groups exist and a verified snapshot holds them
    dr-standby          (R2) warm standby; not built in this repository yet
    dr-capacity         (R1 and up) always a warning: quota is not capacity
    dr-tested           a passed recovery test within 90 days

  The tier (-RecoveryTier) changes nothing in Azure; it only sets the targets. Snapshots and test
  results are read from the run folders (run.json, avd-second-brain contract C17) under -LocalRoot:
  ~/clouddrive/avdlz-runs when clouddrive is mounted (it persists), else ~/avdlz-runs.

  Ends with the deployment portal's state line (stage recovery, status met or notmet).

.EXAMPLE
  ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Get-AvdRecoveryStatus.ps1 -NamePrefix avdlz -Environment prod -RecoveryTier R1 -RecoveryLocation southcentralus
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [ValidateSet('R0', 'R1', 'R2')][string] $RecoveryTier = 'R0',
  # Defaults to the deployment's recoveryLocation parameter, when it has one.
  [string] $RecoveryLocation,
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  # Also print the results as JSON, for a run record.
  [switch] $AsJson,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRecovery.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$now = [datetime]::UtcNow
$target = Get-AvdRecoveryTarget -Tier $RecoveryTier
Write-Host "Recovery status - $NamePrefix-$Environment in '$($ctx.Subscription.Name)', tier $RecoveryTier ($($target.Name): RPO $($target.RpoHours) h, RTO $($target.RtoHours) h)" -ForegroundColor White

Write-Host '  Reading the landing zone, its deployment record, backup, image and Key Vault...' -ForegroundColor DarkGray
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$sub = "/subscriptions/$($ctx.Subscription.Id)"
# Each read reports its full error (lesson 0012) and counts as not known, never as met.
$read = {
  param([string] $What, [scriptblock] $Do)
  try { & $Do }
  catch { Add-AvdCheckResult 'Recovery' "Read $What" 'Warn' -Id 'dr-read' -Detail "$_" -Remediation 'Check your role on the landing zone (Reader is enough) and run this again.' -Data @{ what = $What }; $null }
}

$deployment = & $read 'the deployment records' {
  @(Get-AvdArmList -Path "$sub/providers/Microsoft.Resources/deployments?api-version=2021-04-01" |
      Where-Object { $_.name -match "^avdlz-$([regex]::Escape($Environment))-\d{8}-\d{6}$" -and "$($_.properties.provisioningState)" -eq 'Succeeded' }) |
    Sort-Object { [datetime]$_.properties.timestamp } -Descending | Select-Object -First 1
}
if (-not $RecoveryLocation -and $deployment) { $RecoveryLocation = "$($deployment.properties.parameters.recoveryLocation.value)" }

# Run folders: snapshots and recovery tests (C17 run records with use case 'recovery').
$roots = @((Join-Path $LocalRoot 'clouddrive/avdlz-runs'), (Join-Path $LocalRoot 'avdlz-runs') | Where-Object { Test-Path -LiteralPath $_ })
$records = foreach ($root in $roots) {
  foreach ($f in Get-ChildItem -LiteralPath $root -Filter run.json -Recurse -Depth 1 -ErrorAction SilentlyContinue) {
    try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Host "  Skipping $($f.FullName): not JSON." -ForegroundColor DarkYellow }
  }
}
$runs = @(Get-AvdRecoveryRun -Record @($records))

# Profile backup: the vault, the protected share and its policy.
$vault = $null; $item = $null; $policy = $null; $findings = $null
if ($lz.RecoveryVault) {
  $vaultId = "$($lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($lz.RecoveryVault.Name)"
  $vault = & $read 'the Recovery Services vault' { Invoke-AvdArm -Path "$($vaultId)?api-version=2024-04-01" }
  $item = & $read 'the protected profile share' {
    @(Get-AvdArmList -Path "$vaultId/backupProtectedItems?api-version=2024-04-01&`$filter=backupManagementType eq 'AzureStorage'") |
      Where-Object { "$($_.name)" -match ";$([regex]::Escape($lz.ProfileShareName))$" } | Select-Object -First 1
  }
  if ($item -and $item.properties.policyId) { $policy = & $read 'the backup policy' { Invoke-AvdArm -Path "$($item.properties.policyId)?api-version=2024-04-01" } }
  # The backup's own state is the post-deployment check's verdict (one implementation, two reports).
  if (Get-Command Get-AvdProfileBackupVerdict -ErrorAction SilentlyContinue) {
    $account = if ($lz.StorageAccount) { & $read 'the profile storage account' { Invoke-AvdArm -Path "$($lz.StorageAccount.Id)?api-version=2023-05-01" } }
    $findings = @(Get-AvdProfileBackupVerdict -StorageAccount $account -ProtectedItem $item -Now $now)
  }
}

$images = @(); $versions = @()
if ($lz.RgExists.Hosts) {
  $vms = @(& $read 'the session hosts' { Get-AvdArmList -Path "$($lz.ResourceGroupIds.Hosts)/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" })
  $images = @($vms | Where-Object { $_ } | ForEach-Object { $_.properties.storageProfile.imageReference } | Where-Object { $_ })
  foreach ($id in @($images | Where-Object { "$($_.id)" -match '/galleries/' } | ForEach-Object { "$($_.id)" } | Select-Object -Unique)) {
    $versions += @(& $read "image $id" {
        if ($id -match '/versions/[^/]+$') { Invoke-AvdArm -Path "$($id)?api-version=2023-07-03" }
        else {
          $all = @(Get-AvdArmList -Path "$id/versions?api-version=2023-07-03")
          $latest = Get-AvdLatestVersion -Version @($all | ForEach-Object name)
          $all | Where-Object name -eq $latest
        }
      })
  }
}
$kv = if ($lz.KeyVault) { & $read 'the Key Vault' { Invoke-AvdArm -Path "$($lz.KeyVault.ResourceId)?api-version=2023-07-01" } }

$results = Get-AvdRecoveryVerdict -Tier $RecoveryTier -Deployment $deployment -Runs $runs -BackupEnabled ([bool]$lz.RecoveryVault) `
  -BackupFinding $findings -Vault $vault -ProtectedPolicy $policy -HostImage $images -ImageVersion $versions -RecoveryLocation $RecoveryLocation `
  -KeyVault $kv -Identity @{ UsersGroupId = $lz.UsersGroupId; AdminsGroupId = $lz.AdminsGroupId } -Now $now

Write-AvdSection "Recovery ($RecoveryTier)"
foreach ($r in $results) { Add-AvdCheckResult 'Recovery' $r.Check $r.Status -Id $r.Id -Detail $r.Detail -Remediation $r.Remediation -Data $r.Data }
$sum = Get-AvdRecoverySummary -Result $results
Write-Host ''
Write-Host "  $RecoveryTier met for $($sum.Met) of $($sum.Total) item(s)." -ForegroundColor $(if ($sum.Status -eq 'met') { 'Green' } else { 'Yellow' })
if ($AsJson) { $results | ConvertTo-Json -Depth 8 | Write-Output }

$context = [ordered]@{ namePrefix = $lz.NamePrefix; environment = $Environment; tier = $RecoveryTier; met = $sum.Met; total = $sum.Total; recoveryLocation = $RecoveryLocation }
$state = Get-AvdPortalState -Stage recovery -Status $sum.Status -Context $context
$null = Write-AvdSummary
Write-AvdPortalState $state
exit $(if ($sum.Status -eq 'met') { 0 } else { 1 })
