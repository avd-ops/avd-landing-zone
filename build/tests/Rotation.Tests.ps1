#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for blue/green host rotation (scripts/ops/AvdRotation.psm1; build/specs/image-pipeline-spec.md
# section 6.5). Deployment parameters omit what a deployment didn't set, the way ARM does (lesson 0021).
# Run: Invoke-Pester ./build/tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdRotation.psm1') -Force
  $script:now = [datetime]::new(2026, 10, 20, 12, 0, 0, [DateTimeKind]::Utc)
  $script:v1 = '/subscriptions/0000/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd/versions/2026.1004.1'
  $script:v2 = '/subscriptions/0000/resourceGroups/rg-avdlz-images/providers/Microsoft.Compute/galleries/galavdlz/images/win11-avd/versions/2026.1101.1'
  function New-SessionHost([string] $Vm, [string] $Gen, [bool] $Ok = $true, [int] $Sessions = 0, [bool] $Allow = $true) {
    [pscustomobject]@{ VmName = $Vm; Generation = $Gen; Available = $Ok; Healthy = $Ok; AllowNewSession = $Allow; Sessions = $Sessions }
  }
  function Get-Ids($r) { @($r | Where-Object Status -eq 'Fail' | ForEach-Object Id) -join ',' }
}

Describe 'Generations and names' {
  It 'alternates a and b, starting from the original names' {
    Get-AvdNextHostGeneration -Current '' | Should -Be 'a'
    Get-AvdNextHostGeneration -Current 'a' | Should -Be 'b'
    Get-AvdNextHostGeneration -Current 'b' | Should -Be 'a'
  }
  It 'names each generation as bicep/main.bicep does, and tells a host''s generation from its VM name' {
    Get-AvdGenerationPrefix -BasePrefix 'avdlzdsh' -Generation 'b' | Should -Be 'avdlzdshb'
    Get-AvdGenerationPrefix -BasePrefix 'contosoprsh' -Generation 'a' | Should -Be 'contosoprsa'
    Get-AvdHostGeneration -VmName 'avdlzdsh-001' -BasePrefix 'avdlzdsh' | Should -Be ''
    Get-AvdHostGeneration -VmName 'avdlzdsha-002' -BasePrefix 'avdlzdsh' | Should -Be 'a'
    Get-AvdHostGeneration -VmName 'contosoprsb-001' -BasePrefix 'contosoprsh' | Should -Be 'b'
    Get-AvdHostGeneration -VmName 'manual-vm' -BasePrefix 'avdlzdsh' | Should -BeNullOrEmpty
  }
  It 'flags an 11-character prefix ending in a or b, whose generation would reuse today''s names' {
    Test-AvdGenerationNameClash -BasePrefix 'contosoprsa' | Should -BeTrue
    Test-AvdGenerationNameClash -BasePrefix 'contosoprsh' | Should -BeFalse
    Test-AvdGenerationNameClash -BasePrefix 'avdlzdsha' | Should -BeFalse   # shorter: its a generation is avdlzdshaa
  }
  It 'labels images by version' {
    Get-AvdImageLabel $v2 | Should -Be '2026.1101.1'
    Get-AvdImageLabel '' | Should -Be 'marketplace'
  }
}

Describe 'The rotation tag' {
  It 'round-trips the state in at most 256 characters' {
    $s = @{ phase = 'Wait'; from = 'a'; to = 'b'; version = '2026.1101.1'; deadline = '2026-10-23T12:00Z'; rollback = $false; by = 'operator@contoso.com' }
    $tag = ConvertTo-AvdRotationTag $s
    $tag.Length | Should -BeLessOrEqual 256
    $o = ConvertFrom-AvdRotationTag $tag
    $o.phase | Should -Be 'Wait'; $o.to | Should -Be 'b'; $o.rollback | Should -BeFalse
  }
  It 'leaves out empty values, so the original generation (none) is simply absent' {
    $tag = ConvertTo-AvdRotationTag @{ phase = 'Deploy'; from = ''; to = 'a'; version = '2026.1101.1' }
    $tag | Should -Not -Match '"from"'
    (ConvertFrom-AvdRotationTag $tag).from | Should -BeNullOrEmpty
  }
  It 'reads nothing from an empty, unreadable or unknown-phase tag' {
    ConvertFrom-AvdRotationTag '' | Should -BeNullOrEmpty
    ConvertFrom-AvdRotationTag 'not json' | Should -BeNullOrEmpty
    ConvertFrom-AvdRotationTag '{"phase":"Teleport"}' | Should -BeNullOrEmpty
  }
}

Describe 'The Check phase' {
  It 'passes a new gallery version with quota for the new hosts' {
    $r = Get-AvdRotationCheck -PoolTags @{ 'avdlz-image' = $v1 } -TargetImageId $v2 -BasePrefix 'avdlzdsh' -HostCount 2 -VcpuPerHost 4 -QuotaFree 20
    Get-Ids $r | Should -Be ''
    ($r | Where-Object Id -eq 'rotation-image').Detail | Should -Be '2026.1004.1 -> 2026.1101.1'
  }
  It 'refuses a locked pool, a definition ID, the image it already runs, a name clash and short quota' {
    Get-Ids (Get-AvdRotationCheck -PoolTags @{ 'avdlz-power-lock' = 'budget 2026-10-19T03:00:00Z' } -TargetImageId $v2 -BasePrefix 'avdlzdsh') | Should -Be 'rotation-locked'
    Get-Ids (Get-AvdRotationCheck -PoolTags @{} -TargetImageId ($v2 -replace '/versions/.*$') -BasePrefix 'avdlzdsh') | Should -Be 'rotation-image'
    Get-Ids (Get-AvdRotationCheck -PoolTags @{ 'avdlz-image' = $v2 } -TargetImageId $v2 -BasePrefix 'avdlzdsh') | Should -Be 'rotation-image'
    # After a rollback before Remove, the previous version is the one the pool runs: nothing to roll back to.
    Get-Ids (Get-AvdRotationCheck -PoolTags @{ 'avdlz-image' = $v1; 'avdlz-image-previous' = $v1 } -TargetImageId $v1 -BasePrefix 'avdlzdsh' -Rollback) | Should -Be 'rotation-image'
    Get-Ids (Get-AvdRotationCheck -PoolTags @{} -TargetImageId '' -BasePrefix 'avdlzdsh') | Should -Be 'rotation-image'
    Get-Ids (Get-AvdRotationCheck -PoolTags @{} -TargetImageId $v2 -BasePrefix 'contosoprsb') | Should -Be 'rotation-names'
    $q = Get-AvdRotationCheck -PoolTags @{} -TargetImageId $v2 -BasePrefix 'avdlzdsh' -HostCount 3 -VcpuPerHost 4 -QuotaFree 8
    Get-Ids $q | Should -Be 'rotation-quota'
    ($q | Where-Object Id -eq 'rotation-quota').Detail | Should -Match '12 vCPUs needed, 8 free'
  }
  It 'warns, and does not fail, when quota could not be read' {
    $r = Get-AvdRotationCheck -PoolTags @{} -TargetImageId $v2 -BasePrefix 'avdlzdsh' -HostCount 2 -VcpuPerHost 4 -QuotaFree $null
    ($r | Where-Object Id -eq 'rotation-quota').Status | Should -Be 'Warn'
  }
}

Describe 'deploy.sh flags for the rotation''s deployment' {
  It 'keeps the last deployment''s sizing, power and groups, and adds the image, generation and --rotation' {
    $p = [pscustomobject]@{
      avdUsersGroupObjectId = [pscustomobject]@{ value = '11111111-1111-1111-1111-111111111111' }
      avdAdminsGroupObjectId = [pscustomobject]@{ value = '22222222-2222-2222-2222-222222222222' }
      sessionHostCount = [pscustomobject]@{ value = 3 }; sessionHostVmSize = [pscustomobject]@{ value = 'Standard_E4as_v5' }
      maxSessionLimit = [pscustomobject]@{ value = 8 }; profileShareQuotaGiB = [pscustomobject]@{ value = 100 }
      enableAutoShutdown = [pscustomobject]@{ value = $true }; autoShutdownTime = [pscustomobject]@{ value = '20:00' }
      startVmOnConnect = [pscustomobject]@{ value = $true }
    }
    $a = Get-AvdRotationDeployArgument -Parameters $p -ParameterFile 'parameters/dev.bicepparam' -Location 'northcentralus' -ImageId $v2 -Generation 'b' -HostCount 2 -DeploymentName 'avdlz-dev-rotb-20261021-000000'
    ($a -join ' ') | Should -Be "-p parameters/dev.bicepparam -l northcentralus --users-group 11111111-1111-1111-1111-111111111111 --admins-group 22222222-2222-2222-2222-222222222222 --hosts 2 --vm-size Standard_E4as_v5 --max-sessions 8 --profile-quota 100 --auto-shutdown 20:00 --start-vm-on-connect true --image-id $v2 --generation b --rotation --deployment-name avdlz-dev-rotb-20261021-000000"
  }
  It 'turns auto shutdown off when the deployment had it off, and leaves out what the record lacks' {
    $p = [pscustomobject]@{ enableAutoShutdown = [pscustomobject]@{ value = $false } }
    $a = Get-AvdRotationDeployArgument -Parameters $p -ParameterFile 'parameters/dev.bicepparam' -Location 'northcentralus' -ImageId '' -Generation 'a'
    ($a -join ' ') | Should -Be '-p parameters/dev.bicepparam -l northcentralus --auto-shutdown none --generation a --rotation'
    # Deployed with --auto-shutdown none: the record has auto shutdown on and an empty time.
    $p = [pscustomobject]@{ enableAutoShutdown = [pscustomobject]@{ value = $true }; autoShutdownTime = [pscustomobject]@{ value = '' } }
    (Get-AvdRotationDeployArgument -Parameters $p -ParameterFile 'parameters/dev.bicepparam' -Location 'northcentralus' -ImageId '' -Generation 'a') -join ' ' | Should -Be '-p parameters/dev.bicepparam -l northcentralus --auto-shutdown none --generation a --rotation'
  }
}

Describe 'Each phase''s next step' {
  BeforeAll { $script:s = { param($phase, $extra) $o = @{ phase = $phase; from = 'a'; to = 'b'; version = '2026.1101.1'; rollback = $false }; if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }; [pscustomobject]$o } }
  It 'waits in Deploy until every new host is Available and healthy' {
    $h = @((New-SessionHost 'avdlzdsha-001' 'a'), (New-SessionHost 'avdlzdshb-001' 'b'), (New-SessionHost 'avdlzdshb-002' 'b' -Ok $false))
    $r = Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $h -ExpectedCount 2 -Now $now
    $r.Action | Should -Be 'wait-hosts'; $r.Phase | Should -Be 'Deploy'; $r.Detail | Should -Match '1 of 2'
    $h[2] = New-SessionHost 'avdlzdshb-002' 'b'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $h -ExpectedCount 2 -Now $now).Action | Should -Be 'drain'
  }
  It 'follows the rotation''s own deployment: waits while it runs, deploys again after a failure, never twice at once' {
    $old = @((New-SessionHost 'avdlzdsha-001' 'a'), (New-SessionHost 'avdlzdsha-002' 'a'))
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $old -ExpectedCount 2 -Now $now -DeploymentState running).Action | Should -Be 'wait-hosts'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $old -ExpectedCount 2 -Now $now -DeploymentState none).Action | Should -Be 'deploy'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $old -ExpectedCount 2 -Now $now -DeploymentState failed).Action | Should -Be 'deploy'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $old -ExpectedCount 2 -Now $now -DeploymentState succeeded).Action | Should -Be 'wait-hosts'
    $one = $old + @(New-SessionHost 'avdlzdshb-001' 'b')
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $one -ExpectedCount 2 -Now $now -DeploymentState failed).Action | Should -Be 'deploy'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $one -ExpectedCount 2 -Now $now -DeploymentState succeeded).Action | Should -Be 'wait-hosts'
    # Never cut over to a failed deployment, even when every new host it left is ready.
    $all = $old + @((New-SessionHost 'avdlzdshb-001' 'b'), (New-SessionHost 'avdlzdshb-002' 'b'))
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $all -ExpectedCount 2 -Now $now -DeploymentState failed).Action | Should -Be 'deploy'
    (Get-AvdRotationStep -State (& $s 'Deploy') -SessionHosts $all -ExpectedCount 2 -Now $now -DeploymentState succeeded).Action | Should -Be 'drain'
  }
  It 'removes once no session is left on the old hosts, and otherwise waits for the deadline' {
    $h = @((New-SessionHost 'avdlzdsha-001' 'a' -Sessions 2 -Allow $false), (New-SessionHost 'avdlzdshb-001' 'b' -Sessions 5))
    $r = Get-AvdRotationStep -State (& $s 'Wait' @{ deadline = '2026-10-23T12:00Z' }) -SessionHosts $h -Now $now
    $r.Action | Should -Be 'wait-sessions'; $r.Detail | Should -Match '2 session\(s\) left'
    $h[0] = New-SessionHost 'avdlzdsha-001' 'a' -Sessions 0 -Allow $false
    (Get-AvdRotationStep -State (& $s 'Wait' @{ deadline = '2026-10-23T12:00Z' }) -SessionHosts $h -Now $now).Action | Should -Be 'remove'
  }
  It 'signs users out after the deadline only with -LogOffAtDeadline, and only 15 minutes after a final notice' {
    $h = @((New-SessionHost 'avdlzdsha-001' 'a' -Sessions 1 -Allow $false))
    $past = & $s 'Wait' @{ deadline = '2026-10-20T11:00Z' }
    (Get-AvdRotationStep -State $past -SessionHosts $h -Now $now).Action | Should -Be 'wait-sessions'
    (Get-AvdRotationStep -State $past -SessionHosts $h -Now $now -LogOffAtDeadline).Action | Should -Be 'notify'
    $noticed = & $s 'Wait' @{ deadline = '2026-10-20T11:00Z'; notice = '2026-10-20T11:50Z' }
    (Get-AvdRotationStep -State $noticed -SessionHosts $h -Now $now -LogOffAtDeadline).Action | Should -Be 'wait-sessions'
    (Get-AvdRotationStep -State $noticed -SessionHosts $h -Now $now.AddMinutes(10) -LogOffAtDeadline).Action | Should -Be 'logoff'
  }
  It 'treats the original generation (none) as its own generation' {
    $h = @((New-SessionHost 'avdlzdsh-001' '' -Sessions 0 -Allow $false), (New-SessionHost 'avdlzdsha-001' 'a'))
    $st = [pscustomobject]@{ phase = 'Wait'; to = 'a'; version = '2026.1101.1'; rollback = $false }
    (Get-AvdRotationStep -State $st -SessionHosts $h -Now $now).Action | Should -Be 'remove'
  }
}

Describe 'Rollback' {
  It 'swaps the generations before Remove, so the new hosts drain and go' {
    $st = [pscustomobject]@{ phase = 'Wait'; from = 'a'; to = 'b'; version = '2026.1101.1'; rollback = $false; by = 'me' }
    $r = Get-AvdRotationRollback -State $st -Now $now
    $r.from | Should -Be 'b'; $r.to | Should -Be 'a'; $r.phase | Should -Be 'Drain'; $r.rollback | Should -BeTrue
    (ConvertTo-AvdRotationTag $r).Length | Should -BeLessOrEqual 256
  }
  It 'refuses once the old hosts are being removed, or a second time' {
    { Get-AvdRotationRollback -State ([pscustomobject]@{ phase = 'Remove'; from = 'a'; to = 'b' }) -Now $now } | Should -Throw '*avdlz-image-previous*'
    { Get-AvdRotationRollback -State ([pscustomobject]@{ phase = 'Wait'; from = 'b'; to = 'a'; rollback = $true }) -Now $now } | Should -Throw '*already a rollback*'
  }
}
