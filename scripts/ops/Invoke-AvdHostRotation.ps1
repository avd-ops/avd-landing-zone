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

  -StopBefore pauses once at a cutover point: Drain (the new hosts are ready, the old ones still take
  every session; cut over later, in a maintenance window) or Remove (the old hosts are drained and empty,
  kept so a rollback still has them). The rotation tag records it, so reruns in between keep it without
  the switch; the run after the pause continues. While paused before Drain the new hosts follow the
  scaling plan and auto shutdown like any host, and the cutover waits until they are Available and open.

  Not built yet: removing the old hosts' Entra ID and Intune device objects. They are listed, by name,
  to delete by hand; the in-host check that records their IDs is image pipeline step 4.

  Ends with the deployment portal's state line (stage rotation, status refused, waiting, done or failed).

.EXAMPLE
  ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -ImageId <gallery image version ID>

.EXAMPLE
  ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -Rollback

.EXAMPLE
  ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix avdlz -Environment dev -ImageId <gallery image version ID> -StopBefore Drain
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
  # Pause once before the old hosts drain, or before they are removed; the next run after the pause continues.
  [ValidateSet('Drain', 'Remove')][string] $StopBefore,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRotation.psm1') -Force
$apiAvd = '2024-04-03'; $apiVm = '2024-07-01'; $apiTags = '2021-04-01'
# The scaling plan's exclusion tag (bicep/modules/controlPlane.bicep): without it, ramp-up reopens drained hosts.
$exclusionTag = 'avd-scaling-exclude'; $exclusionValue = 'rotation'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $ParameterFile) { $ParameterFile = "parameters/$Environment.bicepparam" }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Clear-AvdCheckResult
$now = [datetime]::UtcNow
$sub = "/subscriptions/$($ctx.Subscription.Id)"
$context = [ordered]@{ namePrefix = $NamePrefix; environment = $Environment; parameterFile = $ParameterFile }
function Complete-Rotation([string] $Status, [int] $Code) {
  $state = Get-AvdPortalState -Stage rotation -Status $Status -Context $context
  $null = Write-AvdSummary
  Write-AvdPortalState $state
  exit $Code
}
# An Azure error at any step, the first reads included, ends with the rotation's own state line, not the last
# deploy.sh one (lesson 0012: report what Azure said). The state on the pool is untouched: a rerun continues.
trap {
  $at = if ($state.phase) { "$($state.phase)" } else { 'Check' }
  Add-AvdCheckResult 'Rotation' "Phase $at" 'Fail' -Id 'rotation-error' -Detail "$_" -Remediation 'Fix what Azure reported and run this again; it continues from the same phase.'
  $context.phase = $at
  Complete-Rotation 'failed' 1
}
# The portal's issue report redacts the subscription name in this header form (site/portal/report.js).
Write-Host "AVD host rotation - $NamePrefix-$Environment in '$($ctx.Subscription.Name)'" -ForegroundColor White
Write-Host '  Reading the host pool, its session hosts and the last deployment...' -ForegroundColor DarkGray
$lz = Get-AvdLandingZone -NamePrefix $NamePrefix -Environment $Environment
$context.namePrefix = $lz.NamePrefix
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
        # Healthy means checks were reported and every one passed: no results is not a pass.
        Healthy = $checks.Count -gt 0 -and -not @($checks | Where-Object { "$($_.healthCheckResult)" -ne 'HealthCheckSucceeded' }).Count
        AllowNewSession = [bool]$_.properties.allowNewSession
        Sessions = [int]$_.properties.sessions
      }
    })
}
# The rotation's own deployment, by the name it gave deploy.sh (state key deploy): never another one's.
function Get-RotationDeploymentState($State) {
  if (-not $State.deploy) { return 'none' }
  $d = Invoke-AvdArm -Path "$sub/providers/Microsoft.Resources/deployments/$($State.deploy)?api-version=2021-04-01" -AllowNotFound
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
# Drain or reopen a host, keeping the scaling plan out of a drained one (as Invoke-AvdPowerAction.ps1 does).
# Delete matches name and value, so a reopen leaves an auto shutdown lock's exclusion in place.
function Set-HostDrain {
  [CmdletBinding(SupportsShouldProcess)]
  param($SessionHost, [bool] $Drain)
  if (-not $PSCmdlet.ShouldProcess($SessionHost.VmName, $(if ($Drain) { 'Drain, and exclude from the scaling plan' } else { 'Allow new sessions, and include in the scaling plan' }))) { return $false }
  Invoke-AvdArm -Method PATCH -Path "$($SessionHost.Path)?api-version=$apiAvd" -Body @{ properties = @{ allowNewSession = (-not $Drain) } } | Out-Null
  if ($SessionHost.VmId) {
    Invoke-AvdArm -Method PATCH -Path "$($SessionHost.VmId)/providers/Microsoft.Resources/tags/default?api-version=$apiTags" -Body @{ operation = $(if ($Drain) { 'Merge' } else { 'Delete' }); properties = @{ tags = @{ $exclusionTag = $exclusionValue } } } | Out-Null
  }
  $true
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
  # One marker per pool: a shared gallery can serve same-named landing zones in other subscriptions.
  $tag = @{ "avdlz-in-use-$Environment-$($lz.NamePrefix)-$($ctx.Subscription.Id)" = 'true' }
  try { Invoke-AvdArm -Method PATCH -Path "$Version/providers/Microsoft.Resources/tags/default?api-version=$apiTags" -Body @{ operation = $(if ($Clear) { 'Delete' } else { 'Merge' }); properties = @{ tags = $tag } } | Out-Null }
  catch { Add-AvdCheckResult 'Rotation' "In-use tag on $(Get-AvdImageLabel $Version)" 'Warn' -Id 'rotation-in-use-tag' -Detail "$_" -Remediation "Set or clear the tag $($tag.Keys) on the version by hand, so image retention keeps or frees it." }
}

$tags = Get-PoolTag
$state = ConvertFrom-AvdRotationTag $tags['avdlz-rotation']
# The names are told apart by the prefix the rotation started with, even if a later deployment changed it.
if ($state -and $state.prefix) { $basePrefix = "$($state.prefix)" }
$hosts = Read-SessionHost
$context.from = ''; $context.to = ''

# ---------------------------------------------------------------- start, or roll back
# Auto shutdown's lock (decision 0011) wins over a rotation in progress too: no host reopens or deploys.
if ($state -and $tags['avdlz-power-lock']) {
  Add-AvdCheckResult 'Rotation' 'Host pool not locked by auto shutdown' 'Fail' -Id 'rotation-locked' -Detail "Locked: $($tags['avdlz-power-lock']). The rotation stays at phase $($state.phase)." -Remediation 'Run Resume first (Invoke-AvdPowerAction.ps1 -Action Resume), then this again; it continues.'
  $context.from = "$($state.from)"; $context.to = "$($state.to)"; $context.phase = "$($state.phase)"
  Complete-Rotation 'refused' 1
}
# -Rollback again on a rollback in progress just continues it.
if ($Rollback -and $state -and -not $state.rollback) {
  Write-AvdSection 'Rollback'
  # A deployment still running would go on creating the hosts the rollback removes.
  if ($state.phase -eq 'Deploy' -and (Get-RotationDeploymentState $state) -eq 'running') {
    Add-AvdCheckResult 'Rotation' 'Deployment ended before rolling back' 'Warn' -Id 'rotation-waiting' -Detail "Deployment $($state.deploy) of generation $($state.to) is still running in Azure." -Remediation 'Run this with -Rollback again once it ends.'
    # The portal's next command keeps -Rollback, or the rerun would carry on forward.
    $context.from = "$($state.from)"; $context.to = "$($state.to)"; $context.phase = "$($state.phase)"; $context.rollbackPending = $true
    Complete-Rotation 'waiting' 0
  }
  $state = Get-AvdRotationRollback -State $state -Now $now
  # Recorded before anything changes: the Drain phase that follows restores the original hosts and the
  # pool's tags, and a rerun after a disconnect repeats it.
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
  # The same count the deployment uses: as many as the landing zone is meant to have, or more if more are registered.
  $count = [Math]::Max($old.Count, $(if ($params -and $params.sessionHostCount.value) { [int]$params.sessionHostCount.value } else { 0 }))
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
  $state = [pscustomobject]@{ phase = 'Deploy'; from = $currentGen; to = (Get-AvdNextHostGeneration -Current $currentGen); version = (Get-AvdImageLabel $ImageId); hours = $DeadlineHours; prefix = $basePrefix; rollback = [bool]$Rollback; by = $by }
  $start = @{ 'avdlz-image-next' = $ImageId }
  if ($current) { $start['avdlz-image-previous'] = $current }
  Set-PoolTag $start
  Save-State $state
}
$context.from = "$($state.from)"; $context.to = "$($state.to)"; $context.version = "$($state.version)"; $context.rollback = [bool]$state.rollback

# -StopBefore is recorded on the rotation, so the runs before the pause keep it without the switch.
if ($StopBefore) {
  if (Test-AvdRotationPastStop -State $state -StopBefore $StopBefore) {
    Add-AvdCheckResult 'Rotation' "Pause before $StopBefore" 'Fail' -Id 'rotation-stop' -Detail "The rotation is already in phase $($state.phase), past $StopBefore." -Remediation 'Run this again without -StopBefore; it continues.'
    $context.phase = "$($state.phase)"
    Complete-Rotation 'refused' 1
  }
  if ("$($state.stop)" -ne $StopBefore) { $state | Add-Member -NotePropertyName stop -NotePropertyValue $StopBefore -Force; Save-State $state }
}

# ---------------------------------------------------------------- phases
$deployed = $false
for ($i = 0; $i -lt 20; $i++) {
  $tags = Get-PoolTag
  $hosts = Read-SessionHost
  $expected = if ($params -and $params.sessionHostCount.value) { [int]$params.sessionHostCount.value } else { 0 }
  if ($state.phase -eq 'Deploy') { $expected = [Math]::Max($expected, @($hosts | Where-Object { $_.Generation -eq "$($state.from)" }).Count) }
  # A Resume after a budget lock reopens every host: the retiring generation drains again, without a
  # new message, deadline or notice. Before the next step is chosen, and from a fresh read: a user who
  # connected while it was open must count as a session, not be removed with the host.
  if ($state.phase -in 'Wait', 'Remove') {
    $reopened = @($hosts | Where-Object { $_.Generation -eq "$($state.from)" -and $_.AllowNewSession })
    foreach ($h in $reopened) {
      Write-Host "  Draining $($h.VmName) again (it was reopened)" -ForegroundColor DarkYellow
      $null = Set-HostDrain $h $true
    }
    if ($reopened.Count -and -not $WhatIfPreference) { $hosts = Read-SessionHost }
  }
  $deployState = if ($state.phase -eq 'Deploy' -and -not $deployed) { Get-RotationDeploymentState $state } else { 'succeeded' }
  $step = Get-AvdRotationStep -State $state -SessionHosts $hosts -ExpectedCount $expected -Now $now -LogOffAtDeadline:$LogOffAtDeadline -DeploymentState $deployState
  $context.phase = "$($state.phase)"
  Write-Host "  [$($state.phase)] $($step.Detail)" -ForegroundColor DarkGray
  if (Test-AvdRotationPause -State $state -Step $step) {
    $context.stopBefore = "$($state.stop)"
    Add-AvdCheckResult 'Rotation' "Paused before $($state.stop)" 'Warn' -Id 'rotation-paused' -Detail $step.Detail `
      -Remediation "Run this again to continue from phase $($state.phase)$(if ($state.rollback) { ' (the rollback)' } else { ', or with -Rollback to undo the rotation' })."
    # The pause is spent: the next run continues.
    $state.PSObject.Properties.Remove('stop'); Save-State $state
    Complete-Rotation 'waiting' 0
  }
  switch ($step.Action) {
    'deploy' {
      if ($deployed) {
        Add-AvdCheckResult 'Rotation' 'New hosts registered' 'Warn' -Id 'rotation-waiting' -Detail $step.Detail -Remediation 'Run this again in a few minutes; the hosts register after their run commands finish.'
        Complete-Rotation 'waiting' 0
      }
      $target = "$($tags['avdlz-image-next'])"
      # As many hosts as the landing zone is meant to have, even if an original one lost its registration.
      $count = $expected
      $name = "avdlz-$([IO.Path]::GetFileNameWithoutExtension($ParameterFile))-rot$($state.to)-$([datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
      $deployArgs = Get-AvdRotationDeployArgument -Parameters $params -ParameterFile $ParameterFile -Location $lz.Location -ImageId $target -Generation $state.to -HostCount $count -DeploymentName $name
      Write-AvdSection 'Deploy'
      Write-Host "  Deploying generation $($state.to) from $(Get-AvdImageLabel $target) beside the current hosts (deploy.sh, 20-40 minutes)." -ForegroundColor White
      if ($PSCmdlet.ShouldProcess("generation $($state.to) of $($lz.BaseName)", 'Deploy')) {
        $cli = Test-CliSubscription
        if ($cli) {
          Add-AvdCheckResult 'Rotation' 'Azure CLI on the same subscription' 'Fail' -Id 'rotation-cli-subscription' -Detail $cli -Remediation 'Run az login, then this again (it continues).'
          Complete-Rotation 'failed' 1
        }
        # Recorded first, so a rerun after a disconnect finds this deployment instead of starting another.
        $state | Add-Member -NotePropertyName deploy -NotePropertyValue $name -Force
        Save-State $state
        # Settings the parameter file reads from the environment, as the last deployment had them: a fresh
        # Cloud Shell would otherwise drop them. An operator's own value wins.
        $setEnv = @(foreach ($e in (Get-AvdRotationEnvironment -Parameters $params).GetEnumerator()) {
            if (-not [Environment]::GetEnvironmentVariable($e.Key)) { [Environment]::SetEnvironmentVariable($e.Key, $e.Value); $e.Key }
          })
        Push-Location $repo
        try { & bash ./scripts/deploy/deploy.sh @deployArgs | Out-Host; $code = $LASTEXITCODE }
        finally { Pop-Location; foreach ($k in $setEnv) { [Environment]::SetEnvironmentVariable($k, $null) } }
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
      if ($state.version -eq 'rollback') {
        # The original hosts take sessions again, and the pool's tags go back to them (pool image: the
        # version before the rotation). Repeated as is if a rerun finds the rollback still in Drain.
        foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.to)" })) {
          Write-Host "  Taking new sessions again on $($h.VmName)" -ForegroundColor DarkGray
          $null = Set-HostDrain $h $false
        }
        $back = @{}
        if ("$($state.to)") { $back['avdlz-generation'] = "$($state.to)" }
        if ($tags['avdlz-image-previous']) { $back['avdlz-image'] = $tags['avdlz-image-previous'] }
        Set-PoolTag $back
        Remove-PoolTag @(if (-not "$($state.to)") { 'avdlz-generation' }; if (-not $tags['avdlz-image-previous']) { 'avdlz-image' })
        # The new hosts drain only once the original ones can serve: a scheduled stop may have deallocated them.
        $orig = @($hosts | Where-Object { $_.Generation -eq "$($state.to)" })
        $down = @($orig | Where-Object { -not ($_.Available -and $_.Healthy) })
        if ($down.Count -or -not $orig.Count) {
          Add-AvdCheckResult 'Rotation' 'Original hosts ready to take sessions' 'Warn' -Id 'rotation-waiting' -Detail "$(if ($orig.Count) { "Not Available with every health check passing: $($down.VmName -join ', ')." } else { 'No host of the original generation is left.' }) The new hosts keep taking sessions until then." `
            -Remediation 'Start or repair the original hosts (az vm start), then run this again; the rollback continues.'
          Complete-Rotation 'waiting' 0
        }
      }
      foreach ($h in @($hosts | Where-Object { $_.Generation -eq "$($state.from)" })) {
        Write-Host "  Draining $($h.VmName) ($($h.Sessions) session(s))" -ForegroundColor DarkGray
        if (Set-HostDrain $h $true) {
          Send-HostMessage $h 'Desktop update' 'This desktop is being replaced with an updated one. Save your work and sign out when convenient; you will reconnect to an updated desktop.'
        }
      }
      $state.phase = 'Wait'
      # From now, after the deployment and the messages, to the second: users get the whole drain period.
      $state | Add-Member -NotePropertyName deadline -NotePropertyValue ([datetime]::UtcNow.AddHours($(if ($state.version -eq 'rollback') { 1 } elseif ($state.hours) { [int]$state.hours } else { $DeadlineHours })).ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
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
      # When the last notice went out, to the second: sign-out waits the full notice from then.
      $state | Add-Member -NotePropertyName notice -NotePropertyValue ([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
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
      # A notice sent during Wait is spent: anyone found on a host later gets a notice of their own.
      if ($state.phase -eq 'Wait') { $state.phase = 'Remove'; $state | Add-Member -NotePropertyName notice -NotePropertyValue $null -Force; Save-State $state }
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
