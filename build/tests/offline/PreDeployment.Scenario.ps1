# Pre-deployment preflight on an empty subscription (as in the first real Cloud Shell run):
# missing groups, service principal and providers; then a prod file whose zone 3 is unavailable
# and whose Key Vault name is held by a soft-deleted, purge-protected vault.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.rgs = @()
$global:St.unregistered = @('Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.KeyVault', 'Microsoft.RecoveryServices', 'Microsoft.Security')
$global:St.groups = @(); $global:St.avdSp = $false
$pre = @{ PreDeployment = $true; ParameterFile = 'parameters/dev.bicepparam'; UsersGroup = 'AVD Users'; AdminsGroup = 'AVD Admins' }

Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }
Invoke-ScenarioStep 'fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -Fix -Force }
Invoke-ScenarioStep 'recheck' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }

$global:St.skuZones = @('1', '2')
$global:St.deletedVaults = @([pscustomobject]@{ VaultName = 'kvavdlzprodabc123'; Location = 'northcentralus'; ResourceGroup = 'rg-avdlz-prod-management' })
Invoke-ScenarioStep 'prod-zone-and-vault' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/prod.bicepparam -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Location northcentralus
}

# Sized by the deployment portal: 3 x D8as_v5 with 60 sessions each (above 6 per vCPU), priced at
# the mock's placeholder list prices; the public IP meter is not found, so it is reported, not guessed.
$global:St.skuZones = @('1', '2', '3'); $global:St.deletedVaults = @(); $global:St.ipMeterRenamed = $true
Invoke-ScenarioStep 'sized' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 60 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 60
}
# After a quota increase the same sizing passes, and the printed deploy command carries it.
$global:St.quotaLimit = 100; $global:St.ipMeterRenamed = $false
Invoke-ScenarioStep 'sized-ready' {
  & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 32 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 60
}
$global:St.quotaLimit = $null

# The landing zone already runs D4as_v5 hosts; the parameter file now defaults to E4as_v5.
$global:St.rgs = @('rg-avdlz-dev-network', 'rg-avdlz-dev-management', 'rg-avdlz-dev-storage', 'rg-avdlz-dev-avd', 'rg-avdlz-dev-hosts')
Invoke-ScenarioStep 'redeploy-resize' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -Location eastus2 }
$global:St.rgs = @()

$global:St.pricesDown = $true
Invoke-ScenarioStep 'prices-down' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }

# Redeploying with the same prefix after Remove-AvdDemo -IncludeLandingZone (as in the first real
# cleanup): the vault is soft-deleted and its resource group gone. -Fix creates the group again and
# recovers the vault into it; a vault of the same prefix in another region is left alone.
$global:St.pricesDown = $false; $global:St.rgs = @()
$global:St.deletedVaults = @(
  [pscustomobject]@{ VaultName = 'kvavdlzdevs7abc123'; Location = 'northcentralus'; ResourceGroup = 'rg-avdlz-dev-management' },
  [pscustomobject]@{ VaultName = 'kvavdlzdevq9xyz789'; Location = 'eastus2'; ResourceGroup = 'rg-avdlz-dev-management' })
$global:Calls.Clear()
Invoke-ScenarioStep 'vault-recover' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -Fix -Force }
Write-Host "RESULT vault-recover-calls $(@($global:Calls | Where-Object { $_ -match '^ARM PUT' }) -join ' | ')"
Invoke-ScenarioStep 'vault-recovered' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }

# The portal's Cost step with both power settings off: hosts run around the clock, and the
# estimate and state line say so.
$global:St.deletedVaults = @()
Invoke-ScenarioStep 'power-off' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -AutoShutdownTime none -StartVmOnConnect false -ActiveHoursPerWeek 168 }

# A group of the right name that an ordinary user created, and so owns, must not get the landing
# zone's rights (red team LZ-1): fail. Owned by an administrator or by you, it passes.
$global:St.groupOwners = @(@{ id = 'u-eve'; userPrincipalName = 'eve@contoso.com' })
Invoke-ScenarioStep 'owned-group' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }
$global:St.groupOwners = @(@{ id = 'admin-1'; userPrincipalName = 'admin@contoso.com' }, @{ id = 'me-1'; userPrincipalName = 'nick@contoso.com' })
Invoke-ScenarioStep 'admin-owned-group' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre }
$global:St.groupOwners = $null

# Recovery region before deployment: the landing zone's own guardrail leaves it out, but this deployment adds
# it (recoveryLocation joins allowedLocations); a management group's assignment that leaves it out warns.
# Last, so the portal state indexes above stay put.
Invoke-ScenarioStep 'recovery-planned' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -RecoveryLocation southcentralus }
$global:St.foreignAllowed = @('northcentralus')
Invoke-ScenarioStep 'recovery-foreign' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @pre -RecoveryLocation southcentralus }
$global:St.foreignAllowed = $null
