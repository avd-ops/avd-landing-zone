#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Same-tenant recovery for a landing zone (build/specs/recovery-spec.md), as pure functions that take
  data read from Azure and return data, tested offline (build/tests/Recovery.Tests.ps1).
    Get-AvdRecoveryStatus.ps1    what is protected, and whether the tier's targets are met (sections 6)
    Export-AvdConfiguration.ps1  the configuration snapshot, a recorded run (section 7)
    Test-AvdRecoveryCopies.ps1   the monthly verify routine (section 9)
    Start-AvdRecoveryTest.ps1    a recovery test, plan and estimate first (section 8)

  "Same tenant" means any region and any subscription in the operator's own tenant. Copies to another
  tenant or another cloud are not built here; they call these pieces (the copy hook, run records).

  Rules: a copy counts only when it has been read back against the manifest (D3); secrets are recorded
  as present, never copied (D4); nothing here deletes a recovery point, snapshot or copy (D8).
#>

# RPO and RTO per tier (spec section 4). R0 and R1 RTO are this repo's assumptions until a recovery
# test measures them; R2 is Microsoft's estimate for active-passive (spec F4).
$script:Tiers = @{
  R0 = [ordered]@{ Tier = 'R0'; Name = 'Rebuild'; RpoHours = 24; RtoHours = 8; TestIntervalDays = 90 }
  R1 = [ordered]@{ Tier = 'R1'; Name = 'Restore anywhere'; RpoHours = 24; RtoHours = 8; TestIntervalDays = 90 }
  R2 = [ordered]@{ Tier = 'R2'; Name = 'Warm standby'; RpoHours = 0.25; RtoHours = 1; TestIntervalDays = 90 }
}
# A daily backup counts as current for 26 hours: one schedule plus a two-hour margin.
$script:BackupMaxAgeHours = 26

# Property names whose values are never copied into a snapshot; they are recorded as present (D4).
$script:SecretProperty = '(?i)^(.*password.*|.*secret.*|token|.*token|.*sastoken.*|.*connectionstring.*|primarykey|secondarykey|accesskey|.*credential.*|registrationinfo)$'
# Properties that change on their own and would show as drift on every comparison.
$script:VolatileProperty = '(?i)^(etag|systemdata|provisioningstate|lastheartbeat|lastupdatetime|status|statustimestamp|sessions|agentversion|updatestate|updateerrormessage|sessionhosthealthcheckresults|osversion|sxsstackversion|lastsessionhosthealthcheckresults|cloudpcresource|timestamp|correlationid|duration|outputs|outputresources|validatedresources|dependencies|templatehash|createdon|updatedon|createdat|updatedat|lastmodifiedat)$'

function Get-AvdRecoveryTarget {
  <# The tier's targets: RPO and RTO in hours, and how often a recovery test is due. #>
  [CmdletBinding()]
  param([ValidateSet('R0', 'R1', 'R2')][string] $Tier = 'R0')
  [pscustomobject]$script:Tiers[$Tier]
}

function Get-AvdDeployedCommit {
  <#
    The commit a landing zone was deployed from. deploy.sh pins the auto-shutdown runbook's URL to the
    commit when GitHub has it, and to master otherwise (decision 0011), so the deployment record's
    autoShutdownRunbookUri parameter says both which commit and whether the remote holds it.
  #>
  [CmdletBinding()]
  param([string] $RunbookUri)
  $o = [ordered]@{ Commit = $null; Ref = $null; Repository = $null; OnRemote = $false }
  if ($RunbookUri -match '^https://raw\.githubusercontent\.com/(?<repo>[^/]+/[^/]+)/(?<ref>[^/]+)/') {
    $o.Repository = $Matches.repo; $o.Ref = $Matches.ref
    if ($o.Ref -match '^[0-9a-f]{40}$') { $o.Commit = $o.Ref; $o.OnRemote = $true }
  }
  [pscustomobject]$o
}

function Get-AvdRecoveryRun {
  <#
    The recovery runs in a set of run.json records (avd-run-record/v1, use case 'recovery'): kind,
    start, tier, items, measurements, and whether every file has a copy read back against the manifest
    (D3). Records of other use cases are left out. Newest first.
  #>
  [CmdletBinding()]
  param([AllowEmptyCollection()][object[]] $Record = @())
  $runs = foreach ($r in @($Record | Where-Object { $_ })) {
    $h = if ($r -is [System.Collections.IDictionary]) { $r } else { $r | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
    if ($h['useCase'] -ne 'recovery') { continue }
    $ext = if ($h['extensions'] -and $h['extensions']['recovery']) { $h['extensions']['recovery'] } else { @{} }
    $files = @($h['files'] | Where-Object { $_ })
    # ARM-style records omit empty properties and @($null).Count is 1 (lesson 0021): count real copies.
    $copied = @($files | Where-Object { @($_['copies'] | Where-Object { $_ -and $_['sha256'] }).Count })
    [pscustomobject]@{
      RunId    = $h['runId']
      Kind     = $ext['kind']
      Tier     = $ext['tier']
      Started  = ([datetime]$h['started']).ToUniversalTime()
      Status   = $h['status']
      Items    = @($ext['items'] | Where-Object { $_ })
      Outcome  = $ext['outcome']
      Measured = $ext['measured']
      Files    = $files.Count
      Copied   = $copied.Count
      Verified = $files.Count -gt 0 -and $copied.Count -eq $files.Count
      HasIdentity = @($files | Where-Object { $_['path'] -eq 'config/identity.json' }).Count -gt 0
    }
  }
  @($runs | Sort-Object Started -Descending)
}

function Get-AvdRecoveryAge {
  <# "5 hours" or "3 days", for a check's detail line. #>
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][datetime] $Since, [datetime] $Now = [datetime]::UtcNow)
  $h = ($Now - $Since.ToUniversalTime()).TotalHours
  if ($h -lt 48) { '{0} hours' -f [math]::Max(0, [math]::Round($h)) } else { '{0} days' -f [math]::Round($h / 24) }
}

function Get-AvdRecoveryVerdict {
  <#
    One result per item of the spec's inventory (section 6), from what the status check read. Each is
    { Id; Check; Status (Pass, Fail, Warn, Skip); Detail; Remediation; Data }. Nothing is assumed: an
    input that wasn't read (null) is reported as not known, which counts as not met.

    -Deployment       the landing zone's newest succeeded deploy.sh record (properties.parameters)
    -Runs             Get-AvdRecoveryRun output
    -BackupEnabled    whether the landing zone has a Recovery Services vault
    -BackupFinding    the profile backup findings (ids profile-backup, profile-backup-access) from
                      Get-AvdProfileBackupVerdict, mapped to dr-profile-backup and dr-profile-backup-access
    -Vault            the vault (properties.redundancySettings), -ProtectedPolicy the protected share's policy
    -HostImage        the session hosts' imageReference objects; -ImageVersion the gallery versions in use
    -RecoveryLocation the recovery region, if one is set
    -KeyVault         the Key Vault's properties
    -Identity         @{ UsersGroupId; AdminsGroupId }
  #>
  [CmdletBinding()]
  param(
    [ValidateSet('R0', 'R1', 'R2')][string] $Tier = 'R0',
    [object] $Deployment,
    [AllowEmptyCollection()][object[]] $Runs = @(),
    [bool] $BackupEnabled,
    [AllowEmptyCollection()][object[]] $BackupFinding,
    [object] $Vault,
    [object] $ProtectedPolicy,
    [AllowEmptyCollection()][object[]] $HostImage = @(),
    [AllowEmptyCollection()][object[]] $ImageVersion = @(),
    [string] $RecoveryLocation,
    [object] $KeyVault,
    [hashtable] $Identity = @{},
    [datetime] $Now = [datetime]::UtcNow
  )
  $t = Get-AvdRecoveryTarget -Tier $Tier
  $r1 = $Tier -in 'R1', 'R2'
  $out = [System.Collections.Generic.List[object]]::new()
  $add = { param($Id, $Check, $Status, $Detail, $Remediation, $Data)
    $out.Add([pscustomobject]@{ Id = $Id; Check = $Check; Status = $Status; Detail = "$Detail"; Remediation = "$Remediation"; Data = $(if ($Data) { $Data } else { @{} }) }) }

  # P1: the code. The deployment names its commit, and the remote holds it.
  if (-not $Deployment) {
    & $add 'dr-iac' 'Landing zone deployed from a commit on GitHub' 'Fail' 'No succeeded deploy.sh deployment record in this subscription.' 'Deploy with scripts/deploy/deploy.sh from a clone of the repository.'
  }
  else {
    $uri = $Deployment.properties.parameters.autoShutdownRunbookUri.value
    $c = Get-AvdDeployedCommit -RunbookUri $uri
    if ($c.OnRemote) { & $add 'dr-iac' 'Landing zone deployed from a commit on GitHub' 'Pass' "Deployment $($Deployment.name) used commit $($c.Commit.Substring(0, 7)) of $($c.Repository): a rebuild uses the same code." '' @{ commit = $c.Commit; deployment = $Deployment.name } }
    else {
      & $add 'dr-iac' 'Landing zone deployed from a commit on GitHub' 'Warn' "Deployment $($Deployment.name) doesn't name a commit GitHub has$(if ($c.Ref) { " (it used '$($c.Ref)')" }): it ran from changes that weren't pushed, or before deploy.sh pinned commits." `
        'Push the commit you deployed (or deploy again from a pushed one), so a rebuild uses the same code.' @{ deployment = $Deployment.name; ref = $c.Ref }
    }
  }

  # P2: the configuration snapshot, with a verified copy, within the RPO.
  $snaps = @($Runs | Where-Object Kind -eq 'snapshot')
  $verified = @($snaps | Where-Object Verified) | Select-Object -First 1
  $newest = $snaps | Select-Object -First 1
  if (-not $snaps.Count) {
    & $add 'dr-config' 'Configuration snapshot' 'Fail' 'No configuration snapshot found in the run folders.' 'Run ./scripts/ops/Export-AvdConfiguration.ps1, then copy it with Stop-AvdRunRecorder.ps1 -CopyTo github.'
  }
  elseif (-not $verified) {
    & $add 'dr-config' 'Configuration snapshot' 'Fail' "The newest snapshot ($($newest.RunId), $(Get-AvdRecoveryAge $newest.Started $Now) old) has no copy read back from outside the subscription ($($newest.Copied) of $($newest.Files) files)." `
      "Copy it: ./scripts/ops/Stop-AvdRunRecorder.ps1 -RunId $($newest.RunId) -CopyTo github" @{ runId = $newest.RunId }
  }
  else {
    $age = ($Now - $verified.Started).TotalHours
    $ok = $age -le $t.RpoHours
    & $add 'dr-config' 'Configuration snapshot' $(if ($ok) { 'Pass' } else { 'Fail' }) "Newest verified snapshot $($verified.RunId) is $(Get-AvdRecoveryAge $verified.Started $Now) old (target: $($t.RpoHours) hours for $Tier)." `
      $(if (-not $ok) { 'Run ./scripts/ops/Export-AvdConfiguration.ps1 and copy it, or schedule it daily.' }) @{ runId = $verified.RunId; ageHours = [math]::Round($age, 1) }
  }

  # P3: profiles. The status of the backup itself comes from the post-deployment check's verdict.
  if (-not $BackupEnabled) {
    & $add 'dr-profile-backup' 'Profile backup' 'Fail' 'The landing zone has no Recovery Services vault: profile backup is off (enableProfileBackup = false).' 'Set enableProfileBackup = true in the parameter file and deploy again.'
  }
  elseif ($null -eq $BackupFinding) {
    & $add 'dr-profile-backup' 'Profile backup' 'Warn' "This version can't read the backup's state yet (the post-deployment check's profile backup verdict isn't loaded)." 'Update the repository and run this again.'
  }
  else {
    foreach ($f in @($BackupFinding | Where-Object { $_ -and $_.Id -in 'profile-backup', 'profile-backup-access' })) {
      & $add "dr-$($f.Id)" $f.Check $f.Status $f.Detail $f.Remediation $f.Data
    }
  }
  if (-not $r1) {
    & $add 'dr-profile-offsite' 'Profile copy outside the share (R1 and up)' 'Skip' "Not part of $Tier. Snapshot-tier recovery points live in the share and go with it (spec F17)." ''
  }
  elseif (-not $BackupEnabled) {
    & $add 'dr-profile-offsite' 'Profile copy outside the share' 'Fail' 'Profile backup is off.' 'Turn profile backup on with profileBackupTier = Vaulted.'
  }
  else {
    $vaulted = $null -ne $ProtectedPolicy -and $null -ne $ProtectedPolicy.properties.vaultRetentionPolicy
    $red = $Vault.properties.redundancySettings
    $geo = "$($red.standardTierStorageRedundancy)" -eq 'GeoRedundant'
    $crr = "$($red.crossRegionRestore)" -eq 'Enabled'
    $miss = @($(if (-not $vaulted) { 'the policy keeps snapshots only (profileBackupTier = Snapshot)' }), $(if (-not $geo) { 'the vault is not geo-redundant' }), $(if (-not $crr) { 'Cross Region Restore is off' }) | Where-Object { $_ })
    & $add 'dr-profile-offsite' 'Profile copy outside the share' $(if ($miss.Count) { 'Fail' } else { 'Pass' }) $(if ($miss.Count) { ($miss -join '; ') + '.' } else { 'Vaulted backup, geo-redundant, Cross Region Restore on.' }) `
      $(if ($miss.Count) { 'Deploy with profileBackupTier = Vaulted. A vault that already protects items keeps its redundancy: that may need a new vault (spec U7).' }) @{ vaulted = $vaulted; geoRedundant = $geo; crossRegionRestore = $crr }
  }

  # P4: images. Marketplace images exist in every region; gallery versions need a replica (R1 and up).
  $refs = @($HostImage | Where-Object { $_ })
  $gallery = @($refs | Where-Object { "$($_.id)" -match '/galleries/' })
  if (-not $refs.Count) {
    & $add 'dr-image' 'Session host image' 'Skip' 'No session hosts found.' ''
  }
  elseif (-not $gallery.Count) {
    $names = @($refs | ForEach-Object { "$($_.publisher)/$($_.offer)/$($_.sku)" } | Select-Object -Unique) -join ', '
    & $add 'dr-image' 'Session host image' 'Pass' "Marketplace image ($names): available in any region and subscription." '' @{ marketplace = $true }
  }
  elseif (-not $r1) {
    & $add 'dr-image' 'Session host image' 'Pass' 'Gallery image: rebuilt from the image template in git (bicep/images) if the gallery is lost.' '' @{ marketplace = $false }
  }
  else {
    $missing = @(foreach ($v in @($ImageVersion | Where-Object { $_ })) {
        $regions = @($v.properties.publishingProfile.targetRegions | Where-Object { $_ } | ForEach-Object { "$($_.name)".ToLower().Replace(' ', '') })
        if (-not $RecoveryLocation -or $regions -notcontains $RecoveryLocation.ToLower()) { $v.name }
      })
    if (-not @($ImageVersion | Where-Object { $_ }).Count) { $missing = @('(versions not read)') }
    & $add 'dr-image' 'Session host image replica in the recovery region' $(if ($missing.Count) { 'Fail' } else { 'Pass' }) `
      $(if (-not $RecoveryLocation) { 'No recovery region is set.' } elseif ($missing.Count) { "No replica in $RecoveryLocation for: $($missing -join ', ')." } else { "Every version in use has a replica in $RecoveryLocation." }) `
      $(if ($missing.Count) { 'Add the recovery region to the image version''s target regions, or rebuild the image there.' }) @{ recoveryLocation = $RecoveryLocation; missing = $missing }
  }

  # P5: Key Vault. Secrets are regenerated on recovery, never copied (D4); the vault itself must survive a mistaken delete.
  if (-not $KeyVault) {
    & $add 'dr-keyvault' 'Key Vault soft delete and purge protection' 'Fail' 'No Key Vault found.' 'Run the post-deployment preflight.'
  }
  else {
    $soft = $KeyVault.properties.enableSoftDelete -ne $false
    $purge = $KeyVault.properties.enablePurgeProtection -eq $true
    & $add 'dr-keyvault' 'Key Vault soft delete and purge protection' $(if ($soft -and $purge) { 'Pass' } else { 'Fail' }) `
      "Soft delete $(if ($soft) { 'on' } else { 'off' }), purge protection $(if ($purge) { 'on' } else { 'off' }). Secrets are regenerated on recovery, never copied." `
      $(if (-not ($soft -and $purge)) { 'Deploy again: the landing zone sets both.' })
  }

  # P6: the AVD groups exist, and the newest verified snapshot holds them.
  $groupsOk = $Identity.UsersGroupId -and $Identity.AdminsGroupId
  $idSnap = @($snaps | Where-Object { $_.Verified -and $_.HasIdentity }) | Select-Object -First 1
  if (-not $groupsOk) {
    & $add 'dr-identity' 'AVD groups and their snapshot' 'Fail' 'The AVD user or admin group is not assigned to the landing zone.' 'Run the post-deployment preflight with -Fix.'
  }
  elseif (-not $idSnap) {
    & $add 'dr-identity' 'AVD groups and their snapshot' 'Fail' 'No verified snapshot holds the AVD groups, the operator app and their Conditional Access policies (Entra hard-deletes most objects, spec F10).' `
      'Run ./scripts/ops/Export-AvdConfiguration.ps1 -IncludeIdentity after Connect-AvdLandingZone.ps1, then copy it.'
  }
  else {
    $ok = ($Now - $idSnap.Started).TotalHours -le $t.RpoHours
    & $add 'dr-identity' 'AVD groups and their snapshot' $(if ($ok) { 'Pass' } else { 'Fail' }) "Identity snapshot $($idSnap.RunId) is $(Get-AvdRecoveryAge $idSnap.Started $Now) old." `
      $(if (-not $ok) { 'Run ./scripts/ops/Export-AvdConfiguration.ps1 -IncludeIdentity and copy it.' }) @{ runId = $idSnap.RunId }
  }

  # R2 only: the standby isn't built in this repository yet.
  if ($Tier -eq 'R2') { & $add 'dr-standby' 'Warm standby (R2)' 'Fail' 'R2 needs a standby host pool, a second profile share and Cloud Cache; this repository does not deploy them yet.' 'Choose R1, or ask for R2 (spec section 15, phase 6).' }
  else { & $add 'dr-standby' 'Warm standby (R2 only)' 'Skip' "Not part of $Tier." '' }

  # Capacity is never guaranteed in another region (spec F11).
  if ($r1) {
    & $add 'dr-capacity' 'Capacity in the recovery region' 'Warn' "Quota is not capacity: Azure doesn't guarantee hosts in $(if ($RecoveryLocation) { $RecoveryLocation } else { 'a recovery region' }) unless they are running or reserved (spec F11)." `
      'Check quota with the pre-deployment preflight for the recovery region; reserve capacity only if the RTO needs it.' @{ recoveryLocation = $RecoveryLocation }
  }
  else { & $add 'dr-capacity' 'Capacity in a recovery region (R1 and up)' 'Skip' "Not part of $Tier." '' }

  # Tested: only a recovery test proves the tier (D3).
  $order = @{ R0 = 0; R1 = 1; R2 = 2 }
  $test = @($Runs | Where-Object { $_.Kind -eq 'test' -and $_.Outcome -eq 'passed' -and $_.Tier -and $order[$_.Tier] -ge $order[$Tier] }) | Select-Object -First 1
  if (-not $test) {
    & $add 'dr-tested' "Recovery test for $Tier" 'Fail' "No passed recovery test for $Tier or higher is recorded." 'Plan one: ./scripts/ops/Start-AvdRecoveryTest.ps1 (prints the estimate; nothing runs without -Go).'
  }
  else {
    $days = ($Now - $test.Started).TotalDays
    $ok = $days -le $t.TestIntervalDays
    $m = $test.Measured
    $meas = if ($m) { " Measured RPO $($m.rpoMinutes) min, RTO $($m.rtoMinutes) min." } else { '' }
    & $add 'dr-tested' "Recovery test for $Tier" $(if ($ok) { 'Pass' } else { 'Fail' }) "Last passed test $($test.RunId), $(Get-AvdRecoveryAge $test.Started $Now) ago.$meas" `
      $(if (-not $ok) { "Due every $($t.TestIntervalDays) days: ./scripts/ops/Start-AvdRecoveryTest.ps1" }) @{ runId = $test.RunId; measured = $m }
  }
  , $out.ToArray()
}

function Get-AvdRecoverySummary {
  <# How many of the tier's checks are met: Pass counts, Skip doesn't count either way. #>
  [CmdletBinding()]
  param([AllowEmptyCollection()][object[]] $Result = @())
  $applies = @($Result | Where-Object { $_ -and $_.Status -ne 'Skip' })
  $met = @($applies | Where-Object Status -eq 'Pass').Count
  [pscustomobject]@{ Met = $met; Total = $applies.Count; Status = $(if ($applies.Count -and $met -eq $applies.Count) { 'met' } else { 'notmet' }) }
}

function Get-AvdConfigurationSnapshot {
  <#
    A resource as it goes into the configuration snapshot (spec section 7): secret-looking properties
    become '<present>' (D4), properties that change on their own are left out, and the rest is kept
    in a stable order so two snapshots compare line by line.
  #>
  [CmdletBinding()]
  param([AllowNull()][object] $InputObject)
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
  if ($InputObject -is [System.Collections.IDictionary] -or $InputObject -is [pscustomobject]) {
    $pairs = if ($InputObject -is [System.Collections.IDictionary]) { @($InputObject.Keys | ForEach-Object { , @($_, $InputObject[$_]) }) }
    else { @($InputObject.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) }) }
    $o = [ordered]@{}
    foreach ($p in ($pairs | Sort-Object { "$($_[0])" })) {
      $name = "$($p[0])"
      if ($name -match $script:VolatileProperty) { continue }
      if ($name -match $script:SecretProperty) { if ($null -ne $p[1] -and "$($p[1])" -ne '') { $o[$name] = '<present>' }; continue }
      $o[$name] = Get-AvdConfigurationSnapshot -InputObject $p[1]
    }
    return $o
  }
  if ($InputObject -is [System.Collections.IEnumerable]) { return , @($InputObject | ForEach-Object { Get-AvdConfigurationSnapshot -InputObject $_ }) }
  "$InputObject"
}

function Get-AvdConfigurationDrift {
  <#
    What differs between two snapshots of the same file: one line per changed, added or removed
    value, by path (resources keyed by their id or name). Drift is reported, never applied.
  #>
  [CmdletBinding()]
  param([AllowNull()][object] $Reference, [AllowNull()][object] $Current, [string] $Path = '')
  $isMap = { param($x) $x -is [System.Collections.IDictionary] -or $x -is [pscustomobject] }
  $toMap = { param($x) if ($x -is [System.Collections.IDictionary]) { $x } else { $h = [ordered]@{}; foreach ($p in $x.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h } }
  $key = { param($x, $i) if ((& $isMap $x)) { $m = & $toMap $x; if ($m['id']) { "$($m['id'])".ToLower() } elseif ($m['name']) { "$($m['name'])" } else { "[$i]" } } else { "[$i]" } }
  if ((& $isMap $Reference) -and (& $isMap $Current)) {
    $a = & $toMap $Reference; $b = & $toMap $Current
    foreach ($k in @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)) {
      Get-AvdConfigurationDrift -Reference $a[$k] -Current $b[$k] -Path $(if ($Path) { "$Path.$k" } else { "$k" })
    }
    return
  }
  $isList = { param($x) $x -is [System.Collections.IList] }
  if ((& $isList $Reference) -and (& $isList $Current)) {
    $a = [ordered]@{}; $i = 0; foreach ($x in $Reference) { $a[(& $key $x $i)] = $x; $i++ }
    $b = [ordered]@{}; $i = 0; foreach ($x in $Current) { $b[(& $key $x $i)] = $x; $i++ }
    foreach ($k in @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)) {
      Get-AvdConfigurationDrift -Reference $a[$k] -Current $b[$k] -Path "$Path[$k]"
    }
    return
  }
  $ja = if ($null -eq $Reference) { $null } else { $Reference | ConvertTo-Json -Depth 20 -Compress }
  $jb = if ($null -eq $Current) { $null } else { $Current | ConvertTo-Json -Depth 20 -Compress }
  if ($ja -ne $jb) {
    [pscustomobject]@{ Path = $Path; Change = $(if ($null -eq $Reference) { 'added' } elseif ($null -eq $Current) { 'removed' } else { 'changed' }); Before = $ja; After = $jb }
  }
}

function Get-AvdCopyCheck {
  <#
    The verify routine's read-back (spec section 9): each file of a run's manifest against what the
    copy holds now. -Held maps a manifest path to the SHA-256 read back from the copy (gzip bytes for
    a commit or release asset, as -CopyTo github stores them). A file whose manifest names a copy that
    is gone or different is a finding, never a repair. Returns { Path; Status (ok, mismatch, missing,
    nocopy); Detail }.
  #>
  [CmdletBinding()]
  param([AllowEmptyCollection()][object[]] $File = @(), [hashtable] $Held = @{})
  foreach ($f in @($File | Where-Object { $_ })) {
    $h = if ($f -is [System.Collections.IDictionary]) { $f } else { $f | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable }
    $copies = @($h['copies'] | Where-Object { $_ -and $_['sha256'] })
    if (-not $copies.Count) { [pscustomobject]@{ Path = $h['path']; Status = 'nocopy'; Detail = $(if ($h['keptOnlyIn']) { "kept in $($h['keptOnlyIn']) only" } else { 'no verified copy recorded' }) }; continue }
    $want = $copies[-1]['sha256']
    if (-not $Held.ContainsKey($h['path'])) { [pscustomobject]@{ Path = $h['path']; Status = 'missing'; Detail = "the copy recorded on $($copies[-1]['verifiedAt']) is no longer there" }; continue }
    if ($Held[$h['path']] -ne $want) { [pscustomobject]@{ Path = $h['path']; Status = 'mismatch'; Detail = "read back $($Held[$h['path']].Substring(0, 12))..., the manifest says $($want.Substring(0, 12))..." }; continue }
    [pscustomobject]@{ Path = $h['path']; Status = 'ok'; Detail = '' }
  }
}

function Get-AvdRecoveryTestPlan {
  <#
    A profile recovery test (T-profile, spec section 8): where the restored copy goes and what it
    costs, before anything is created. The copy always goes to new names (D2): a new resource group
    and storage account in the vault's subscription and region, because Azure Files restores to an
    alternate location only in the vault's region (spec F19) and, through the API, only in the same
    subscription (U7). -TargetSubscriptionId names where the redeploy half of a test (T-config) goes:
    any subscription in the same tenant.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $NamePrefix,
    [Parameter(Mandatory)][string] $Environment,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $VaultLocation,
    [Parameter(Mandatory)][string] $SourceSubscriptionId,
    [string] $TargetSubscriptionId,
    [double] $ShareGiB = 100,
    [double] $Hours = 2,
    # Retail prices (USD) for the test's lines; a missing price leaves the line unpriced, never guessed (decision 0010).
    [hashtable] $Price = @{}
  )
  $suffix = $RunId.Substring($RunId.Length - 4)
  $rg = "rg-$NamePrefix-$Environment-rtest-$suffix"
  $sa = ("strt$NamePrefix$suffix" -replace '[^a-z0-9]', '').ToLower()
  if ($sa.Length -gt 24) { $sa = $sa.Substring(0, 24) }
  $hoursPerMonth = 730
  $lines = @(
    [pscustomobject]@{ Item = "Premium file share, $ShareGiB GiB provisioned, $Hours h"; Meter = 'premiumFilesGiBMonth'; Cost = $(if ($Price.ContainsKey('premiumFilesGiBMonth')) { [math]::Round($Price.premiumFilesGiBMonth * $ShareGiB * $Hours / $hoursPerMonth, 2) } else { $null }) }
    [pscustomobject]@{ Item = 'Restore operation (Azure Backup charges no restore fee; data stays in the region)'; Meter = 'none'; Cost = 0 }
  )
  $priced = @($lines | Where-Object { $null -ne $_.Cost })
  [pscustomobject]@{
    Test                 = 'T-profile'
    ResourceGroup        = $rg
    StorageAccount       = $sa
    Share                = 'profiles-restored'
    Location             = $VaultLocation
    SubscriptionId       = $SourceSubscriptionId
    TargetSubscriptionId = $(if ($TargetSubscriptionId) { $TargetSubscriptionId } else { $SourceSubscriptionId })
    CrossSubscription    = [bool]($TargetSubscriptionId -and $TargetSubscriptionId -ne $SourceSubscriptionId)
    Lines                = $lines
    Total                = [math]::Round((@($priced | ForEach-Object Cost) | Measure-Object -Sum).Sum, 2)
    Unpriced             = @($lines).Count - $priced.Count
  }
}

function Get-AvdRecoveryRestoreRequest {
  <#
    The body of an Azure Backup restore of the whole profile share to an alternate location
    (POST .../recoveryPoints/{id}/restore; Microsoft Learn: Restore Azure Files using REST API).
    The target is always a new share (D2): never OriginalLocation, never over the source.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $SourceStorageAccountId,
    [Parameter(Mandatory)][string] $TargetStorageAccountId,
    [Parameter(Mandatory)][string] $TargetShare
  )
  if ($SourceStorageAccountId.TrimEnd('/') -ieq $TargetStorageAccountId.TrimEnd('/')) { throw 'A recovery test restores into a new storage account, never over the source (spec D2).' }
  [ordered]@{
    properties = [ordered]@{
      objectType         = 'AzureFileShareRestoreRequest'
      recoveryType       = 'AlternateLocation'
      sourceResourceId   = $SourceStorageAccountId
      copyOptions        = 'FailOnConflict'
      restoreRequestType = 'FullShareRestore'
      restoreFileSpecs   = @([ordered]@{ targetFolderPath = 'restored' })
      targetDetails      = [ordered]@{ name = $TargetShare; targetResourceId = $TargetStorageAccountId }
    }
  }
}

Export-ModuleMember -Function Get-AvdRecoveryTarget, Get-AvdDeployedCommit, Get-AvdRecoveryRun, Get-AvdRecoveryAge, Get-AvdRecoveryVerdict,
Get-AvdRecoverySummary, Get-AvdConfigurationSnapshot, Get-AvdConfigurationDrift, Get-AvdCopyCheck, Get-AvdRecoveryTestPlan, Get-AvdRecoveryRestoreRequest
