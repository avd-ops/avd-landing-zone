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

Invoke-ScenarioStep 'demo' { & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com }
# A hardening baseline that stops a Kerberos client service fails the host check by name. Not in the state-line list.
$global:St.kerberosServicesStopped = @('iphlpsvc')
$kerbDemo = & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com 6>&1 | Out-String
$global:St.kerberosServicesStopped = @()
Write-Host "RESULT kerberos-services failed=$($kerbDemo -match 'FAIL.*Entra Kerberos services running') named=$($kerbDemo -match 'Not running: iphlpsvc')"
Invoke-ScenarioStep 'remove-demo' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force }

$global:Calls.Clear()
Invoke-ScenarioStep 'remove-lz-whatif' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -WhatIf }
Write-Host "RESULT remove-lz-whatif changes=$(@($global:Calls | Where-Object { $_ -match 'del |unlock|backup|rsv|DELETE|RBAC -|PUT' }).Count)"

$global:Calls.Clear()
Invoke-ScenarioStep 'remove-lz' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -IncludeLandingZone -ResetDefender -Force }
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
Invoke-ScenarioStep 'remove-test-beside-dev' { & ./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment test -IncludeLandingZone -Force }
Write-Host ("RESULT remove-test-beside-dev devRgs={0} testRgs={1} policyDeletes={2} activityLogDeleted={3} records={4}" -f `
    @($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-dev-*' }).Count, @($global:St.rgs | Where-Object { $_ -like 'rg-avdlz-test-*' }).Count,
    @($global:Calls | Where-Object { $_ -match 'DELETE .*policyAssignments' }).Count, [bool]@($global:Calls | Where-Object { $_ -match 'DELETE .*avdlz-activity-log' }).Count,
    ($global:St.deployments -join ','))
