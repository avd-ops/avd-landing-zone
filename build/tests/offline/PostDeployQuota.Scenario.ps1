# Post-deployment quota check on a deployed landing zone, as in the real run of 2026-09-30:
# one Standard_E4as_v5 host deployed, Easv5 quota 4 with all 4 in use (by that host).
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.unregistered = @()
$global:St.hostSize = 'Standard_E4as_v5'; $global:St.eLimit = 4; $global:St.eUsed = 4
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev'; SkipTenant = $true; SkipNtfs = $true }
Invoke-ScenarioStep 'deployed-host' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SessionHostVmSize Standard_E4as_v5 -SessionHostCount 1 }
# Scaling out to two hosts needs 4 more vCPUs than the deployed host already uses.
Invoke-ScenarioStep 'scale-out' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -SessionHostVmSize Standard_E4as_v5 -SessionHostCount 2 }
