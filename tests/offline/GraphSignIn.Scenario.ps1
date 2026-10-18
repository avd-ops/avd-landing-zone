# One Microsoft Graph sign-in per Cloud Shell session (decision 0016): the operator app setup, run
# twice (the second run changes nothing), then a whole session (sign-in, preflight, -Fix, demo,
# cleanup) through the operator app, and the same session through Microsoft's default app.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev' }
$opAppId = '77777777-7777-7777-7777-777777777777'
$admins = '22222222-2222-2222-2222-222222222222'
$writes = { @($global:Calls | Where-Object { $_ -match '^GRAPH (POST|PATCH|DELETE) ' }) }
$connects = { @($global:Calls | Where-Object { $_ -match '^graph connect ' }) }

# ---- Setup, then again ----
$env:AVD_GRAPH_CLIENT_ID = $null
Invoke-ScenarioStep 'setup' { & ./scripts/ops/Initialize-AvdGraphApp.ps1 -OperatorsGroup $admins }
$app = $global:St.opApp
$graphScopes = @($app.requiredResourceAccess | Where-Object resourceAppId -eq '00000003-0000-0000-c000-000000000000' | ForEach-Object { $_.resourceAccess } | ForEach-Object id)
$grant = @($global:St.grants | Where-Object clientId -eq 'op-sp') | Select-Object -First 1
# Graph's service principal doesn't list Device.ReadWrite.All (lesson 0030): granted by name, not in the app's permission list.
Write-Host ("RESULT setup-state publicClient={0} scopes={1} assignmentRequired={2} consent={3} grantScopes={4} assigned={5} clientIdSet={6} setupClient={7} deviceGranted={8}" -f
  $app.isFallbackPublicClient, $graphScopes.Count, $global:St.opSp.appRoleAssignmentRequired, $grant.consentType, @($grant.scope -split ' ').Count,
  (@($global:St.opAssigned) -join ','), ($env:AVD_GRAPH_CLIENT_ID -eq $opAppId), ((& $connects) -join ';' -replace '^graph connect (client=\S+).*', '$1'),
  (@($grant.scope -split ' ') -contains 'Device.ReadWrite.All'))

$global:Calls.Clear()
Invoke-ScenarioStep 'setup-again' { & ./scripts/ops/Initialize-AvdGraphApp.ps1 -OperatorsGroup $admins }
Write-Host "RESULT setup-again writes=$((& $writes).Count)"

# A drifted app (assignment turned off) is put back.
$global:St.opSp.appRoleAssignmentRequired = $false
$global:Calls.Clear()
& ./scripts/ops/Initialize-AvdGraphApp.ps1 -OperatorsGroup $admins 6>&1 | Out-Null
Write-Host "RESULT setup-drift writes=$((& $writes).Count) assignmentRequired=$($global:St.opSp.appRoleAssignmentRequired)"

# An app created under its earlier name is renamed in place, so its client ID (and consent) stay.
$global:St.opApp.displayName = 'AVD Landing Zone Operator'; $global:St.opSp.displayName = 'AVD Landing Zone Operator'
$global:Calls.Clear()
& ./scripts/ops/Initialize-AvdGraphApp.ps1 -OperatorsGroup $admins 6>&1 | Out-Null
Write-Host "RESULT setup-rename exit=$LASTEXITCODE writes=$((& $writes).Count) app=$($global:St.opApp.displayName) sp=$($global:St.opSp.displayName) sameClient=$($global:St.opApp.appId -eq $opAppId) created=$(@($global:Calls | Where-Object { $_ -match '^GRAPH POST v1\.0/applications$' }).Count)"

# ---- A whole session through the operator app; the setup's own sign-in is still active ----
$env:AVD_GRAPH_CLIENT_ID = $opAppId
$global:Calls.Clear()
Invoke-ScenarioStep 'op-signin' { & ./scripts/ops/Connect-AvdLandingZone.ps1 }
Invoke-ScenarioStep 'op-check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }
Invoke-ScenarioStep 'op-fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force }
Invoke-ScenarioStep 'op-demo' { & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com }
Invoke-ScenarioStep 'op-remove' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force }
$c = & $connects
Write-Host "RESULT op-session connects=$($c.Count) client=$(($c | ForEach-Object { ($_ -split ' ')[2] }) -join ',')"

# ---- A default-app sign-in that already has every scope (earlier consent, as in the first real run)
# must not keep the operator app from being used once its client ID is set ----
$global:MgCtx = [pscustomobject]@{ TenantId = '55555555-5555-5555-5555-555555555555'; Scopes = @(Get-Content -Raw ./scripts/ops/Initialize-AvdGraphApp.ps1 | Select-String "'[A-Za-z]+\.[A-Za-z.]+'" -AllMatches | ForEach-Object { $_.Matches.Value.Trim("'") }); ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
$global:Calls.Clear()
$switched = & ./scripts/ops/Connect-AvdLandingZone.ps1 6>&1 | Out-String
$c = & $connects
Write-Host "RESULT default-to-operator connects=$($c.Count) client=$(($c | ForEach-Object { ($_ -split ' ')[2] }) -join ',') named=$($switched -match 'Through the avd-opsbot app')"

# ---- The same session through Microsoft's default app, without the sign-in script ----
$env:AVD_GRAPH_CLIENT_ID = $null
$global:MgCtx = $null
& ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com 6>&1 | Out-Null   # the cleanup needs a demo to remove
$global:MgCtx = $null
$global:Calls.Clear()
Invoke-ScenarioStep 'default-check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }
Invoke-ScenarioStep 'default-fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -Fix -Force }
Invoke-ScenarioStep 'default-demo' { & ./scripts/ops/Deploy-AvdDemo.ps1 @lz -TestUserUpn alex@contoso.com }
Invoke-ScenarioStep 'default-remove' { & ./scripts/ops/Remove-AvdDemo.ps1 @lz -Force }
$c = & $connects
Write-Host "RESULT default-session connects=$($c.Count) client=$(($c | ForEach-Object { ($_ -split ' ')[2] }) -join ',')"

# ---- A client ID that is not a GUID fails the sign-in step with the way out ----
$env:AVD_GRAPH_CLIENT_ID = 'avd-opsbot'
$global:MgCtx = $null
$bad = & ./scripts/ops/Connect-AvdLandingZone.ps1 6>&1 | Out-String
Write-Host "RESULT bad-client-id exit=$LASTEXITCODE named=$($bad -match 'is not a client ID') wayOut=$($bad -match 'Remove-Item Env:AVD_GRAPH_CLIENT_ID')"
$env:AVD_GRAPH_CLIENT_ID = $null
