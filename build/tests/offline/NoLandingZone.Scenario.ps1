# Post-deployment preflight in a subscription without the landing zone: one clear failure,
# not one per missing resource.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.rgs = @('rg-other-thing', 'rg-contoso-prod-network')
Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev }
