# Where did I leave off (Get-AvdRunStatus.ps1, build/specs/run-recorder-spec.md section 4): Cloud Shell
# reset during deploy.sh, then again after the deployment finished, then after cleanup.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$now = (Get-Date).ToUniversalTime()
Invoke-ScenarioStep 'running' {
  $global:St.deploymentRecords = @(@{ name = 'avdlz-dev-20261019-100000'; state = 'Succeeded'; timestamp = $now.AddDays(-1).ToString('o') },
    @{ name = 'avdlz-dev-20261020-171800'; state = 'Running'; timestamp = $now.AddMinutes(-12).ToString('o') })
  & ./scripts/ops/Get-AvdRunStatus.ps1 -NamePrefix avdlz -Environment dev
}
Invoke-ScenarioStep 'succeeded' {
  $global:St.deploymentRecords[1].state = 'Succeeded'
  & ./scripts/ops/Get-AvdRunStatus.ps1
}
Invoke-ScenarioStep 'cleaned-up' {
  $global:St.rgs = @()
  & ./scripts/ops/Get-AvdRunStatus.ps1
}
