#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Replaces the landing zone's session hosts blue/green with a new image version
  (build/specs/image-pipeline-spec.md section 6.5).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) in the repository folder. It moves through five phases and
  records where it is in the host pool's avdlz-rotation tag, so running it again continues where it
  stopped: a Cloud Shell disconnect costs nothing.

    Check   refuses a locked pool, an image that isn't a gallery version, the image the pool already
            runs, and too little vCPU quota for the new hosts beside the old ones
    Deploy  deploy.sh adds a new host generation (a or b) from the image; the old hosts are untouched.
            Ends when every new host is Available with every health check passing; then the pool's
            avdlz-image and avdlz-generation tags change
    Drain   the old hosts take no new sessions, and their users get a message
    Wait    each run reports the sessions left; after the deadline (default 72 hours), with
            -LogOffAtDeadline, a final notice and, 15 minutes later, sign-out
    Remove  the old session hosts and VMs are deleted (disks and NICs go with them)

  The image comes from -ImageId or the host pool's avdlz-image-next tag (set by promotion). Sizing,
  power settings and groups come from the last succeeded deployment, so the new hosts match the old.
  -Rollback before Remove swaps the generations back: the new hosts drain and are removed. After Remove,
  -Rollback rotates to the version the pool ran before (avdlz-image-previous).

  Not built yet: removing the old hosts' Entra ID and Intune device objects. They are listed, by name,
  to delete by hand; the in-host check that records their IDs is image pipeline step 4.

  Ends with the deployment portal's state line (stage rotation, status refused, waiting, done or failed).

.EXAMPLE
  ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -ImageId <gallery image version ID>

.EXAMPLE
  ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -Rollback
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  # A Compute Gallery image version ID. Default: the host pool's avdlz-image-next tag.
  [string] $ImageId,
  # Default: parameters/<environment>.bicepparam.
  [string] $ParameterFile,
  [ValidateRange(1, 720)][int] $DeadlineHours = 72,
  [switch] $LogOffAtDeadline,
  [switch] $Rollback,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRotation.psm1') -Force
$apiAvd = '2024-04-03'; $apiVm = '2024-07-01'; $apiTags = '2021-04-01'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $ParameterFile) { $ParameterFile = "parameters/$Environment.bicepparam" }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$now = [datetime]::UtcNow
$sub = "/subscriptions/$($ctx.Subscription.Id)"
# The portal's issue report redacts the subscription name in this header form (site/portal/report.js).
Write-Host "AVD host rotation - $NamePrefix-$Environment in '$($ctx.Subscription.Name)'" -ForegroundColor White
Write-Host '  Reading the host pool, its session hosts and the last deployment...' -ForegroundColor DarkGray
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment

$context = [ordered]@{ namePrefix = $lz.NamePrefix; environment = $Environment; parameterFile = $ParameterFile }
function Complete-Rotation([string] $Status, [int] $Code) {
  $state = Get-AvdPortalState -Stage rotation -Status $Status -Context $context
  $null = Write-AvdSummary
  Write-AvdPortalState $state
  exit $Code
}
if (-not $lz.HostPool) {
  Add-AvdCheckResult 'Rotation' 'Landing zone found' 'Fail' -Id 'rotation-lz' -Detail "No host pool in $($lz.ResourceGroups.ControlPlane)." -Remediation 'Check -NamePrefix and -Environment, and the subscription.'
  Complete-Rotation 'refused' 1
}
$poolId = $lz.HostPool.ResourceId

# deploy.sh takes the landing zone's name from the parameter file, so the file must name this pool.
$pfPath = if ([IO.Path]::IsPathRooted($ParameterFile)) { $ParameterFile } else { Join-Path $repo $ParameterFile }
$pfText = if (Test-Path $pfPath) { Get-Content $pfPath -Raw } else { '' }
$pfPrefix = if ($pfText -match "(?m)^param namePrefix = '([^']*)'") { $Matches[1].Replace('-', '').ToLower() } else { '' }
$pfEnv = if ($pfText -match "(?m)^param environmentName = '([^']*)'") { $Matches[1] } else { '' }
if ($pfPrefix -ne $lz.NamePrefix -or $pfEnv -ne $Environment) {
  Add-AvdCheckResult 'Rotation' 'Parameter file names this landing zone' 'Fail' -Id 'rotation-parameter-file' `
    -Detail "$ParameterFile deploys '$(if ($pfPrefix) { $pfPrefix } else { '?' })-$(if ($pfEnv) { $pfEnv } else { '?' })', not '$($lz.NamePrefix)-$Environment'." `
    -Remediation 'Pass -ParameterFile with the file this landing zone was deployed from.'
  Complete-Rotation 'refused' 1
}

function Get-PoolTag {
  $p = Invoke-AvdArm -Path "$($poolId)?api-version=$apiAvd"
  $t = @{}
  if ($p.tags) { foreach ($x in $p.tags.PSObject.Properties) { $t[$x.Name] = "$($x.Value)" } }
  $t
}
function Set-PoolTag {
  [CmdletBinding(SupportsShouldProcess)]
  param([hashtable] $Tags, [ValidateSet('Merge', 'Delete')][string] $Operation = 'Merge')
  if (-not $Tags.Count) { return }
  if ($PSCmdlet.ShouldProcess("host pool tags $($Tags.Keys -join ', ')", $Operation)) {
    Invoke-AvdArm -Method PATCH -Path "$poolId/providers/Microsoft.Resources/tags/default?api-version=$apiTags" -Body @{ operation = $Operation; properties = @{ tags = $Tags } } | Out-Null
  }
}
function Remove-PoolTag {
  [CmdletBinding(SupportsShouldProcess)]
  param([string[]] $Name)
  # Delete matches name and value, so pass the values the pool has now.
  $now = Get-PoolTag; $gone = @{}
  foreach ($n in $Name) { if ($now.ContainsKey($n)) { $gone[$n] = $now[$n] } }
  Set-PoolTag $gone 'Delete'
}
function Save-State($State) { Set-PoolTag @{ 'avdlz-rotation' = (ConvertTo-AvdRotationTag $State) } }

# The settings to keep come from the last succeeded deployment of this host pool, found by its output
# (not by name: another landing zone can share the parameter file name, and the demo deploys too).
$deployment = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Resources/deployments?api-version=2021-04-01" |
    Where-Object { "$($_.properties.provisioningState)" -eq 'Succeeded' -and "$($_.properties.outputs.hostPoolResourceId.value)" -eq $poolId }) |
  Sort-Object { [datetime]$_.properties.timestamp } -Descending | Select-Object -First 1
$params = if ($deployment) { $deployment.properties.parameters } else { $null }
$basePrefix = if ($params -and $params.sessionHostNamePrefix.value) { "$($params.sessionHostNamePrefix.value)" } else { "$($lz.NamePrefix)$($Environment.Substring(0, 1))sh".Substring(0, [Math]::Min(11, "$($lz.NamePrefix)$($Environment.Substring(0, 1))sh".Length)) }

function Read-SessionHost {
  @(Get-AvdArmList -Path "$poolId/sessionHosts?api-version=$apiAvd" | ForEach-Object {
      $vmId = "$($_.properties.resourceId)"
      $vm = ($vmId -split '/')[-1]
      $checks = @($_.properties.sessionHostHealthCheckResults | Where-Object { $_ })
      [pscustomobject]@{
        Path = "$($_.id)"; Name = ("$($_.name)" -split '/')[-1]; VmId = $vmId; VmName = $vm
        Generation = Get-AvdHostGeneration -VmName $vm -BasePrefix $basePrefix
        Available = "$($_.properties.status)" -eq 'Available'
        Healthy = -not @($checks | Where-Object { "$($_.healthCheckResult)" -ne 'HealthCheckSucceeded' }).Count
        AllowNewSession = [bool]$_.properties.allowNewSession
        Sessions = [int]$_.properties.sessions
      }
    })
}
# The rotation's own deployment: deploy.sh names it avdlz-<parameter file>-<time>, after deployAt.
function Get-RotationDeploymentState($State) {
  if (-not $State.deployAt) { return 'none' }
  $since = [datetime]::Parse($State.deployAt, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal).AddMinutes(-2)
  $base = [IO.Path]::GetFileNameWithoutExtension($ParameterFile)
  $d = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Resources/deployments?api-version=2021-04-01" |
      Where-Object { "$($_.name)" -like "avdlz-$base-*" -and [datetime]$_.properties.timestamp -ge $since }) |
    Sort-Object { [datetime]$_.properties.timestamp } -Descending | Select-Object -First 1
  switch ("$($d.properties.provisioningState)") {
    '' { 'none' } 'Succeeded' { 'succeeded' } { $_ -in 'Failed', 'Canceled' } { 'failed' } default { 'running' }
  }
}
# deploy.sh runs with Azure CLI, whose subscription is separate from Az PowerShell's: select the same one.
function Test-CliSubscription {
  $id = "$($ctx.Subscription.Id)"
  $out = & az account set --subscription $id 2>&1
  if ($LASTEXITCODE -ne 0) { return "az account set --subscription $id failed: $out" }
  $now = "$(& az account show --query id -o tsv 2>&1)".Trim()
  if ($now -ne $id) { return "Azure CLI is on subscription '$now', not '$id'." }
  $null
}
function Send-HostMessage($SessionHost, [string] $Title, [string] $Body) {
  foreach ($us in @(Get-AvdArmList -Path "$($SessionHost.Path)/userSessions?api-version=$apiAvd")) {
    $id = ("$($us.name)" -split '/')[-1]
    Invoke-AvdArm -Method POST -Path "$($SessionHost.Path)/userSessions/$id/sendMessage?api-version=$apiAvd" -Body @{ messageTitle = $Title; messageBody = $Body } | Out-Null
  }
}
function Set-GalleryInUse {
  [CmdletBinding(SupportsShouldProcess)]
  param([string] $Version, [switch] $Clear)
  # Image retention never deletes a version a pool uses (spec section 4.2). Best effort: the gallery may
  # be in a subscription this identity can only read.
  if (-not $Version -or -not $PSCmdlet.ShouldProcess((Get-AvdImageLabel $Version), 'Tag in use')) { return }
  $tag = @{ "avdlz-in-use-$Environment-$($lz.NamePrefix)" = 'true' }
  try { Invoke-AvdArm -Method PATCH -Path "$Version/providers/Microsoft.Resources/tags/default?api-version=$apiTags" -Body @{ operation = $(if ($Clear) { 'Delete' } else { 'Merge' }); properties = @{ tags = $tag } } | Out-Null }
  catch { Add-AvdCheckResult 'Rotation' "In-use tag on $(Get-AvdImageLabel $Version)" 'Warn' -Id 'rotation-in-use-tag' -Detail "$_" -Remediation "Set or clear the tag $($tag.Keys) on the version by hand, so image retention keeps or frees it." }
}

$tags = Get-PoolTag
$state = ConvertFrom-AvdRotationTag $tags['avdlz-rotation']
$hosts = Read-SessionHost
$context.from = ''; $context.to = ''

# ---------------------------------------------------------------- start, or roll back
if ($Rollback -and $state) {
  Write-AvdSection 'Rollback'
  $state = Get-AvdRotationRollback -State $state -Now $now
  # The original hosts take sessions again; the pool's tags go back to what they recorded before.
  foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.to)" -and -not $_.AllowNewSession })) {
    Write-Host "  Taking new sessions again on $($h.VmName)" -ForegroundColor DarkGray
    if ($PSCmdlet.ShouldProcess($h.VmName, 'Allow new sessions')) {
      Invoke-AvdArm -Method PATCH -Path "$($h.Path)?api-version=$apiAvd" -Body @{ properties = @{ allowNewSession = $true } } | Out-Null
    }
  }
  $back = @{}
  if ("$($state.to)") { $back['avdlz-generation'] = "$($state.to)" } else { Remove-PoolTag 'avdlz-generation' }
  if ($tags['avdlz-image-previous']) { $back['avdlz-image'] = $tags['avdlz-image-previous'] } else { Remove-PoolTag 'avdlz-image' }
  Set-PoolTag $back
  Save-State $state
  Add-AvdCheckResult 'Rotation' 'Rollback started' 'Pass' -Id 'rotation-rollback' -Detail "Generation $($state.from) drains and is removed; generation $(if ($state.to) { $state.to } else { 'none' }) takes sessions again."
}
elseif (-not $state) {
  Write-AvdSection 'Check'
  $current = "$($tags['avdlz-image'])"; $currentGen = "$($tags['avdlz-generation'])"
  if ($Rollback) {
    if (-not $tags['avdlz-image-previous']) {
      Add-AvdCheckResult 'Rotation' 'A version to roll back to' 'Fail' -Id 'rotation-image' -Detail 'No rotation in progress and no avdlz-image-previous on the host pool.' -Remediation 'Rotate to a validated version with -ImageId.'
      Complete-Rotation 'refused' 1
    }
    $ImageId = $tags['avdlz-image-previous']
  }
  elseif (-not $ImageId) { $ImageId = "$($tags['avdlz-image-next'])" }
  $old = @($hosts | Where-Object { $_.Generation -eq $currentGen })
  $count = if ($old.Count) { $old.Count } elseif ($params) { [int]$params.sessionHostCount.value } else { 0 }
  $vcpu = 0; $free = $null
  $size = if ($params) { "$($params.sessionHostVmSize.value)" } else { '' }
  if ($size -and $lz.Location) {
    try {
      $sku = Get-AzComputeResourceSku -Location $lz.Location -ErrorAction Stop | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $size } | Select-Object -First 1
      $vcpu = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value)
      $usage = @(Get-AzVMUsage -Location $lz.Location -ErrorAction Stop)
      $free = @(foreach ($n in @($sku.Family, 'cores')) { $u = $usage | Where-Object { $_.Name.Value -eq $n } | Select-Object -First 1; if ($u) { [int]$u.Limit - [int]$u.CurrentValue } }) | Measure-Object -Minimum | ForEach-Object Minimum
    }
    catch { $free = $null; Write-Host "  Could not read quota: $_" -ForegroundColor DarkYellow }
  }
  $checks = Get-AvdRotationCheck -PoolTags $tags -TargetImageId $ImageId -BasePrefix $basePrefix -HostCount $count -VcpuPerHost $vcpu -QuotaFree $free -Rollback:$Rollback
  if (-not $deployment) { $checks += [pscustomobject]@{ Id = 'rotation-deployment'; Status = 'Fail'; Check = 'A succeeded deployment to copy settings from'; Detail = "No succeeded deployment record with hostPoolResourceId $(($poolId -split '/')[-1])."; Remediation = 'Deploy the landing zone with deploy.sh first.'; Data = $null } }
  $cli = Test-CliSubscription
  if ($cli) { $checks += [pscustomobject]@{ Id = 'rotation-cli-subscription'; Status = 'Fail'; Check = 'Azure CLI on the same subscription'; Detail = $cli; Remediation = 'Run az login, then this again.'; Data = $null } }
  foreach ($c in $checks) { Add-AvdCheckResult 'Rotation' $c.Check $c.Status -Id $c.Id -Detail $c.Detail -Remediation $c.Remediation -Data $c.Data }
  if (@($checks | Where-Object Status -eq 'Fail').Count) { Complete-Rotation 'refused' 1 }
  $by = try { "$($ctx.Account.Id)" } catch { '' }
  $state = [pscustomobject]@{ phase = 'Deploy'; from = $currentGen; to = (Get-AvdNextHostGeneration -Current $currentGen); version = (Get-AvdImageLabel $ImageId); rollback = [bool]$Rollback; by = $by }
  $start = @{ 'avdlz-image-next' = $ImageId }
  if ($current) { $start['avdlz-image-previous'] = $current }
  Set-PoolTag $start
  Save-State $state
}
$context.from = "$($state.from)"; $context.to = "$($state.to)"; $context.version = "$($state.version)"; $context.rollback = [bool]$state.rollback

# ---------------------------------------------------------------- phases
$deployed = $false
for ($i = 0; $i -lt 20; $i++) {
  $tags = Get-PoolTag
  $hosts = Read-SessionHost
  $expected = if ($params -and $params.sessionHostCount.value) { [int]$params.sessionHostCount.value } else { 0 }
  if ($state.phase -eq 'Deploy') { $expected = [Math]::Max($expected, @($hosts | Where-Object { $_.Generation -eq "$($state.from)" }).Count) }
  $deployState = if ($state.phase -eq 'Deploy' -and -not $deployed) { Get-RotationDeploymentState $state } else { 'succeeded' }
  $step = Get-AvdRotationStep -State $state -SessionHosts $hosts -ExpectedCount $expected -Now $now -LogOffAtDeadline:$LogOffAtDeadline -DeploymentState $deployState
  $context.phase = "$($state.phase)"
  Write-Host "  [$($state.phase)] $($step.Detail)" -ForegroundColor DarkGray
  switch ($step.Action) {
    'deploy' {
      if ($deployed) {
        Add-AvdCheckResult 'Rotation' 'New hosts registered' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again in a few minutes; the hosts register after their run commands finish.'
        Complete-Rotation 'waiting' 0
      }
      $target = "$($tags['avdlz-image-next'])"
      $count = @($hosts | Where-Object { $_.Generation -eq "$($state.from)" }).Count
      $deployArgs = Get-AvdRotationDeployArgument -Parameters $params -ParameterFile $ParameterFile -Location $lz.Location -ImageId $target -Generation $state.to -HostCount $count
      Write-AvdSection 'Deploy'
      Write-Host "  Deploying generation $($state.to) from $(Get-AvdImageLabel $target) beside the current hosts (deploy.sh, 20-40 minutes)." -ForegroundColor White
      if ($PSCmdlet.ShouldProcess("generation $($state.to) of $($lz.BaseName)", 'Deploy')) {
        $cli = Test-CliSubscription
        if ($cli) {
          Add-AvdCheckResult 'Rotation' 'Azure CLI on the same subscription' 'Fail' -Id 'rotation-cli-subscription' -Detail $cli -Remediation 'Run az login, then this again (it continues).'
          Complete-Rotation 'failed' 1
        }
        # Recorded first, so a rerun after a disconnect finds this deployment instead of starting another.
        $state | Add-Member -NotePropertyName deployAt -NotePropertyValue ([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mmZ')) -Force
        Save-State $state
        Push-Location $repo
        try { & bash ./scripts/deploy/deploy.sh @deployArgs | Out-Host; $code = $LASTEXITCODE }
        finally { Pop-Location }
        if ($code -ne 0) {
          Add-AvdCheckResult 'Rotation' 'Deploy the new hosts' 'Fail' -Id 'rotation-deploy' -Detail "deploy.sh exited with $code; the old hosts are untouched." -Remediation 'Fix what deploy.sh reported and run this again (it continues), or -Rollback.'
          Complete-Rotation 'failed' 1
        }
      }
      $deployed = $true
    }
    'wait-hosts' {
      Add-AvdCheckResult 'Rotation' 'New hosts ready' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again in a few minutes.'
      Complete-Rotation 'waiting' 0
    }
    'drain' {
      if ($state.phase -eq 'Deploy') {
        # The new hosts are ready: the pool now records them (spec section 6.1, red-team C2).
        Set-PoolTag @{ 'avdlz-image' = "$($tags['avdlz-image-next'])"; 'avdlz-generation' = "$($state.to)" }
        Set-GalleryInUse "$($tags['avdlz-image-next'])"
        Add-AvdCheckResult 'Rotation' 'New hosts ready' 'Pass' -Id 'rotation-deployed' -Detail $step.Detail
        $state.phase = 'Drain'; Save-State $state
        continue
      }
      Write-AvdSection 'Drain'
      foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.from)" })) {
        Write-Host "  Draining $($h.VmName) ($($h.Sessions) session(s))" -ForegroundColor DarkGray
        if ($PSCmdlet.ShouldProcess($h.VmName, 'Drain')) {
          Invoke-AvdArm -Method PATCH -Path "$($h.Path)?api-version=$apiAvd" -Body @{ properties = @{ allowNewSession = $false } } | Out-Null
          Send-HostMessage $h 'Desktop update' 'This desktop is being replaced with an updated one. Save your work and sign out when convenient; you will reconnect to an updated desktop.'
        }
      }
      $state.phase = 'Wait'
      $state | Add-Member -NotePropertyName deadline -NotePropertyValue ($now.AddHours($(if ($state.version -eq 'rollback') { 1 } else { $DeadlineHours })).ToString('yyyy-MM-ddTHH:mmZ')) -Force
      Save-State $state
      Add-AvdCheckResult 'Rotation' 'Old hosts draining' 'Pass' -Id 'rotation-drained' -Detail "Deadline $($state.deadline) UTC."
    }
    'wait-sessions' {
      $left = (@($hosts | Where-Object { $_.Generation -eq "$($state.from)" }) | Measure-Object -Property Sessions -Sum).Sum
      $context.sessionsLeft = [int]$left
      Add-AvdCheckResult 'Rotation' 'Sessions left on the old hosts' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again later; it continues from here.' -Data @{ sessions = [int]$left; deadline = "$($state.deadline)" }
      Complete-Rotation 'waiting' 0
    }
    'notify' {
      foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.from)" -and $_.Sessions })) {
        if ($PSCmdlet.ShouldProcess($h.VmName, 'Final notice')) { Send-HostMessage $h 'Signing out in 15 minutes' 'This desktop is being replaced. Save your work now: you will be signed out in 15 minutes, and can sign in again straight away.' }
      }
      $state | Add-Member -NotePropertyName notice -NotePropertyValue ($now.ToString('yyyy-MM-ddTHH:mmZ')) -Force
      Save-State $state
      Add-AvdCheckResult 'Rotation' 'Final notice sent' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again with -LogOffAtDeadline after 15 minutes.'
      Complete-Rotation 'waiting' 0
    }
    'logoff' {
      foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.from)" -and $_.Sessions })) {
        foreach ($us in @(Get-AvdArmList -Path "$($h.Path)/userSessions?api-version=$apiAvd")) {
          $id = ("$($us.name)" -split '/')[-1]
          if ($PSCmdlet.ShouldProcess("$($h.VmName) session $id", 'Sign out')) { Invoke-AvdArm -Method DELETE -Path "$($h.Path)/userSessions/$($id)?api-version=$apiAvd&force=true" | Out-Null }
        }
      }
      Add-AvdCheckResult 'Rotation' 'Sessions signed out' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again in a few minutes to remove the old hosts.'
      Complete-Rotation 'waiting' 0
    }
    'remove' {
      if ($state.phase -eq 'Wait') { $state.phase = 'Remove'; Save-State $state }
      Write-AvdSection 'Remove'
      # The retiring generation, from its session hosts and from the VMs themselves: a rerun after an
      # interrupted removal still finds a VM whose session host is already gone.
      $gone = @($hosts | Where-Object { $_.Generation -eq "$($state.from)" })
      $vms = @(Get-AvdArmList -Path "$($lz.ResourceGroupIds.Hosts)/providers/Microsoft.Compute/virtualMachines?api-version=$apiVm" |
          Where-Object { (Get-AvdHostGeneration -VmName "$($_.name)" -BasePrefix $basePrefix) -eq "$($state.from)" -and $gone.VmName -notcontains "$($_.name)" })
      $gone += @($vms | ForEach-Object { [pscustomobject]@{ Path = $null; VmId = "$($_.id)"; VmName = "$($_.name)" } })
      foreach ($h in $gone) {
        Write-Host "  Removing $($h.VmName): $(if ($h.Path) { 'session host, then ' })VM (its disk and NIC go with it)" -ForegroundColor DarkGray
        if ($PSCmdlet.ShouldProcess($h.VmName, 'Remove')) {
          if ($h.Path) { Invoke-AvdArm -Method DELETE -Path "$($h.Path)?api-version=$apiAvd&force=true" | Out-Null }
          if ($h.VmId) { Invoke-AvdArm -Method DELETE -Path "$($h.VmId)?api-version=$apiVm" -AllowNotFound | Out-Null }
        }
      }
      if ($WhatIfPreference) { Complete-Rotation 'waiting' 0 }
      # "Removed" means gone: wait for each VM delete, up to 15 minutes (lesson 0006).
      foreach ($h in @($gone | Where-Object VmId)) {
        for ($n = 0; $n -lt 60 -and (Invoke-AvdArm -Path "$($h.VmId)?api-version=$apiVm" -AllowNotFound); $n++) { Start-Sleep -Seconds 15 }
      }
      $left = @($gone | Where-Object { $_.VmId -and (Invoke-AvdArm -Path "$($_.VmId)?api-version=$apiVm" -AllowNotFound) })
      if ($left.Count) {
        Add-AvdCheckResult 'Rotation' 'Old VMs deleted' 'Warn' -Id 'rotation-waiting' -Detail "Still deleting: $($left.VmName -join ', ')." -Remediation 'Run this again to finish.'
        # The next run no longer sees the hosts deleted now, so their device names are reported here.
        $done = @($gone | Where-Object { $left.VmName -notcontains $_.VmName })
        if ($done.Count) {
          Add-AvdCheckResult 'Rotation' 'Device objects of the removed hosts' 'Warn' -Id 'devices-left' -Detail "Entra ID and Intune still hold devices named $($done.VmName -join ', ')." `
            -Remediation 'Delete them in Entra ID and Intune once you have checked they are these hosts; automatic removal by ID comes with the in-host check (image pipeline step 4).' -Data @{ devices = @($done.VmName) }
        }
        Complete-Rotation 'waiting' 0
      }
      $tags = Get-PoolTag
      # The version the removed hosts ran is no longer in use by this pool.
      # A reversal (version 'rollback') removes the hosts of avdlz-image-next; any other rotation, including
      # one back to the previous version, removes the hosts of avdlz-image-previous.
      Set-GalleryInUse "$($tags[$(if ($state.version -eq 'rollback') { 'avdlz-image-next' } else { 'avdlz-image-previous' })])" -Clear
      Remove-PoolTag 'avdlz-rotation', 'avdlz-image-next'
      Add-AvdCheckResult 'Rotation' 'Old hosts removed' 'Pass' -Id 'rotation-removed' -Detail "$($gone.Count) host(s) of generation $(if ($state.from) { $state.from } else { 'none' }) removed."
      if ($gone.Count) {
        Add-AvdCheckResult 'Rotation' 'Device objects of the removed hosts' 'Warn' -Id 'devices-left' -Detail "Entra ID and Intune still hold devices named $($gone.VmName -join ', ')." `
          -Remediation 'Delete them in Entra ID and Intune once you have checked they are these hosts; automatic removal by ID comes with the in-host check (image pipeline step 4).' -Data @{ devices = @($gone.VmName) }
      }
      $context.phase = 'Done'
      Complete-Rotation 'done' 0
    }
    default { $context.phase = 'Done'; Complete-Rotation 'done' 0 }
  }
}
Add-AvdCheckResult 'Rotation' 'Progress' 'Warn' -Id 'rotation-waiting' -Detail "Stopped after $i steps at phase $($state.phase)." -Remediation 'Run this again.'
Complete-Rotation 'waiting' 0
