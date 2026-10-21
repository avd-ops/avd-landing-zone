# scripts/deploy/deploy.sh against a fake az (build/tests/offline/deploybin/az) that logs every call.
# Lesson 0026: a redeploy fails on session hosts that aren't running, so deploy.sh starts them
# before the deployment and deallocates them after, whether it succeeds or fails.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '../../..')
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
  $calls = @(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^az (group exists|vm |deployment sub (create|what-if))' -and $_ -notmatch 'jumpbox' } |
      ForEach-Object { $_ -replace '^az deployment sub (\S+).*', 'deployment-$1' -replace '^az (\S+) (\S+).*', '$1-$2' })
  Write-Host "RESULT $Step-calls $($calls -join ',')"
  Write-Host "RESULT $Step-ids $(@(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^az vm (start|deallocate)' } | ForEach-Object { if ($_ -match '--ids (\S+)') { ($Matches[1] -split '/')[-1] } }) -join ',')"
  Write-Host "RESULT $Step-unmocked $([bool]($out -match 'unmocked call'))"
  Write-Host "RESULT $Step-env $(@(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'deploy-env *' }) -join ';')"
  Write-Host "RESULT $Step-jumpbox $(@(Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like 'jumpbox-env *' }) -join ';')"
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
$env:FAKE_POWER_LOCK = ''; $env:FAKE_NOT_RUNNING = ''

# A group found by name whose owner is not an administrator (red team LZ-1): refused before anything
# else. Owned by a Global Administrator, it is accepted; given by object ID, owners are not checked.
$env:FAKE_HOSTS_RG_EXISTS = 'true'; $env:FAKE_GROUP_OWNERS = 'u-eve'; $env:FAKE_ADMIN_IDS = 'admin-1'
Invoke-Deploy 'owned-group'
$env:FAKE_GROUP_OWNERS = 'admin-1'
Invoke-Deploy 'admin-owned-group'
$env:FAKE_GROUP_OWNERS = 'u-eve'
Invoke-Deploy 'group-by-id' @('--admins-group', '22222222-2222-2222-2222-222222222222', '--users-group', '11111111-1111-1111-1111-111111111111')
$env:FAKE_GROUP_OWNERS = ''; $env:FAKE_ADMIN_IDS = ''

# Image and generation (image pipeline spec section 6.1). The host pool's tags decide; deploy.sh passes
# them back so they survive, refuses a different image or generation, and refuses during a rotation,
# except for the rotation script itself (--rotation).
$v1 = '/subscriptions/0000/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd/versions/2026.1004.1'
$v2 = '/subscriptions/0000/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd/versions/2026.1101.1'
$env:FAKE_HOSTS_RG_EXISTS = 'true'
$env:FAKE_POOL_TAGS = "{`n  `"avdlz-generation`": `"a`",`n  `"avdlz-image`": `"$v1`",`n  `"avdlz-image-next`": null,`n  `"avdlz-rotation`": null`n}"
Invoke-Deploy 'pool-tags'
Invoke-Deploy 'pool-tags-new-generation' @('--generation', 'b', '--image-id', $v2)
$env:FAKE_POOL_TAGS = "{`n  `"avdlz-generation`": `"a`",`n  `"avdlz-image`": `"$v1`",`n  `"avdlz-image-next`": `"$v2`",`n  `"avdlz-rotation`": `"{\`"phase\`":\`"Deploy\`"}`"`n}"
Invoke-Deploy 'pool-rotating'
Invoke-Deploy 'pool-rotation-deploy' @('--generation', 'b', '--image-id', $v2, '--rotation')
# A rotation starts and deallocates only the new generation's VMs: a stopped retiring host stays stopped.
$env:FAKE_NOT_RUNNING = "$stopped`n$($stopped -replace 'avdlzdsh-001$', 'avdlzdshb-001')"
Invoke-Deploy 'pool-rotation-stopped' @('--generation', 'b', '--image-id', $v2, '--rotation')
$env:FAKE_NOT_RUNNING = ''
# A pool that outlived its hosts resource group still decides: its tags are read all the same.
$env:FAKE_HOSTS_RG_EXISTS = 'false'
Invoke-Deploy 'pool-no-hosts-rg'
$env:FAKE_POOL_TAGS = "{`n  `"avdlz-generation`": `"a`",`n  `"avdlz-image`": `"$v1`",`n  `"avdlz-image-next`": null,`n  `"avdlz-rotation`": null`n}"
Invoke-Deploy 'pool-no-hosts-rg-keeps'
$env:FAKE_HOSTS_RG_EXISTS = 'true'
# A host pool that can't be read is not a missing one: stop, with what Azure said.
$env:FAKE_POOL_READ_ERROR = '(AuthorizationFailed) The client does not have authorization to perform action Microsoft.DesktopVirtualization/hostpools/read.'
Invoke-Deploy 'pool-unreadable'
$env:FAKE_POOL_READ_ERROR = ''
$env:FAKE_POOL_TAGS = ''
$env:FAKE_HOSTS_RG_EXISTS = 'false'
Invoke-Deploy 'first-image' @('--image-id', $v1, '--generation', 'a')
Invoke-Deploy 'bad-image' @('--image-id', '/subscriptions/0000/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd')

# Operator jumpbox (decision 0018). --jumpbox-keep-running alone needs a jumpbox; one that exists is
# kept without --jumpbox, accepts --jumpbox-keep-running, and its VM is marked existing so it isn't re-sent.
$soon = [datetime]::UtcNow.AddHours(4).ToString('yyyy-MM-ddTHH:mmZ')
Invoke-Deploy 'jumpbox-new' @('--jumpbox')
Invoke-Deploy 'jumpbox-keep-alone' @('--jumpbox-keep-running', $soon)
Invoke-Deploy 'jumpbox-past' @('--jumpbox', '--jumpbox-keep-running', '2020-01-01T00:00Z')
$env:FAKE_JUMPBOX_RG_EXISTS = 'true'; $env:FAKE_JUMPBOX_VM_EXISTS = 'true'
Invoke-Deploy 'jumpbox-kept'
Invoke-Deploy 'jumpbox-kept-running' @('--jumpbox-keep-running', $soon)
$env:FAKE_JUMPBOX_RG_EXISTS = ''; $env:FAKE_JUMPBOX_VM_EXISTS = ''
Invoke-Deploy 'jumpbox-region' @('--jumpbox', '-l', 'eastus')
Remove-Item $log -ErrorAction SilentlyContinue
