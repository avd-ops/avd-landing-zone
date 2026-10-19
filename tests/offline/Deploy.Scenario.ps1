# scripts/deploy/deploy.sh against a fake az (tests/offline/deploybin/az) that logs every call.
# Lesson 0026: a redeploy fails on session hosts that aren't running, so deploy.sh starts them
# before the deployment and deallocates them after, whether it succeeds or fails.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '../..')
$env:PATH = (Join-Path $PSScriptRoot 'deploybin') + [IO.Path]::PathSeparator + $env:PATH
$log = Join-Path ([IO.Path]::GetTempPath()) "avdlz-fake-az-$PID.log"
$env:FAKE_AZ_LOG = $log
$stopped = '/subscriptions/0000/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/avdlzdsh-001'

function Invoke-Deploy([string] $Step, [string[]] $Extra) {
  Remove-Item $log -ErrorAction SilentlyContinue
  Write-Host "`n######## $Step" -ForegroundColor Magenta
  $out = & bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins' @Extra 2>&1 | Out-String
  $exit = $LASTEXITCODE
  Write-Host $out
  Write-Host "RESULT $Step EXIT=$exit"
  # The calls that matter, in order: power state, start, deployment, deallocate.
  $calls = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^az (group exists|vm |deployment sub (create|what-if))' } |
      ForEach-Object { $_ -replace '^az deployment sub (\S+).*', 'deployment-$1' -replace '^az (\S+) (\S+).*', '$1-$2' })
  Write-Host "RESULT $Step-calls $($calls -join ',')"
  Write-Host "RESULT $Step-ids $(@(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^az vm (start|deallocate)' } | ForEach-Object { if ($_ -match '--ids (\S+)') { ($Matches[1] -split '/')[-1] } }) -join ',')"
  Write-Host "RESULT $Step-unmocked $([bool]($out -match 'unmocked call'))"
}

# A redeploy while the host is deallocated: start, deploy, deallocate.
$env:FAKE_HOSTS_RG_EXISTS = 'true'; $env:FAKE_NOT_RUNNING = $stopped; $env:FAKE_DEPLOY_EXIT = '0'
Invoke-Deploy 'stopped'

# The deployment fails: the host is still deallocated again.
$env:FAKE_DEPLOY_EXIT = '1'
Invoke-Deploy 'stopped-fails'

# What-if: says the host isn't running, starts nothing.
$env:FAKE_DEPLOY_EXIT = '0'
Invoke-Deploy 'whatif' @('--what-if')

# Every host running: nothing to start or deallocate.
$env:FAKE_NOT_RUNNING = ''
Invoke-Deploy 'running'

# First deployment: no hosts resource group yet, so no VM calls.
$env:FAKE_HOSTS_RG_EXISTS = 'false'
Invoke-Deploy 'first'

# Locked by auto shutdown (a budget alert): refused before any host is touched, unless --unlock.
# A what-if only reports it.
$env:FAKE_HOSTS_RG_EXISTS = 'true'; $env:FAKE_NOT_RUNNING = $stopped; $env:FAKE_POWER_LOCK = 'budget 2026-10-19T03:00:00Z'
Invoke-Deploy 'locked'
Invoke-Deploy 'locked-whatif' @('--what-if')
Invoke-Deploy 'locked-unlock' @('--unlock')
$env:FAKE_POWER_LOCK = ''
Remove-Item $log -ErrorAction SilentlyContinue
