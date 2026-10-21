#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Blue/green host rotation (build/specs/image-pipeline-spec.md section 6.5), as pure functions that take
  data read from Azure and return data, tested offline (build/tests/Rotation.Tests.ps1).
  Invoke-AvdHostRotation.ps1 reads Azure, calls these, and makes the changes they decide.

  The host pool's tags are the state:
    avdlz-image, avdlz-generation  what the pool's hosts run (set at the end of Deploy)
    avdlz-image-next               the version promotion asked for
    avdlz-image-previous           what the pool ran before this rotation, for rolling back
    avdlz-rotation                 the rotation in progress: compact JSON, at most 256 characters
#>

$script:Phases = @('Check', 'Deploy', 'Drain', 'Wait', 'Remove', 'Done')
$script:VersionId = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+/versions/[0-9]+\.[0-9]+\.[0-9]+$'

function Get-AvdImageLabel {
  <# A short name for an image: the gallery version (2026.1101.1), or 'marketplace' for none. #>
  [CmdletBinding()]
  param([AllowEmptyString()][string] $ImageId)
  if (-not $ImageId) { return 'marketplace' }
  ($ImageId -split '/')[-1]
}

function Get-AvdNextHostGeneration {
  <# The generation a rotation deploys: a after none or b, b after a. #>
  [CmdletBinding()]
  param([AllowEmptyString()][ValidateSet('', 'a', 'b')][string] $Current)
  if ($Current -eq 'a') { 'b' } else { 'a' }
}

function Get-AvdGenerationPrefix {
  <# The VM name prefix of a generation, as bicep/main.bicep computes it (hostNamePrefix). #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $BasePrefix, [AllowEmptyString()][ValidateSet('', 'a', 'b')][string] $Generation)
  if (-not $Generation) { return $BasePrefix }
  $BasePrefix.Substring(0, [Math]::Min(10, $BasePrefix.Length)) + $Generation
}

function Test-AvdGenerationNameClash {
  <# True when a generation's names would equal the original names: an 11-character prefix ending in a or b. #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $BasePrefix)
  foreach ($g in 'a', 'b') { if ((Get-AvdGenerationPrefix -BasePrefix $BasePrefix -Generation $g) -eq $BasePrefix) { return $true } }
  $false
}

function Get-AvdHostGeneration {
  <#
    Which generation a session host belongs to, from its VM name: '', 'a' or 'b', or $null when the
    name matches none (a host someone added by hand). Session host names are <pool>/<fqdn>; pass the VM name.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string] $VmName, [Parameter(Mandatory)][string] $BasePrefix)
  foreach ($g in 'a', 'b', '') {
    if ($VmName -match ('^{0}-\d{{3}}$' -f [regex]::Escape((Get-AvdGenerationPrefix -BasePrefix $BasePrefix -Generation $g)))) { return $g }
  }
  $null
}

function ConvertTo-AvdRotationTag {
  <# The avdlz-rotation tag value: compact JSON. Azure allows 256 characters, so long values are cut. #>
  [CmdletBinding()]
  param([Parameter(Mandatory)] $State)
  $o = [ordered]@{}
  foreach ($k in 'phase', 'from', 'to', 'version', 'deadline', 'notice', 'deploy', 'hours', 'prefix', 'rollback', 'by') {
    $v = if ($State -is [System.Collections.IDictionary]) { $State[$k] } else { $State.$k }
    # The deployment's name is only needed while deploying; dropping it later keeps room for the notice.
    if ($k -eq 'deploy' -and "$(if ($State -is [System.Collections.IDictionary]) { $State['phase'] } else { $State.phase })" -ne 'Deploy') { continue }
    if ($null -ne $v -and "$v" -ne '') { $o[$k] = if ($v -is [bool]) { $v } else { "$v" } }
  }
  if ($o.by -and $o.by.Length -gt 40) { $o.by = $o.by.Substring(0, 40) }
  $json = $o | ConvertTo-Json -Compress
  # Who started the rotation is the one field nothing reads back: it gives way first, so long version
  # numbers and deployment names still fit.
  if ($json.Length -gt 256 -and $o.by) {
    $keep = $o.by.Length - ($json.Length - 256)
    if ($keep -ge 8) { $o.by = $o.by.Substring(0, $keep) } else { $o.Remove('by') }
    $json = $o | ConvertTo-Json -Compress
  }
  if ($json.Length -gt 256) { throw "The rotation state is $($json.Length) characters; a tag holds 256." }
  $json
}

function ConvertFrom-AvdRotationTag {
  <# The rotation in progress, from the avdlz-rotation tag, or $null when none (or unreadable). #>
  [CmdletBinding()]
  param([AllowEmptyString()][string] $Value)
  if (-not $Value) { return $null }
  try { $o = $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return $null }
  if (-not $o -or $o.phase -notin $script:Phases) { return $null }
  $o.rollback = [bool]$o.rollback
  # ConvertFrom-Json turns timestamps with seconds into dates; keep them as the UTC text that was written.
  foreach ($k in 'deadline', 'notice') { if ($o[$k] -is [datetime]) { $o[$k] = $o[$k].ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } }
  [pscustomobject]$o
}

function Get-AvdRotationDeployArgument {
  <#
    deploy.sh flags that keep the landing zone as it is while the rotation adds hosts: the sizing and
    power of the last succeeded deployment, the groups by object ID (no owner check), the image and
    generation, and --rotation. Without them a redeploy would fall back to the parameter file's values.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Parameters,      # the deployment record's properties.parameters
    [Parameter(Mandatory)][string] $ParameterFile,
    [Parameter(Mandatory)][string] $Location,
    [AllowEmptyString()][string] $ImageId,
    [Parameter(Mandatory)][ValidateSet('a', 'b')][string] $Generation,
    [int] $HostCount,
    # The deployment's name, so the rotation can find exactly this deployment again.
    [string] $DeploymentName
  )
  $values = @{}
  foreach ($x in $Parameters.PSObject.Properties) { if ($null -ne $x.Value -and $x.Value.PSObject.Properties['value']) { $values[$x.Name] = $x.Value.value } }
  $v = { param($n) $values[$n] }
  $a = [System.Collections.Generic.List[string]]::new()
  $a.AddRange([string[]]@('-p', $ParameterFile, '-l', $Location))
  if (& $v 'avdUsersGroupObjectId') { $a.AddRange([string[]]@('--users-group', (& $v 'avdUsersGroupObjectId'))) }
  if (& $v 'avdAdminsGroupObjectId') { $a.AddRange([string[]]@('--admins-group', (& $v 'avdAdminsGroupObjectId'))) }
  $count = if ($HostCount -gt 0) { $HostCount } else { & $v 'sessionHostCount' }
  if ($null -ne $count) { $a.AddRange([string[]]@('--hosts', "$count")) }
  foreach ($pair in @(@('sessionHostVmSize', '--vm-size'), @('maxSessionLimit', '--max-sessions'), @('profileShareQuotaGiB', '--profile-quota'))) {
    $x = & $v $pair[0]; if ($null -ne $x -and "$x" -ne '') { $a.AddRange([string[]]@($pair[1], "$x")) }
  }
  $auto = & $v 'enableAutoShutdown'; $time = & $v 'autoShutdownTime'
  # A deployment made with --auto-shutdown none records an empty time, not enableAutoShutdown false.
  if ($auto -eq $false -or ($values.ContainsKey('autoShutdownTime') -and -not "$time")) { $a.AddRange([string[]]@('--auto-shutdown', 'none')) }
  elseif ($time) { $a.AddRange([string[]]@('--auto-shutdown', "$time")) }
  $svc = & $v 'startVmOnConnect'
  if ($null -ne $svc) { $a.AddRange([string[]]@('--start-vm-on-connect', "$svc".ToLower())) }
  if ($ImageId) { $a.AddRange([string[]]@('--image-id', $ImageId)) }
  $a.AddRange([string[]]@('--generation', $Generation, '--rotation'))
  if ($DeploymentName) { $a.AddRange([string[]]@('--deployment-name', $DeploymentName)) }
  , $a.ToArray()
}

function Get-AvdRotationEnvironment {
  <#
    The environment variables the parameter files read for settings deploy.sh has no flag for, as the last
    deployment had them (its record's properties.parameters). Secrets and the values deploy.sh sets itself
    (the runbook URI, image, generation and pool tags) are never among them.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Parameters)
  $values = @{}
  foreach ($x in $Parameters.PSObject.Properties) { if ($null -ne $x.Value -and $x.Value.PSObject.Properties['value']) { $values[$x.Name] = $x.Value.value } }
  $e = [ordered]@{}
  if ("$($values['recoveryLocation'])") { $e['AVD_RECOVERY_LOCATION'] = "$($values['recoveryLocation'])" }
  if ($values['deployImageBuildSubnets'] -eq $true) { $e['AVD_IMAGE_BUILD_SUBNETS'] = 'true' }
  $mail = @($values['alertEmailAddresses'] | Where-Object { $_ })
  if ($mail.Count -eq 1) { $e['AVD_ALERT_EMAIL'] = "$($mail[0])" }
  if ([int]$values['monthlyBudgetAmount'] -gt 0) { $e['AVD_MONTHLY_BUDGET'] = "$([int]$values['monthlyBudgetAmount'])" }
  $e
}

function Get-AvdRotationCheck {
  <#
    The Check phase: whether a rotation may start. Returns results (Id, Status Pass|Fail|Warn, Check,
    Detail, Remediation, Data). Any Fail stops the rotation before anything changes.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable] $PoolTags,
    [AllowEmptyString()][string] $TargetImageId,
    [Parameter(Mandatory)][string] $BasePrefix,
    [int] $HostCount,
    [int] $VcpuPerHost,
    # Free vCPUs in the host family and the region, $null when unknown.
    $QuotaFree,
    [switch] $Rollback
  )
  $r = [System.Collections.Generic.List[object]]::new()
  $add = { param($id, $st, $check, $detail, $fix, $data) $r.Add([pscustomobject]@{ Id = $id; Status = $st; Check = $check; Detail = $detail; Remediation = $fix; Data = $data }) }
  $current = "$($PoolTags['avdlz-image'])"
  if ($PoolTags['avdlz-power-lock']) {
    & $add 'rotation-locked' 'Fail' 'Host pool not locked by auto shutdown' "Locked: $($PoolTags['avdlz-power-lock'])." 'Run Resume first (Invoke-AvdPowerAction.ps1 -Action Resume); a rotation would start hosts the budget stopped.' $null
  }
  if ($TargetImageId -and $TargetImageId -notmatch $script:VersionId) {
    & $add 'rotation-image' 'Fail' 'Target is a gallery image version' "'$TargetImageId' is not a Compute Gallery image version ID." 'Pass the version ID (.../images/<definition>/versions/<x.y.z>), never a definition or latest.' $null
  }
  elseif (-not $TargetImageId -and -not $Rollback) {
    & $add 'rotation-image' 'Fail' 'A target image' 'No -ImageId and no avdlz-image-next on the host pool.' 'Promote a validated version (image-promote.yml) or pass -ImageId.' $null
  }
  elseif ($TargetImageId -eq $current) {
    # After a rollback before Remove, avdlz-image-previous is the version the pool runs again.
    & $add 'rotation-image' 'Fail' 'Target differs from the current image' "The pool already runs $(Get-AvdImageLabel $current)." $(if ($Rollback) { 'Nothing to roll back to; rotate to a validated version with -ImageId.' } else { 'Nothing to rotate.' }) $null
  }
  else { & $add 'rotation-image' 'Pass' 'Target image' "$(Get-AvdImageLabel $current) -> $(Get-AvdImageLabel $TargetImageId)" '' $null }
  if (Test-AvdGenerationNameClash -BasePrefix $BasePrefix) {
    & $add 'rotation-names' 'Fail' 'Generation names differ from the current names' "sessionHostNamePrefix '$BasePrefix' is 11 characters ending in a or b, so a generation would reuse today's names." 'Use a sessionHostNamePrefix of 10 characters or fewer, or one that does not end in a or b.' $null
  }
  if ($HostCount -gt 0 -and $VcpuPerHost -gt 0) {
    $need = $HostCount * $VcpuPerHost
    $data = @{ needed = $need; free = $QuotaFree }
    if ($null -eq $QuotaFree) { & $add 'rotation-quota' 'Warn' 'vCPU quota for the new hosts' "Needs $need vCPUs beside the current hosts; quota could not be read." 'Check Portal > Quotas before continuing.' $data }
    elseif ($QuotaFree -lt $need) { & $add 'rotation-quota' 'Fail' 'vCPU quota for the new hosts' "The new hosts run beside the old ones until they drain: $need vCPUs needed, $QuotaFree free." 'Request the quota increase (Portal > Quotas); the rotation does not shrink capacity to fit.' $data }
    else { & $add 'rotation-quota' 'Pass' 'vCPU quota for the new hosts' "$need needed, $QuotaFree free." '' $data }
  }
  , $r.ToArray()
}

function Get-AvdRotationStep {
  <#
    What to do next for a rotation in progress, from the session hosts as they are now. Hosts are
    objects with VmName, Generation, Available (bool), Healthy (bool), AllowNewSession (bool), Sessions (int).
    Returns Action (deploy | wait-hosts | drain | wait-sessions | notify | logoff | remove | done), the next
    Phase, and a Detail line.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $State,
    [object[]] $SessionHosts = @(),
    [int] $ExpectedCount,
    [Parameter(Mandatory)][datetime] $Now,
    [switch] $LogOffAtDeadline,
    [int] $NoticeMinutes = 15,
    # The rotation's own deployment, from the subscription's deployment records: none (not started, or
    # not found), running, failed or succeeded. A rerun waits for a running one and retries a failed one.
    [ValidateSet('none', 'running', 'failed', 'succeeded')][string] $DeploymentState = 'none'
  )
  $old = @($SessionHosts | Where-Object { $_ -and $_.Generation -eq "$($State.from)" })
  $new = @($SessionHosts | Where-Object { $_ -and $_.Generation -eq "$($State.to)" })
  $out = { param($action, $phase, $detail) [pscustomobject]@{ Action = $action; Phase = $phase; Detail = $detail } }
  switch ($State.phase) {
    'Check' { return & $out 'deploy' 'Deploy' 'Checks passed; deploying the new hosts.' }
    'Deploy' {
      if ($DeploymentState -eq 'running') { return & $out 'wait-hosts' 'Deploy' "The deployment of generation $($State.to) is still running in Azure." }
      # Only a succeeded deployment is cut over to, however many hosts a failed or missing one left ready.
      if ($DeploymentState -eq 'failed') { return & $out 'deploy' 'Deploy' "$($new.Count)$(if ($ExpectedCount -gt 0) { " of $ExpectedCount" }) new host(s) registered and the deployment failed; deploying again." }
      if ($DeploymentState -eq 'none') { return & $out 'deploy' 'Deploy' "No deployment of generation $($State.to) found$(if ($new.Count) { " ($($new.Count) new host(s) registered)" }); deploying." }
      if ($new.Count -eq 0) { return & $out 'wait-hosts' 'Deploy' "The deployment succeeded; no generation $($State.to) host registered yet." }
      # Ready means taking sessions too: a replacement autoscale drained would leave no host open.
      $ready = @($new | Where-Object { $_.Available -and $_.Healthy -and $_.AllowNewSession })
      if ($ExpectedCount -gt 0 -and $ready.Count -lt $ExpectedCount) {
        return & $out 'wait-hosts' 'Deploy' "$($ready.Count) of $ExpectedCount new host(s) Available, taking new sessions, with every health check passing."
      }
      if ($ready.Count -lt $new.Count) { return & $out 'wait-hosts' 'Deploy' "$($ready.Count) of $($new.Count) new host(s) ready." }
      return & $out 'drain' 'Drain' "$($ready.Count) new host(s) ready."
    }
    'Drain' { return & $out 'drain' 'Wait' "Draining $($old.Count) host(s) of generation $(if ($State.from) { $State.from } else { 'none' })." }
    { $_ -in 'Wait', 'Remove' } {
      # Remove keeps the same gates: a host reopened while a removal was interrupted can have a user on
      # it again, who gets the deadline, notice and sign-out opt-in like anyone else. The phase stays
      # Remove, so a rollback stays refused.
      $sessions = ($old | Measure-Object -Property Sessions -Sum).Sum
      if (-not $sessions) {
        if ($State.phase -eq 'Remove') { return & $out 'remove' 'Done' "Removing $($old.Count) host(s) of generation $(if ($State.from) { $State.from } else { 'none' })." }
        return & $out 'remove' 'Remove' 'No sessions left on the old hosts.'
      }
      $p = "$($State.phase)"
      $deadline = if ($State.deadline) { [datetime]::Parse($State.deadline, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } else { $null }
      if (-not $deadline -or $Now -lt $deadline) {
        return & $out 'wait-sessions' $p "$sessions session(s) left on the old hosts$(if ($deadline) { "; deadline $($deadline.ToString('yyyy-MM-dd HH:mm')) UTC" })."
      }
      if (-not $LogOffAtDeadline) { return & $out 'wait-sessions' $p "$sessions session(s) left after the deadline. Run again with -LogOffAtDeadline to sign them out, or wait." }
      if (-not $State.notice) { return & $out 'notify' $p "Deadline passed: telling $sessions session(s) they are signed out in $NoticeMinutes minutes." }
      $notice = [datetime]::Parse($State.notice, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
      if ($Now -lt $notice.AddMinutes($NoticeMinutes)) { return & $out 'wait-sessions' $p "Final notice sent at $($notice.ToString('HH:mm')) UTC; signing out after $($notice.AddMinutes($NoticeMinutes).ToString('HH:mm')) UTC." }
      return & $out 'logoff' $p "Signing out $sessions session(s) left after the final notice."
    }
    default { return & $out 'done' 'Done' 'The rotation is complete.' }
  }
}

function Get-AvdRotationRollback {
  <#
    The state that rolls a rotation back before Remove: the generations swap, so the new hosts drain and
    are removed and the old ones take sessions again. After Remove there is nothing to swap back to:
    roll back by rotating to the previous version (avdlz-image-previous).
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][datetime] $Now, [int] $DeadlineHours = 1)
  if ($State.phase -in 'Remove', 'Done') { throw 'The old hosts are being removed or gone; roll back by rotating to avdlz-image-previous.' }
  if ($State.rollback) { throw 'This rotation is already a rollback.' }
  [pscustomobject]@{
    phase = 'Drain'; from = "$($State.to)"; to = "$($State.from)"; version = 'rollback'
    deadline = $Now.AddHours($DeadlineHours).ToString('yyyy-MM-ddTHH:mmZ'); prefix = $State.prefix; rollback = $true; by = $State.by
  }
}

Export-ModuleMember -Function Get-AvdImageLabel, Get-AvdNextHostGeneration, Get-AvdGenerationPrefix, Test-AvdGenerationNameClash,
  Get-AvdHostGeneration, ConvertTo-AvdRotationTag, ConvertFrom-AvdRotationTag, Get-AvdRotationDeployArgument, Get-AvdRotationEnvironment, Get-AvdRotationCheck,
  Get-AvdRotationStep, Get-AvdRotationRollback
