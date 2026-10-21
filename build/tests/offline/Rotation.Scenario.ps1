# Blue/green host rotation (scripts/ops/Invoke-AvdHostRotation.ps1, image pipeline spec section 6.5) against the
# mocked landing zone: two hosts on version 1 (avdlzdsh-001 with one session, 002 idle) move to version 2 as
# generation a, run by run, the way an operator runs it again after each wait. Then a rotation rolled back
# before Remove, and one back to the previous version after it. deploy.sh runs against the fake az in deploybin, as in Deploy.Scenario.ps1.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$global:St.unregistered = @()
$env:PATH = (Join-Path $PSScriptRoot 'deploybin') + [IO.Path]::PathSeparator + $env:PATH
$env:FAKE_AZ_LOG = Join-Path ([IO.Path]::GetTempPath()) "avdlz-rotation-az-$PID.log"
$env:FAKE_HOSTS_RG_EXISTS = 'true'; $env:FAKE_DEPLOY_EXIT = '0'; $env:FAKE_NOT_RUNNING = ''
$gal = '/subscriptions/00000000-aaaa-bbbb-cccc-000000000001/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd'
$v1 = "$gal/versions/2026.1004.1"; $v2 = "$gal/versions/2026.1101.1"
$p = @{ NamePrefix = 'avdlz'; Environment = 'dev' }

function Reset-Rotation {
  $global:St.rotation = @{
    tags = @{ 'avdlz-image' = $v1 }
    hosts = @{ 'avdlzdsh-001' = @{ status = 'Available'; sessions = 1; allowNew = $true }; 'avdlzdsh-002' = @{ status = 'Available'; sessions = 0; allowNew = $true } }
    vmsGone = @(); vmsSlow = @(); excluded = @(); galleryTags = @(); runs = @(); messages = 0; signedOut = 0
    deployment = @{
      sessionHostNamePrefix = @{ value = 'avdlzdsh' }; sessionHostCount = @{ value = 2 }; sessionHostVmSize = @{ value = 'Standard_D4as_v5' }
      maxSessionLimit = @{ value = 4 }; avdUsersGroupObjectId = @{ value = '11111111-1111-1111-1111-111111111111' }
      avdAdminsGroupObjectId = @{ value = '22222222-2222-2222-2222-222222222222' }; startVmOnConnect = @{ value = $true }
    }
  }
}
function Add-Generation([string] $Status, [string[]] $Names = @('avdlzdsha-001', 'avdlzdsha-002')) {
  foreach ($n in $Names) { $global:St.rotation.hosts[$n] = @{ status = $Status; sessions = 0; allowNew = $true } }
}
# The rotation's own deployment record, as Azure keeps it after Cloud Shell disconnects, under the name the
# rotation recorded. A routine deployment just before it never counts as the rotation's.
function Set-RotationRun([string] $State) {
  $name = ($global:St.rotation.tags['avdlz-rotation'] | ConvertFrom-Json).deploy
  $global:St.rotation.runs = @(@{ name = 'avdlz-dev-20261021-000000'; state = 'Succeeded'; timestamp = [datetime]::UtcNow.ToString('o') }, @{ name = $name; state = $State; timestamp = [datetime]::UtcNow.ToString('o') })
}
# Moves the recorded deadline or notice into the past, as if the operator came back later.
function Set-RotationTime([string] $Key) {
  $s = $global:St.rotation.tags['avdlz-rotation'] | ConvertFrom-Json
  $s | Add-Member -NotePropertyName $Key -NotePropertyValue ([datetime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mmZ')) -Force
  $global:St.rotation.tags['avdlz-rotation'] = $s | ConvertTo-Json -Compress
}
function Show-Rotation([string] $Step) {
  $ro = $global:St.rotation; $t = $ro.tags
  $phase = if ($t['avdlz-rotation']) { ($t['avdlz-rotation'] | ConvertFrom-Json).phase } else { '' }
  $hosts = @($ro.hosts.Keys | Sort-Object | Where-Object { -not $ro.hosts[$_].deleted } | ForEach-Object { '{0}:{1}' -f $_, $(if ($ro.hosts[$_].allowNew) { 'open' } else { 'drain' }) })
  Write-Host ("RESULT $Step-state phase={0} image={1} gen={2} next={3} previous={4} hosts={5} vmsGone={6} messages={7} signedOut={8} gallery={9}" -f `
      $phase, ($t['avdlz-image'] -replace '^.*/versions/', ''), $t['avdlz-generation'], ($t['avdlz-image-next'] -replace '^.*/versions/', ''), ($t['avdlz-image-previous'] -replace '^.*/versions/', ''),
      ($hosts -join ','), ($ro.vmsGone -join ','), $ro.messages, $ro.signedOut, (@($ro.galleryTags | ForEach-Object { $_ -replace '^(\w+) .*/versions/', '$1 ' }) -join ','))
  Write-Host "RESULT $Step-excluded $(@($ro.excluded | Where-Object { $_ } | Sort-Object) -join ',')"
  Write-Host "RESULT $Step-deploy $(@(Get-Content $env:FAKE_AZ_LOG -ErrorAction SilentlyContinue | Where-Object { $_ -like 'deploy-env *' -or $_ -like 'az deployment sub create*' } | ForEach-Object { $_ -replace '^az deployment sub create .*', 'create' -replace '/subscriptions/[^"\s]*/versions/', '' }) -join ';')"
  Remove-Item $env:FAKE_AZ_LOG -ErrorAction SilentlyContinue
}

Reset-Rotation
# Refused before anything changes: the version the pool already runs, then too little quota for both generations.
Invoke-ScenarioStep 'same-image' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v1 }
Show-Rotation 'same-image'
Invoke-ScenarioStep 'no-quota' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v2 }
Show-Rotation 'no-quota'
$global:St.quotaLimit = 40
# A parameter file for another landing zone, and Azure CLI on another subscription: refused before any tag changes.
Invoke-ScenarioStep 'wrong-file' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v2 -ParameterFile parameters/test.bicepparam }
Show-Rotation 'wrong-file'
$env:FAKE_AZ_SUB = '99999999-0000-0000-0000-000000000099'
Invoke-ScenarioStep 'cli-sub' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v2 }
Show-Rotation 'cli-sub'
$env:FAKE_AZ_SUB = ''

# Deploy: deploy.sh adds generation a with the last deployment's settings; the new hosts haven't registered.
Invoke-ScenarioStep 'deploy' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v2 }
Show-Rotation 'deploy'
# Cloud Shell disconnected while Azure still deploys: wait for it, don't start another.
Set-RotationRun 'Running'
Invoke-ScenarioStep 'deploy-running' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'deploy-running'
# It failed with one of two hosts registered: deploy again.
Set-RotationRun 'Failed'
Add-Generation 'Available' @('avdlzdsha-001')
Invoke-ScenarioStep 'deploy-retry' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'deploy-retry'
Set-RotationRun 'Succeeded'
# Registered but not yet Available: wait, without deploying again.
Add-Generation 'Unavailable'
Invoke-ScenarioStep 'hosts-wait' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'hosts-wait'
# Ready: the pool records the new image and generation, and the old hosts drain with a message.
Add-Generation 'Available'
Invoke-ScenarioStep 'drain' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'drain'
# After the deadline: nobody is signed out without -LogOffAtDeadline; with it, a notice, then sign-out.
Set-RotationTime 'deadline'
Invoke-ScenarioStep 'deadline' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'deadline'
Invoke-ScenarioStep 'notice' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -LogOffAtDeadline }
Show-Rotation 'notice'
Set-RotationTime 'notice'
Invoke-ScenarioStep 'logoff' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -LogOffAtDeadline }
Show-Rotation 'logoff'
# Remove: the old session hosts and VMs go; the device objects are listed to delete by hand. One VM is still
# deleting when the run stops; the next run finds it by its name although its session host is gone.
$global:St.rotation.vmsSlow = @('avdlzdsh-002')
Invoke-ScenarioStep 'remove' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'remove'
Invoke-ScenarioStep 'remove-resume' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'remove-resume'
# After Remove, a rollback is a rotation back to the previous version: it frees the version it leaves.
$global:St.rotation.galleryTags = @()
Invoke-ScenarioStep 'back-deploy' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -Rollback }
Add-Generation 'Available' @('avdlzdshb-001', 'avdlzdshb-002')
Invoke-ScenarioStep 'back-finish' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'back-finish'

# Rolled back before Remove: the original hosts take sessions again, the new ones drain and go.
Reset-Rotation
Invoke-ScenarioStep 'rb-deploy' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -ImageId $v2 }
Show-Rotation 'rb-deploy'
# Not while Azure is still deploying the hosts the rollback would remove.
Set-RotationRun 'Running'
Invoke-ScenarioStep 'rb-running' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -Rollback }
Show-Rotation 'rb-running'
Set-RotationRun 'Succeeded'
Add-Generation 'Available'
Invoke-ScenarioStep 'rb-drain' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p }
Show-Rotation 'rb-drain'
# A preview changes nothing.
$global:Calls.Clear()
Invoke-ScenarioStep 'rollback-whatif' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -Rollback -WhatIf }
Write-Host "RESULT rollback-whatif-writes $(@($global:Calls | Where-Object { $_ -match '^ARM (PATCH|PUT|POST|DELETE)' }).Count)"
Invoke-ScenarioStep 'rollback' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -Rollback }
Show-Rotation 'rollback'
# The pool runs the previous version again, so there is nothing left to roll back to.
Invoke-ScenarioStep 'rollback-again' { & ./scripts/ops/Invoke-AvdHostRotation.ps1 @p -Rollback }
Show-Rotation 'rollback-again'
$global:St.rotation = $null
Remove-Item $env:FAKE_AZ_LOG -ErrorAction SilentlyContinue
