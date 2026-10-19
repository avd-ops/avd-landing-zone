# Post-deployment -WellArchitected against the mocked landing zone: first as the dev parameter
# file deploys it (one host, LRS, no backup, Defender off, 30-day logs, a region without zones),
# then as a production-grade one. Findings are warnings, so both runs exit 0.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.unregistered = @()   # providers are covered by the other scenarios
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev'; SkipTenant = $true; SkipNtfs = $true }

Invoke-ScenarioStep 'dev' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -WellArchitected }
Write-Host "RESULT dev-calls psruleExport=$(@($global:Calls | Where-Object { $_ -match '^psrule export .*rg-avdlz-dev-hosts' }).Count) suppressions=$(@($global:Calls | Where-Object { $_ -match 'psrule invoke outcome=Fail suppressions=True' }).Count) assessmentPages=$(@($global:Calls | Where-Object { $_ -match 'Microsoft.Security/assessments' }).Count)"

$global:Calls.Clear()
Invoke-ScenarioStep 'skip-psrule' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -WellArchitected -SkipPSRule }
Write-Host "RESULT skip-psrule-calls psrule=$(@($global:Calls | Where-Object { $_ -match '^psrule' }).Count)"

$global:St.waf = @{ good = $true; regionZones = $true }
Invoke-ScenarioStep 'production-grade' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -WellArchitected }

$global:St.waf = @{ good = $false; regionZones = $false; amaFailed = $true; standardDisk = $true }
Invoke-ScenarioStep 'ama-failed' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz -WellArchitected }

$global:St.waf = @{ good = $true; regionZones = $true }
Invoke-ScenarioStep 'without-switch' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 @lz }
