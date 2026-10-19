# A new profile share whose root never had an ACL set: Azure Files returns no permission key
# for it (found in a real run, PR #16). Check mode must report the default ACL; -Fix applies it.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.defaultRoot = $true
Invoke-ScenarioStep 'check' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev }
Invoke-ScenarioStep 'fix' { & ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -Force }
Write-Host "RESULT fix-state aclApplied=$($global:St.aclApplied)"
