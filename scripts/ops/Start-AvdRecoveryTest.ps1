#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  A recovery test of the profile share (T-profile, build/specs/recovery-spec.md section 8): restore the
  newest recovery point into a new storage account, measure the real RPO and restore time, tear down.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), in the operator's own subscription.

  (no switch)  Plan only, read-only: the newest recovery point, where the copy would go (always new
               names, never over the source), and the estimate at retail list prices. Nothing is created.
  -Go          Runs the test as a recorded run (use case 'recovery', kind 'test', contract C17):
               creates rg-<prefix>-<env>-rtest-<id> with one premium storage account and share, restores
               the whole share into it through Azure Backup, waits for the job, and records the measured
               RPO (age of the recovery point) and restore time. Only on the operator's go, after the plan.
  -Cleanup     Removes the test's resource group once the source share is confirmed still there (the
               restored share is a copy, spec section 11), checks it is gone, and records the teardown.

  Azure Files restores to an alternate location only in the vault's region and, through the API, only
  in the vault's subscription (spec F19, U7), so the copy goes there. The configuration half of a test
  (T-config: deploy.sh to a new prefix, in this or any other subscription in the same tenant, then
  compare with the snapshot) and the sign-in half (T-signin) are printed as the next steps.

  A test opens no real user's data: run it against test users' profiles only.

.EXAMPLE
  ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev

.EXAMPLE
  ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Go

.EXAMPLE
  ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix avdlz -Environment dev -Cleanup -RunId run-20261020-1900-ab12
#>
[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [ValidateSet('R0', 'R1', 'R2')][string] $RecoveryTier = 'R0',
  [Parameter(ParameterSetName = 'Go')][switch] $Go,
  [Parameter(ParameterSetName = 'Cleanup', Mandatory)][switch] $Cleanup,
  [Parameter(ParameterSetName = 'Cleanup', Mandatory)][string] $RunId,
  # Where T-config's redeploy goes: any subscription in this tenant (default: this one).
  [string] $TargetSubscriptionId,
  [ValidateRange(0.5, 24)][double] $Hours = 2,
  [ValidateRange(1, 720)][int] $TimeoutMinutes = 120,
  [string] $LocalRoot = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }),
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRecovery.psm1') -Force

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$now = [datetime]::UtcNow
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$mode = $PSCmdlet.ParameterSetName
Write-Host "Recovery test (T-profile) - $($lz.BaseName) in '$($ctx.Subscription.Name)', $($mode.ToLower())" -ForegroundColor White
$runsHome = $LocalRoot; $cloudDrive = Test-Path (Join-Path $LocalRoot 'clouddrive')
$folderOf = { param($id) (Get-AvdJournalSetting -Record on -RunId $id -HomePath $runsHome -CloudDriveExists $cloudDrive).Folder }
$stop = {
  param($Status)
  $state = Get-AvdPortalState -Stage recovery -Status $Status -Context ([ordered]@{ namePrefix = $lz.NamePrefix; environment = $Environment; tier = $RecoveryTier; test = 'T-profile'; mode = $mode.ToLower(); runId = $RunId })
  $null = Write-AvdSummary
  Write-AvdPortalState $state
  exit $(if ($Status -in 'failed', 'notready') { 1 } else { 0 })
}

if ($Cleanup) {
  Write-AvdSection 'Teardown'
  $folder = & $folderOf $RunId
  $runPath = Join-Path $folder 'run.json'
  if (-not (Test-Path -LiteralPath $runPath)) { throw "No run.json in ${folder}: pass the -RunId the test printed." }
  $run = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -AsHashtable
  $rg = $run.extensions.recovery.target.resourceGroup
  if ($run.useCase -ne 'recovery' -or $run.extensions.recovery.kind -ne 'test' -or $rg -notmatch '-rtest-[a-z0-9]{4}$') { throw "$RunId is not a recovery test run; nothing was removed." }
  # The restored share is a copy; it goes only while the source is still there (spec section 11).
  if (-not $lz.StorageAccount) {
    Add-AvdCheckResult 'Recovery' 'Source profile share still exists' 'Fail' -Id 'rtest-source-missing' -Detail "The landing zone's profile storage account is gone: $rg may hold the only copy of the profiles." `
      -Remediation "Nothing was removed. Keep $rg until the profiles are restored somewhere else, or delete it yourself if you mean to."
    & $stop 'failed'
  }
  Write-Host "  Deleting $rg (a few minutes)..." -ForegroundColor DarkGray
  Remove-AzResourceGroup -Name $rg -Force -ErrorAction Stop | Out-Null
  $gone = -not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)
  $evidence = [ordered]@{ resourceGroup = $rg; checkedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); found = -not $gone }
  ConvertTo-Json -InputObject $evidence | Set-Content -LiteralPath (Join-Path $folder 'teardown.json') -Encoding utf8
  $run.teardown = [ordered]@{ status = $(if ($gone) { 'clean' } else { 'leftovers' }); checkedAt = $evidence.checkedAt; evidence = 'teardown.json'; logs = 'Keep' }
  $run.status = if ($gone) { 'torn-down' } else { $run.status }
  $run.files = @(Get-AvdRunManifest -Folder $folder -Previous @($run.files | ForEach-Object { [pscustomobject]$_ }) | ForEach-Object { $e = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $e[$p.Name] = $p.Value }; $e })
  $run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runPath -Encoding utf8
  Add-AvdCheckResult 'Recovery' "Test resources removed ($rg)" $(if ($gone) { 'Pass' } else { 'Fail' }) -Id 'rtest-teardown' `
    -Detail $(if ($gone) { 'Azure no longer finds the resource group (teardown.json).' } else { 'The resource group is still there.' }) -Remediation $(if (-not $gone) { 'Run -Cleanup again in a few minutes.' })
  & $stop $(if ($gone) { 'done' } else { 'failed' })
}

# ---- The plan: what would be restored, where, and what it costs. Read-only.
Write-AvdSection 'Plan'
if (-not $lz.RecoveryVault -or -not $lz.StorageAccount) {
  Add-AvdCheckResult 'Recovery' 'Profile backup to test' 'Fail' -Id 'rtest-nobackup' -Detail 'The landing zone has no Recovery Services vault or no profile storage account.' `
    -Remediation 'Turn profile backup on (enableProfileBackup = true) and deploy again; a test needs at least one recovery point.'
  & $stop 'notready'
}
$vaultId = "$($lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($lz.RecoveryVault.Name)"
$vault = Invoke-AvdArm -Path "$($vaultId)?api-version=2024-04-01"
$item = @(Get-AvdArmList -Path "$vaultId/backupProtectedItems?api-version=2024-04-01&`$filter=backupManagementType eq 'AzureStorage'") |
  Where-Object { "$($_.name)" -match ";$([regex]::Escape($lz.ProfileShareName))$" } | Select-Object -First 1
$points = if ($item) { @(Get-AvdArmList -Path "$($item.id)/recoveryPoints?api-version=2024-04-01") } else { @() }
$point = $points | Sort-Object { [datetime]$_.properties.recoveryPointTime } -Descending | Select-Object -First 1
if (-not $point) {
  Add-AvdCheckResult 'Recovery' 'A recovery point to restore' 'Fail' -Id 'rtest-nopoint' -Detail $(if ($item) { 'The profile share is protected but has no recovery point yet.' } else { 'The profile share is not protected by the vault.' }) `
    -Remediation 'Wait for the first scheduled backup (02:00 UTC), or check the post-deployment preflight''s profile backup result.'
  & $stop 'notready'
}
$pointTime = ([datetime]$point.properties.recoveryPointTime).ToUniversalTime()
$share = Invoke-AvdArm -Path "$($lz.StorageAccount.Id)/fileServices/default/shares/$($lz.ProfileShareName)?api-version=2023-05-01"
$quota = [int]$share.properties.shareQuota
$planId = if ($RunId) { $RunId } else { Get-AvdRunId }
$price = @{}
try {
  $meters = @(Get-AvdRetailPrice -Filter "serviceName eq 'Storage' and armRegionName eq '$($vault.location)' and productName eq 'Premium Files' and priceType eq 'Consumption'" |
      Where-Object { $_.skuName -eq 'Premium LRS' -and $_.meterName -match 'Provisioned' -and $_.unitOfMeasure -match 'GB/Month|GiB/Month' })
  # One meter, or the line stays unpriced (decision 0010).
  if ($meters.Count -eq 1) { $price.premiumFilesGiBMonth = [double]$meters[0].retailPrice }
  else { Write-Host "  Premium Files provisioned price: $($meters.Count) meters matched ($(@($meters | ForEach-Object meterName) -join ', ')); left unpriced." -ForegroundColor DarkYellow }
}
catch { Write-Host "  Retail prices API: $_" -ForegroundColor DarkYellow }
$plan = Get-AvdRecoveryTestPlan -NamePrefix $lz.NamePrefix -Environment $Environment -RunId $planId -VaultLocation $vault.location `
  -SourceSubscriptionId $ctx.Subscription.Id -TargetSubscriptionId $TargetSubscriptionId -ShareGiB $quota -Hours $Hours -Price $price
Write-Host "  Recovery point   $($point.name), $($pointTime.ToString('yyyy-MM-dd HH:mm')) UTC ($(Get-AvdRecoveryAge $pointTime $now) old)"
Write-Host "  Restore to       $($plan.ResourceGroup) / $($plan.StorageAccount) / $($plan.Share) in $($plan.Location) (new names; the source is never written)"
foreach ($l in $plan.Lines) { Write-Host ('  {0,-80} {1}' -f $l.Item, $(if ($null -ne $l.Cost) { '{0:N2} USD' -f $l.Cost } else { 'unpriced' })) }
Write-Host ('  {0,-80} {1:N2} USD{2}' -f "Estimate for $Hours h", $plan.Total, $(if ($plan.Unpriced) { " plus $($plan.Unpriced) unpriced line(s)" })) -ForegroundColor White
if ($plan.CrossSubscription) { Write-Host "  T-config would deploy to subscription $($plan.TargetSubscriptionId) (same tenant); the profile copy stays in the vault's subscription (spec U7)." -ForegroundColor DarkGray }

if (-not $Go) {
  Add-AvdCheckResult 'Recovery' "T-profile planned: about $($plan.Total) USD for $Hours h" 'Pass' -Id 'rtest-plan' -Detail 'Nothing was created.' `
    -Remediation "Run it with -Go when you are ready; remove it after with -Cleanup -RunId <id>." -Data @{ estimate = $plan.Total; unpriced = $plan.Unpriced; recoveryPointAgeHours = [math]::Round(($now - $pointTime).TotalHours, 1) }
  & $stop 'ready'
}

# ---- The test: a recorded run.
$RunId = $planId
$folder = & $folderOf $RunId
$null = New-Item -ItemType Directory -Path $folder -Force
$commit = '0000000'
if (Get-Command git -ErrorAction SilentlyContinue) { $h = git -C $PSScriptRoot rev-parse --short HEAD 2>$null; if (-not $LASTEXITCODE -and $h) { $commit = "$h".Trim() } }
$target = [ordered]@{ resourceGroup = $plan.ResourceGroup; storageAccount = $plan.StorageAccount; share = $plan.Share; location = $plan.Location }
$ext = [ordered]@{ kind = 'test'; test = 'T-profile'; tier = $RecoveryTier; target = $target; targets = [ordered]@{ rpoHours = (Get-AvdRecoveryTarget $RecoveryTier).RpoHours; rtoHours = (Get-AvdRecoveryTarget $RecoveryTier).RtoHours }
  items = @([ordered]@{ id = 'P3'; source = "$($lz.StorageAccount.StorageAccountName)/$($lz.ProfileShareName)"; copy = "recovery point $($point.name)"; recoveryPointTime = $pointTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }) }
$run = Get-AvdRunRecord -RunId $RunId -UseCase 'recovery' -Commit $commit -Entry 'Start-AvdRecoveryTest.ps1' -Region $plan.Location -Started $now -Extension $ext
$save = { $run.files = @(Get-AvdRunManifest -Folder $folder | ForEach-Object { $e = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { $e[$p.Name] = $p.Value }; $e }); $run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'run.json') -Encoding utf8 }
& $save
Write-Host "  Run $RunId; remove the test's resources afterwards with: ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix $($lz.NamePrefix) -Environment $Environment -Cleanup -RunId $RunId" -ForegroundColor White

Write-AvdSection 'Restore'
$rgId = "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$($plan.ResourceGroup)"
$saId = "$rgId/providers/Microsoft.Storage/storageAccounts/$($plan.StorageAccount)"
$tags = @{ 'avdlz-recovery-test' = $RunId; 'avdlz-workload' = $lz.BaseName }
$fail = {
  param($Step, $Err)
  Add-AvdCheckResult 'Recovery' $Step 'Fail' -Id 'rtest-failed' -Detail "$Err" -Remediation "Remove what was created: ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix $($lz.NamePrefix) -Environment $Environment -Cleanup -RunId $RunId"
  $run.status = 'failed'; $run.ended = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); $run.extensions.recovery.outcome = 'failed'; & $save
  & $stop 'failed'
}
try {
  Write-Host "  Creating $($plan.ResourceGroup) and $($plan.StorageAccount)..." -ForegroundColor DarkGray
  $null = Invoke-AvdArm -Method PUT -Path "$($rgId)?api-version=2021-04-01" -Body @{ location = $plan.Location; tags = $tags }
  # Azure Backup restores Azure Files with key-based access (spec F14), so this one test account allows it;
  # it is reachable only by trusted Azure services, holds test users' profiles only, and goes with -Cleanup.
  $null = Invoke-AvdArm -Method PUT -Path "$($saId)?api-version=2023-05-01" -Body @{
    location = $plan.Location; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; tags = $tags
    properties = @{ minimumTlsVersion = 'TLS1_2'; supportsHttpsTrafficOnly = $true; allowSharedKeyAccess = $true; allowBlobPublicAccess = $false
      networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices' } }
  }
  for ($i = 0; $i -lt 30; $i++) {
    $sa = Invoke-AvdArm -Path "$($saId)?api-version=2023-05-01"
    if ("$($sa.properties.provisioningState)" -eq 'Succeeded') { break }
    Start-Sleep -Seconds 10
  }
  $null = Invoke-AvdArm -Method PUT -Path "$saId/fileServices/default/shares/$($plan.Share)?api-version=2023-05-01" -Body @{ properties = @{ shareQuota = $quota } }
}
catch { & $fail 'Create the test storage' $_ }

$started = [datetime]::UtcNow
try {
  Write-Host "  Restoring recovery point $($point.name) into $($plan.StorageAccount)/$($plan.Share)..." -ForegroundColor DarkGray
  $body = Get-AvdRecoveryRestoreRequest -SourceStorageAccountId $lz.StorageAccount.Id -TargetStorageAccountId $saId -TargetShare $plan.Share
  $null = Invoke-AvdArm -Method POST -Path "$($point.id)/restore?api-version=2024-04-01" -Body $body
}
catch { & $fail 'Start the restore' $_ }

# The restore job: newest Restore job for the share after the start. The loop ends on an error, a
# finished job or the timeout (lesson 0008).
$job = $null; $deadline = $started.AddMinutes($TimeoutMinutes)
Write-Host "  Waiting for the restore job (up to $TimeoutMinutes minutes; it keeps running in Azure if Cloud Shell disconnects)..." -ForegroundColor DarkGray
while ([datetime]::UtcNow -lt $deadline) {
  try {
    $job = @(Get-AvdArmList -Path "$vaultId/backupJobs?api-version=2024-04-01&`$filter=operation eq 'Restore' and startTime eq '$($started.AddMinutes(-5).ToString('yyyy-MM-dd hh:mm:ss tt'))' and endTime eq '$($deadline.ToString('yyyy-MM-dd hh:mm:ss tt'))'") |
      Sort-Object { [datetime]$_.properties.startTime } -Descending | Select-Object -First 1
  }
  catch { & $fail 'Read the restore job' $_ }
  if ($job -and "$($job.properties.status)" -notin 'InProgress', 'Cancelling', '') { break }
  Start-Sleep -Seconds 30
}
$done = [datetime]::UtcNow
$status = "$($job.properties.status)"
$bag = $job.properties.extendedInfo.propertyBag
$failedFiles = [int]"0$($bag.'Number Of Failed Files')"
$restoredFiles = [int]"0$($bag.'Number Of Restored Files')"
$passed = $status -eq 'Completed' -and $failedFiles -eq 0
$run.extensions.recovery.measured = [ordered]@{ rpoMinutes = [math]::Round(($started - $pointTime).TotalMinutes); restoreMinutes = [math]::Round(($done - $started).TotalMinutes, 1); rtoMinutes = [math]::Round(($done - $now).TotalMinutes, 1); restoredFiles = $restoredFiles; failedFiles = $failedFiles }
$run.extensions.recovery.outcome = if ($passed) { 'passed' } else { 'failed' }
$run.extensions.recovery.job = [ordered]@{ name = $job.name; status = $status; errors = @($job.properties.errorDetails | Where-Object { $_ } | ForEach-Object { "$($_.errorCode): $($_.errorString)" }) }
$run.status = if ($passed) { 'succeeded' } else { 'failed' }
$run.ended = $done.ToString('yyyy-MM-ddTHH:mm:ssZ')
& $save
if (-not $job) { Add-AvdCheckResult 'Recovery' 'Restore job' 'Fail' -Id 'rtest-nojob' -Detail "No restore job appeared within $TimeoutMinutes minutes." -Remediation "Look in the vault's Backup jobs, then remove the test with -Cleanup -RunId $RunId." }
else {
  Add-AvdCheckResult 'Recovery' "Profile share restored: $status, $restoredFiles file(s), $failedFiles failed" $(if ($passed) { 'Pass' } else { 'Fail' }) -Id 'rtest-restore' `
    -Detail "Measured RPO $($run.extensions.recovery.measured.rpoMinutes) min (age of the recovery point), restore $($run.extensions.recovery.measured.restoreMinutes) min.$(if ($run.extensions.recovery.job.errors) { ' ' + ($run.extensions.recovery.job.errors -join '; ') })" `
    -Remediation $(if (-not $passed) { 'Read the errors above (they are in run.json too), then remove the test with -Cleanup.' }) -Data $run.extensions.recovery.measured
}
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host "  1. Optional T-signin: point a test host at \\$($plan.StorageAccount).file.core.windows.net\$($plan.Share)\restored and sign in as a test user."
Write-Host "  2. Copy the record: ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId $RunId -Local -CopyTo github"
Write-Host "  3. Remove the test: ./scripts/ops/Start-AvdRecoveryTest.ps1 -NamePrefix $($lz.NamePrefix) -Environment $Environment -Cleanup -RunId $RunId"
& $stop $(if ($passed) { 'passed' } else { 'failed' })
