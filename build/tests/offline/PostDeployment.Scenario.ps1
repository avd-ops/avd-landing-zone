# Post-deployment preflight, demo and cleanup against a mocked landing zone whose three
# tenant steps are not done yet.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev' }

Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }
Invoke-ScenarioStep 'fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force }
Write-Host "RESULT fix-state consent=$(@($global:St.grants).Count -gt 0) tagged=$(@($global:St.tags).Count -gt 0) caExcluded=$(@($global:St.caExclude).Count -gt 0) aclApplied=$($global:St.aclApplied) leftoverRoles=$(@($global:St.roleAssignments).Count)"
Invoke-ScenarioStep 'recheck' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }

# The launch link's IDs are read through REST; a desktop or workspace without objectId (ARM leaves out
# empty properties) means no launch context, never a malformed link. Not in the state-line list below.
$global:St.launchNoObjectId = $true
$noLaunch = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz 6>&1 | Out-String
$global:St.launchNoObjectId = $false
Write-Host "RESULT launch-missing hasLaunch=$($noLaunch -match '"launch":')"

# Security Defaults has no per-app exclusion, so it is reported as a warning, never changed. Not in the state-line list.
$global:St.securityDefaults = $true
$secDefaults = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz 6>&1 | Out-String
$global:St.securityDefaults = $false
Write-Host "RESULT security-defaults warned=$($secDefaults -match '\[WARN \] Security Defaults is off') stillReady=$($secDefaults -match '"status":"ready"')"

# AES-256-GCM as the only channel encryption denies Entra Kerberos sessions (lesson 0028). Not in the state-line list.
$global:St.smbChannel = 'AES-256-GCM;'
$channel = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz 6>&1 | Out-String
$global:St.smbChannel = $null
Write-Host "RESULT smb-channel failed=$($channel -match '\[FAIL \] Profile share allows AES-128-GCM') notReady=$($channel -match '"status":"notready"')"

# Recovery section (build/specs/recovery-spec.md): warnings only. No recovery region by default; one the landing
# zone's own guardrail leaves out says to deploy again with AVD_RECOVERY_LOCATION; one a management group's
# assignment leaves out says to ask its owner; too little quota there warns. Not in the state-line list.
$global:St.backup = @{ status = 'Healthy'; ageHours = 3 }
$noRegion = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs 6>&1 | Out-String
$own = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs -RecoveryLocation southcentralus 6>&1 | Out-String
$global:St.allowedLocations = @('eastus2', 'southcentralus'); $global:St.foreignAllowed = @('eastus2'); $global:St.quotaLimit = 5
$foreign = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs -RecoveryLocation southcentralus 6>&1 | Out-String
$global:St.foreignAllowed = $null; $global:St.quotaLimit = $null
$allowed = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs -RecoveryLocation southcentralus 6>&1 | Out-String
$global:St.allowedLocations = $null
Write-Host ("RESULT recovery-region skipped={0} ownWarned={1} ownSaysRedeploy={2} foreignNamed={3} quotaWarned={4} allowedPassed={5} stillReady={6}" -f
  ($noRegion -match '\[SKIP \] Recovery region'), ($own -match '\[WARN \] Recovery region southcentralus allowed by Azure Policy'), ($own -match 'export AVD_RECOVERY_LOCATION=southcentralus'),
  ($foreign -match 'Blocked by: Corp allowed RG locations \(allows eastus2\)'), ($foreign -match '"id":"recovery-quota"'), ($allowed -match '\[PASS \] Recovery region southcentralus allowed by Azure Policy'), ($foreign -match '"status":"ready"'))

# Profile backup: healthy and recent passes; a failed last backup on an account without key access names the
# key-based error; none yet and stale warn. Not in the state-line list.
$healthy = $noRegion
$global:St.backup = @{ status = 'Unhealthy'; ageHours = 30 }
$failed = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs 6>&1 | Out-String
$global:St.backup = @{ state = 'IRPending' }
$never = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SkipTenant -SkipNtfs 6>&1 | Out-String
$global:St.backup = $null
Write-Host ("RESULT profile-backup healthy={0} access={1} failedWarned={2} keyHint={3} stale={4} never={5} stillReady={6}" -f
  ($healthy -match '\[PASS \] Profile share backup'), ($healthy -match '\[PASS \] Azure Backup can reach the profile storage account'), ($failed -match '\[WARN \] Profile share backup'),
  ($failed -match 'UserErrorStorageKeyBasedAuthenticationNotPermitted'), ($failed -match 'last backup 30 hours ago'), ($never -match 'protection state IRPending; profiles has no backup yet'), ($failed -match '"status":"ready"'))

# A user-registered app with the storage app's display name (red team LZ-2). Beside the real one, the
# real one (no owners) is used; alone, after a teardown and before the account is redeployed, nothing
# is consented or excluded from Conditional Access. Not in the state-line list.
$global:St.storageAppImposter = 'beside'; $excluded = @($global:St.caExclude)
$beside = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force 6>&1 | Out-String
$global:St.storageAppImposter = 'only'; $global:St.caExclude = @()
$only = & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force 6>&1 | Out-String
$global:St.storageAppImposter = $null; $global:St.caExclude = $excluded
$besideReady = $beside -match '"status":"ready"'; $besideApp = $beside -match '\[PASS \] Storage account Entra app exists\s+55555555-'
$onlyFailed = $only -match '\[FAIL \] Storage account Entra app exists'; $onlyExcluded = @($global:St.caExclude | Where-Object { $_ -eq '66666666-6666-6666-6666-666666666666' }).Count
Write-Host "RESULT storage-app-imposter besideReady=$besideReady besideApp=$besideApp onlyFailed=$onlyFailed onlyExcluded=$onlyExcluded"

Invoke-ScenarioStep 'demo' { & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com }
# A hardening baseline that stops a Kerberos client service fails the host check by name. Not in the state-line list.
$global:St.kerberosServicesStopped = @('iphlpsvc')
$kerbDemo = & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com 6>&1 | Out-String
$global:St.kerberosServicesStopped = @()
Write-Host "RESULT kerberos-services failed=$($kerbDemo -match 'FAIL.*Entra Kerberos services running') named=$($kerbDemo -match 'Not running: iphlpsvc')"
Invoke-ScenarioStep 'remove-demo' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force }

# A Graph sign-in that times out during the demo cleanup (lesson 0029): the hosts are gone, so the
# deployment record is kept to name them, and a rerun deletes the devices and then the record.
# Not in the state-line list.
& ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com 6>&1 | Out-Null
$global:St.graphTimeout = $true; $global:MgCtx = $null
$timedOut = & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force 6>&1 | Out-String
$global:St.graphTimeout = $false
$global:Calls.Clear()
& ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force 6>&1 | Out-Null
$rerunDevices = @($global:Calls | Where-Object { $_ -match '^GRAPH DELETE v1\.0/(devices|deviceManagement/managedDevices)/' }).Count
Write-Host ("RESULT device-retry kept={0} named={1} rerunDeleted={2} recordGone={3}" -f ($timedOut -match 'Kept: it names the demo hosts'), ($timedOut -match 'Intune: avdlzddemo-001'),
  ($rerunDevices -gt 0), (@($global:St.deployments) -notcontains 'avdlz-demo-avdlz-dev'))

$global:Calls.Clear()
Invoke-ScenarioStep 'remove-lz-whatif' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -WhatIf }
Write-Host "RESULT remove-lz-whatif changes=$(@($global:Calls | Where-Object { $_ -match 'del |unlock|backup|rsv|DELETE|RBAC -|PUT' }).Count)"

# Never delete the last copy (decision 0016): -Force alone refuses, before anything changes.
$global:Calls.Clear()
$refused = try { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -Force 6>&1 | Out-Null; 'no' } catch { $_.Exception.Message }
Write-Host "RESULT remove-lz-refused named=$($refused -match '-DiscardLastCopy') changes=$(@($global:Calls | Where-Object { $_ -match 'del |unlock|backup|rsv|DELETE|RBAC -|PUT' }).Count)"

$global:Calls.Clear()
Invoke-ScenarioStep 'remove-lz' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -ResetDefender -Force -DiscardLastCopy }
$lawDelete = @($global:Calls | Where-Object { $_ -match '^ARM DELETE .*/workspaces/log-avdlz-dev\?api-version=[0-9-]+&force=true$' }).Count
$lawBeforeRg = @($global:Calls).IndexOf(@($global:Calls | Where-Object { $_ -match '^ARM DELETE .*/workspaces/log-avdlz-dev' })[0]) -lt @($global:Calls).IndexOf(@($global:Calls | Where-Object { $_ -match '^del rg rg-avdlz-dev-management' })[0])
Write-Host "RESULT remove-lz-workspace forceDeletes=$lawDelete beforeResourceGroup=$lawBeforeRg"
Write-Host "RESULT remove-lz remainingRgs=$(@($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-dev-*' }).Count)"
# The storage account's Entra app goes to deleted items with the account; cleanup purges it (rule 26).
$appPurge = @($global:Calls | Where-Object { $_ -match '^GRAPH DELETE v1\.0/directory/deletedItems/' })
$afterRg = @($global:Calls).IndexOf($appPurge[0]) -gt @($global:Calls).IndexOf(@($global:Calls | Where-Object { $_ -match '^del rg rg-avdlz-dev-storage' })[0])
Write-Host "RESULT remove-lz-storage-app deleteCalls=$($appPurge.Count) leftInDeletedItems=$(@($global:St.deletedItems).Count) afterStorageRg=$afterRg"

# Two landing zones in one subscription (test beside dev, docs/demo.md): removing test keeps
# what dev still uses (policy assignments, the activity log export to dev's workspace, dev's
# deployment records) and removes only test's resource groups.
$dev = 'network', 'management', 'storage', 'avd', 'hosts' | ForEach-Object { "rg-avdlz-dev-$_" }
$test = 'network', 'management', 'storage', 'avd', 'hosts' | ForEach-Object { "rg-avdlz-test-$_" }
$global:St.rgs = @($dev) + @($test)
$global:St.deployments = @('avdlz-dev-20260929-101500', 'avdlz-governance-avdlz-dev-northcentralus', 'avdlz-test-20260930-091500', 'avdlz-governance-avdlz-test-northcentralus')
$global:Calls.Clear()
Invoke-ScenarioStep 'remove-test-beside-dev' { & ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment test -IncludeLandingZone -Force -DiscardLastCopy }
Write-Host ("RESULT remove-test-beside-dev devRgs={0} testRgs={1} policyDeletes={2} activityLogDeleted={3} records={4}" -f `
    @($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-dev-*' }).Count, @($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-test-*' }).Count,
    @($global:Calls | Where-Object { $_ -match 'DELETE .*policyAssignments' }).Count, [bool]@($global:Calls | Where-Object { $_ -match 'DELETE .*avdlz-activity-log' }).Count,
    ($global:St.deployments -join ','))
