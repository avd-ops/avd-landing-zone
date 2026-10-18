#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Reads an avd-target-state/v1 manifest (avd-second-brain contract C14) for
  ConvertFrom-AvdTargetState.ps1. Pure functions: they take documents already read
  from disk and return data, so they are tested offline (tests/TargetState.Tests.ps1).
#>

function Get-AvdTargetStateDecision {
  # Every decision in the manifest that this landing zone would deploy, with its JSON pointer.
  [CmdletBinding()]
  param([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] [int] $PoolIndex)
  foreach ($name in 'identity', 'region', 'network') {
    [pscustomobject]@{ Pointer = "/$name"; Decision = $Manifest.$name }
  }
  $pool = $Manifest.hostPools[$PoolIndex]
  foreach ($name in 'type', 'appGroup', 'vmSize', 'maxSessions', 'hosts', 'power', 'profileQuotaGiB') {
    [pscustomobject]@{ Pointer = "/hostPools/$PoolIndex/$name"; Decision = $pool.$name }
  }
}

function Get-AvdParameterFileTimeZone {
  # The time zone the scheduled stop uses: autoShutdownTimeZone, else scalingTimeZone, else main.bicep's UTC.
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
  foreach ($p in 'autoShutdownTimeZone', 'scalingTimeZone') {
    $m = [regex]::Match($Text, "(?m)^\s*param\s+$p\s*=\s*'([^']+)'")
    if ($m.Success) { return $m.Groups[1].Value }
  }
  'UTC'
}

function Get-AvdTargetStatePlan {
  # Checks a manifest and its approval against the landing zone's capabilities and returns
  # { Refusals; Pool; Values; SetByHand; Block }. Block is empty when anything is refused.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Manifest,
    [Parameter(Mandatory)] [string] $ManifestSha256,
    [AllowNull()] $Approval,
    [Parameter(Mandatory)] $Capabilities,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $ParameterFileText,
    [Parameter(Mandatory)] [string] $ParameterFile,
    [string] $HostPool,
    [string] $UsersGroup = 'AVD Users',
    [string] $AdminsGroup = 'AVD Admins',
    [string] $AlertEmail
  )
  $refusals = [System.Collections.Generic.List[string]]::new()
  $setByHand = [System.Collections.Generic.List[string]]::new()
  $cap = $Capabilities

  if ($Manifest.pins.factRegister -notin @($cap.factRegisterVersions)) {
    $refusals.Add("The manifest uses fact register v$($Manifest.pins.factRegister); this landing zone knows v$(@($cap.factRegisterVersions) -join ', v'). Update the landing zone.")
  }

  # Approval: a separate file that pins this manifest's exact bytes (C14).
  $approvedUtc = $null
  if (-not $Approval) { $refusals.Add('No approval file. Design review signs off with an avd-target-approval/v1 file next to the manifest.') }
  elseif ($Approval.manifestSha256 -ne $ManifestSha256.ToLowerInvariant()) { $refusals.Add('The approval is for another version of this manifest (SHA-256 differs). Changed after approval? It needs a new approval.') }
  else { $approvedUtc = [datetime]::Parse($Approval.approvedUtc, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) }

  if ($Manifest.target.renderer -ne $cap.renderer) { $refusals.Add("The manifest is for renderer '$($Manifest.target.renderer)', not '$($cap.renderer)'.") }
  if (@($Manifest.target.gaps).Count) { $refusals.Add("The manifest lists requirements this target can't express: $(@($Manifest.target.gaps) -join ', ').") }
  if ($Manifest.identity.value -notin @($cap.identity)) { $refusals.Add("Identity lane $($Manifest.identity.value): this landing zone is $(@($cap.identity) -join ', ') only.") }
  if ($Manifest.network.value -notin @($cap.network)) { $refusals.Add("Network mode $($Manifest.network.value): this landing zone deploys $(@($cap.network) -join ', ') from a manifest.") }
  if (-not $cap.liquidware -and $Manifest.PSObject.Properties['liquidware'] -and @($Manifest.liquidware.PSObject.Properties | Where-Object { $_.Value -eq $true }).Count) {
    $refusals.Add('The manifest turns on a Liquidware product; that tier is avd-liquidware, not this landing zone.')
  }
  if ($Manifest.profiles.storage -notin @($cap.profileStorage)) { $refusals.Add("Profile storage $($Manifest.profiles.storage): this landing zone deploys $(@($cap.profileStorage) -join ', ').") }

  # One host pool per landing zone.
  $pools = @($Manifest.hostPools)
  $index = -1
  if ($HostPool) { for ($i = 0; $i -lt $pools.Count; $i++) { if ($pools[$i].id -eq $HostPool) { $index = $i } } }
  elseif ($pools.Count -le $cap.hostPoolsPerLandingZone) { $index = 0 }
  if ($index -lt 0) {
    if ($HostPool) { $refusals.Add("No host pool '$HostPool' in the manifest (it has $(@($pools.id) -join ', ')).") }
    else { $refusals.Add("The manifest has $($pools.Count) host pools; one landing zone deploys one. Pick one with -HostPool ($(@($pools.id) -join ', ')).") }
    return [pscustomobject]@{ Refusals = @($refusals); Pool = $null; Values = $null; SetByHand = @(); Block = '' }
  }
  $pool = $pools[$index]
  if ($pool.type.value -notin @($cap.hostPoolTypes)) { $refusals.Add("$($pool.id) is a $($pool.type.value) host pool; this landing zone deploys $(@($cap.hostPoolTypes) -join ', ').") }
  if ($pool.appGroup.value -notin @($cap.appGroups)) { $refusals.Add("$($pool.id) publishes $($pool.appGroup.value); this landing zone publishes $(@($cap.appGroups) -join ', ').") }
  if ($pool.vmSize.value -match $cap.unsupportedVmSizePattern) { $refusals.Add("$($pool.id) needs $($pool.vmSize.value); GPU sizes aren't supported here yet.") }
  if ($pool.hosts.value -gt $cap.maxHosts) { $refusals.Add("$($pool.id) needs $($pool.hosts.value) hosts; this landing zone deploys up to $($cap.maxHosts).") }
  if ($pool.maxSessions.value -gt $cap.maxSessions) { $refusals.Add("$($pool.id) needs $($pool.maxSessions.value) sessions per host; the most is $($cap.maxSessions).") }
  $quota = $pool.profileQuotaGiB.value
  if ($quota -lt $cap.profileQuotaGiB.min -or $quota -gt $cap.profileQuotaGiB.max) { $refusals.Add("$($pool.id) asks for a $quota GiB profile share; this landing zone takes $($cap.profileQuotaGiB.min) to $($cap.profileQuotaGiB.max).") }

  # Confidence: a person must have accepted every low-confidence value this would deploy.
  $decisions = @(Get-AvdTargetStateDecision -Manifest $Manifest -PoolIndex $index)
  $accepted = if ($Approval) { @($Approval.acceptLowConfidence) } else { @() }
  foreach ($d in $decisions) {
    if ($d.Decision.confidence -eq 'low' -and $d.Pointer -notin $accepted) { $refusals.Add("$($d.Pointer) is low confidence and the approval doesn't accept it.") }
  }

  # Freshness at approval time (the same limits as avd-swarm's gate).
  if ($approvedUtc) {
    $cited = @($decisions | ForEach-Object { @($_.Decision.evidence) })
    if (@($cited | Where-Object { $_ -like 'c11.*' }).Count) {
      if (-not $Manifest.evidence.currentState) { $refusals.Add('Decisions cite current-state (C11) facts, but the manifest has no snapshot time.') }
      else {
        $age = ($approvedUtc - [datetime]::Parse($Manifest.evidence.currentState, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).TotalDays
        if ($age -gt $cap.freshnessDays.c11) { $refusals.Add(("Approved {0:N0} days after the current-state snapshot; the limit is {1}. Rerun the collector and the facts script, then the design." -f $age, $cap.freshnessDays.c11)) }
      }
    }
    if (@($cited | Where-Object { $_ -like 'c12.*' }).Count) {
      if (-not $Manifest.evidence.forensicWindowEnd) { $refusals.Add('Decisions cite forensic (C12) facts, but the manifest has no window end.') }
      else {
        $age = ($approvedUtc.Date - [datetime]::ParseExact($Manifest.evidence.forensicWindowEnd, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays
        if ($age -gt $cap.freshnessDays.c12) { $refusals.Add(("Approved {0:N0} days after the measured window ended; the limit is {1}." -f $age, $cap.freshnessDays.c12)) }
      }
      if ($Manifest.evidence.quality -ne 'pass') { $refusals.Add("The measured window's quality gate says '$($Manifest.evidence.quality)', not pass.") }
    }
  }

  # Time zone: the scheduled stop and any schedule run in the parameter file's zone.
  $fileZone = Get-AvdParameterFileTimeZone -Text $ParameterFileText
  if ($pool.PSObject.Properties['scaling']) {
    if ($pool.scaling.timeZone -ne $fileZone) { $refusals.Add("$($pool.id) is designed for '$($pool.scaling.timeZone)', but $ParameterFile runs its schedule in '$fileZone'. Set the time zone in the file first.") }
    else { $setByHand.Add("Scaling schedule for $($pool.id) ($fileZone): ramp-up $($pool.scaling.rampUp), peak $($pool.scaling.peak), ramp-down $($pool.scaling.rampDown). Set it on the scaling plan by hand.") }
  }
  if (@($pool.replaces).Count) { $setByHand.Add("$($pool.id) replaces $(@($pool.replaces) -join ', ') (informational: nothing here touches existing host pools).") }

  $power = $pool.power.value
  $values = [ordered]@{
    Location          = $Manifest.region.value
    SessionHostCount  = [int]$pool.hosts.value
    SessionHostVmSize = $pool.vmSize.value
    MaxSessionLimit   = [int]$pool.maxSessions.value
    ProfileQuotaGiB   = [int]$quota
    AutoShutdownTime  = [string]$power.autoShutdownTime
    StartVmOnConnect  = ([string]$power.startVmOnConnect).ToLowerInvariant()
    MonthlyBudget     = [int][Math]::Ceiling([double]$pool.monthlyEstimate * 1.1)
  }
  if ($refusals.Count) { return [pscustomobject]@{ Refusals = @($refusals); Pool = $pool.id; Values = $values; SetByHand = @($setByHand); Block = '' } }

  $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
  $sha = $ManifestSha256.ToLowerInvariant().Substring(0, 12)
  $lines = @(
    "# $($pool.id) of $($Manifest.engagement) ($($Manifest.estate)), approved $($Approval.approvedUtc), manifest SHA-256 $sha..."
    "# Estimated $($pool.monthlyEstimate) $($Manifest.cost.currency) a month at list prices; compare with the preflight's estimate below."
    'if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }'
    'Set-Location ~/avd-landing-zone; git checkout -q master; git pull -q --ff-only'
  )
  if ($AlertEmail) {
    $lines += "`$env:AVD_MONTHLY_BUDGET = '$($values.MonthlyBudget)'; `$env:AVD_ALERT_EMAIL = $(& $q $AlertEmail)"
  }
  else {
    $lines += '# No -AlertEmail: no budget is set, so the budget lock is not armed. Pass -AlertEmail to arm it.'
    $lines += "Remove-Item Env:AVD_MONTHLY_BUDGET -ErrorAction SilentlyContinue"
  }
  $lines += "./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile $ParameterFile -Location $($values.Location) -UsersGroup $(& $q $UsersGroup) -AdminsGroup $(& $q $AdminsGroup) " +
    "-SessionHostCount $($values.SessionHostCount) -SessionHostVmSize $($values.SessionHostVmSize) -MaxSessionLimit $($values.MaxSessionLimit) -ProfileShareQuotaGiB $($values.ProfileQuotaGiB) " +
    "-AutoShutdownTime $($values.AutoShutdownTime) -StartVmOnConnect $($values.StartVmOnConnect)"
  $deploy = "./scripts/deploy/deploy.sh -p $ParameterFile -l $($values.Location) --users-group $(& $q $UsersGroup) --admins-group $(& $q $AdminsGroup) " +
    "--hosts $($values.SessionHostCount) --vm-size $($values.SessionHostVmSize) --max-sessions $($values.MaxSessionLimit) --profile-quota $($values.ProfileQuotaGiB) " +
    "--auto-shutdown $($values.AutoShutdownTime) --start-vm-on-connect $($values.StartVmOnConnect)"
  $lines += "$deploy --what-if"
  $lines += '# When the what-if looks right:'
  $lines += "# $deploy"
  [pscustomobject]@{ Refusals = @(); Pool = $pool.id; Values = $values; SetByHand = @($setByHand); Block = ($lines -join "`n") }
}

Export-ModuleMember -Function Get-AvdTargetStateDecision, Get-AvdParameterFileTimeZone, Get-AvdTargetStatePlan
