#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Sandbox batches: pure functions for queue items, batches, the approval and the runner's stop and
  resume rules (docs/sandbox-runs.md, decision 0020). Nothing here calls Azure or GitHub; the
  scripts pass in what they read.

  A batch file (sandbox-batch/v1) is hashed in canonical form, and an approval is bound to that
  hash, so the canonical form and the batch's fields never change within v1: a new field goes
  into a v2 schema, or every open approval would be void (build/tests/SandboxBatch.Tests.ps1
  holds a golden hash).
#>

Set-StrictMode -Version Latest

$script:DeadlineFactor = 1.5
# The run recorder's printed estimate may be at most this much over the approved group estimate:
# a re-estimate more than 10% higher voids the approval.
$script:RecordTolerance = 1.1
# Item file fields (sandbox-run/v1 JSON) and the issue form labels they stand for.
$script:ItemFileFields = [ordered]@{
  purpose = 'Purpose'; source = 'Source'; tests = 'Tests'; kind = 'Kind'; sandbox = 'Sandbox'; region = 'Region'; regionReason = 'Region reason'
  shape = 'Shape'; deploymentKey = 'Deployment key'; ratePerHour = 'Rate per hour'; fixedCost = 'Fixed cost'; hours = 'Hours'
  hoursWhenSharing = 'Hours when sharing'; estimateNote = 'Estimate note'; unattended = 'Unattended'; deploy = 'Deploy'; test = 'Test'
  teardown = 'Teardown'; record = 'Record'; evidence = 'Evidence'; keep = 'Keep'; dependsOn = 'Depends on'
}
$script:Required = @('Purpose', 'Source', 'Tests', 'Kind', 'Sandbox', 'Region', 'Shape', 'Rate per hour', 'Hours', 'Estimate note', 'Test', 'Evidence')

# =====================================================================
# Items
# =====================================================================
function ConvertFrom-AvdBatchIssueBody {
  <#
    The fields of an issue opened from the Sandbox run form: "### <label>" headings, each
    followed by its value. GitHub writes "_No response_" for an empty field. Code blocks
    (render: bash) are unwrapped. A "---" rule outside a code block ends the field it is in.
  #>
  param([AllowEmptyString()][string] $Body)
  $fields = [ordered]@{}
  $name = $null; $lines = @(); $fence = $false
  $flush = {
    if ($null -ne $name) {
      $v = ($lines -join "`n").Trim()
      if ($v -match '^```[a-z]*\r?\n([\s\S]*?)\r?\n?```$') { $v = $Matches[1].Trim() }
      if ($v -eq '_No response_') { $v = '' }
      $fields[$name] = $v
    }
  }
  foreach ($line in ($Body -split "`r?`n")) {
    if ($line -match '^\s*```') { $fence = -not $fence }
    if (-not $fence -and $line -match '^###\s+(.+?)\s*$') { $next = $Matches[1]; . $flush; $name = $next; $lines = @() }
    # A "---" rule outside a code block ends the field: an edit through the API can append a footer
    # (an attribution line, a link), and it is never part of a value.
    elseif (-not $fence -and $line -match '^\s*---+\s*$') { . $flush; $name = $null; $lines = @() }
    elseif ($null -ne $name) { $lines += $line }
  }
  . $flush
  $fields
}

function ConvertFrom-AvdBatchItemFile {
  <#
    A queue item from a sandbox-run/v1 JSON file instead of an issue, so a queue needs no GitHub:
    { "schema": "sandbox-run/v1", "number": 1, "title": "...", "purpose": "...", ... } with the
    fields in $ItemFileFields. Returns the issue shape Get-AvdBatchItem reads: number, title, and
    a body of "### <label>" sections. Lists (keep, dependsOn) may be arrays; unattended may be a bool.
  #>
  param([Parameter(Mandatory)][System.Collections.IDictionary] $Item)
  if (-not $Item.Contains('schema') -or $Item.schema -ne 'sandbox-run/v1') { throw 'Not a sandbox-run/v1 item file (schema).' }
  if (-not $Item.Contains('number') -or "$($Item.number)" -notmatch '^\d+$') { throw 'An item file needs a whole "number", unique in the queue.' }
  $unknown = @($Item.Keys | Where-Object { $_ -notin @('schema', 'number', 'title') -and -not $script:ItemFileFields.Contains($_) })
  if ($unknown.Count) { throw "Unknown field(s) in the item file: $($unknown -join ', ')" }
  $body = foreach ($k in $script:ItemFileFields.Keys) {
    if (-not $Item.Contains($k)) { continue }
    $v = $Item[$k]
    $text = if ($v -is [bool]) { if ($v) { 'Yes' } else { 'No' } }
    elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { (@($v) -join "`n") }
    else { "$v" }
    if ($k -eq 'dependsOn') { $text = $text -replace "`n", ', ' }
    "### $($script:ItemFileFields[$k])`n`n$text`n"
  }
  [pscustomobject]@{ number = [int]$Item.number; title = $(if ($Item.Contains('title')) { $Item.title } else { "item $($Item.number)" }); body = (@($body) -join "`n") }
}

function Get-AvdBatchNumber {
  <# A non-negative number from a form field; Default when empty; NaN (and the name in Bad) when not a number. #>
  param($Fields, [string] $Key, [System.Collections.Generic.List[string]] $Bad, [double] $Default = [double]::NaN)
  $raw = if ($Fields.Contains($Key)) { "$($Fields[$Key])".Trim().TrimStart('$') } else { '' }
  if (-not $raw) { return $Default }
  $d = 0.0
  if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0) { return $d }
  $Bad.Add($Key); [double]::NaN
}

function Get-AvdBatchItem {
  <#
    One queue item from an issue (number, title, body, labels as gh returns them), with the
    numbers parsed and a list of problems. An item with problems is never batched.
  #>
  param(
    [Parameter(Mandatory)] $Issue,
    # Your sandbox's usual region: an item in any other region must say why (Region reason). Empty: any region.
    [string] $DefaultRegion
  )
  $f = ConvertFrom-AvdBatchIssueBody -Body $Issue.body
  $problems = @()
  foreach ($r in $script:Required) { if (-not $f.Contains($r) -or -not $f[$r]) { $problems += "Missing: $r" } }
  $bad = [System.Collections.Generic.List[string]]::new()
  $rate = Get-AvdBatchNumber $f 'Rate per hour' $bad
  $hours = Get-AvdBatchNumber $f 'Hours' $bad
  $fixed = Get-AvdBatchNumber $f 'Fixed cost' $bad 0
  $shared = Get-AvdBatchNumber $f 'Hours when sharing' $bad $hours
  foreach ($k in $bad) { $problems += "Not a number: $k" }
  if (-not [double]::IsNaN($hours) -and $hours -le 0) { $problems += 'Hours must be more than 0' }
  $region = if ($f.Contains('Region') -and $f['Region']) { $f['Region'].Trim().ToLower() } else { '' }
  $regionReason = if ($f.Contains('Region reason')) { $f['Region reason'] } else { '' }
  if ($DefaultRegion -and $region -and $region -ne $DefaultRegion -and -not $regionReason) { $problems += "Region $region needs a reason (Region reason); the default is $DefaultRegion" }
  $source = if ($f.Contains('Source')) { $f['Source'].Trim() } else { '' }
  if ($source -and $source -notmatch '^[\w.-]+/[\w.-]+(#\d+|@[0-9a-fA-F]{7,40})$') { $problems += "Source must be owner/repo#PR or owner/repo@commit: $source" }
  $depends = @(if ($f.Contains('Depends on')) { $f['Depends on'] -split '[,\s]+' | Where-Object { $_ } })
  foreach ($d in $depends) { if ($d -notmatch '^[\w.-]+/[\w.-]+#\d+$') { $problems += "Depends on must list owner/repo#N: $d" } }
  $get = { param($k) if ($f.Contains($k)) { $f[$k] } else { '' } }
  $record = $null
  try { $record = ConvertFrom-AvdBatchRecordField (& $get 'Record') } catch { $problems += $_.Exception.Message }
  [ordered]@{
    number        = [int]$Issue.number
    title         = $Issue.title
    purpose       = & $get 'Purpose'
    source        = $source
    kind          = & $get 'Kind'
    sandbox       = (& $get 'Sandbox').Trim()
    region        = $region
    regionReason  = $regionReason
    shape         = & $get 'Shape'
    deploymentKey = (& $get 'Deployment key').Trim()
    rate          = $rate
    fixed         = $fixed
    hours         = $hours
    sharedHours   = $shared
    estimateNote  = & $get 'Estimate note'
    unattended    = ((& $get 'Unattended') -eq 'Yes')
    deploy        = & $get 'Deploy'
    test          = & $get 'Test'
    teardown      = & $get 'Teardown'
    evidence      = & $get 'Evidence'
    keep          = @((& $get 'Keep') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    record        = $record
    dependsOn     = $depends
    problems      = @($problems)
  }
}

function ConvertFrom-AvdBatchRecordField {
  <#
    The Record field: how avd-landing-zone's run recorder records the group this item leads.
    "<parameter file> [-NamePrefix <p>] [-Environment <e>] [-DemoHostCount <n>] [-SessionHostVmSize <size>]",
    or empty or
    "none" for no recording ($null). Throws on anything else, so a typo never turns recording off.
  #>
  param([AllowEmptyString()][string] $Value)
  $v = "$Value".Trim()
  if (-not $v -or $v -eq 'none') { return $null }
  $tokens = @($v -split '\s+')
  if ($tokens[0] -notmatch '^[\w.-]+(/[\w.-]+)*\.bicepparam$') { throw "Record must start with a .bicepparam path in avd-landing-zone (or be none): $v" }
  $r = [ordered]@{ parameterFile = $tokens[0]; namePrefix = 'avdlz'; environment = 'dev'; demoHostCount = 0; sessionHostVmSize = '' }
  for ($k = 1; $k -lt $tokens.Count; $k += 2) {
    $val = if ($k + 1 -lt $tokens.Count) { $tokens[$k + 1] } else { '' }
    switch -CaseSensitive ($tokens[$k]) {
      '-NamePrefix' { if ($val -notmatch '^[a-z0-9]{2,8}$') { throw "Record: -NamePrefix must be 2 to 8 lowercase letters or digits: $val" }; $r.namePrefix = $val }
      '-Environment' { if ($val -notin 'dev', 'test', 'prod') { throw "Record: -Environment must be dev, test or prod: $val" }; $r.environment = $val }
      '-DemoHostCount' { if ($val -notmatch '^\d{1,2}$') { throw "Record: -DemoHostCount must be a number: $val" }; $r.demoHostCount = [int]$val }
      '-SessionHostVmSize' { if ($val -notmatch '^Standard_[A-Za-z0-9_]+$') { throw "Record: -SessionHostVmSize must be a VM size such as Standard_D2as_v5: $val" }; $r.sessionHostVmSize = $val }
      default { throw "Record: only -NamePrefix, -Environment, -DemoHostCount and -SessionHostVmSize are allowed after the parameter file: $($tokens[$k])" }
    }
  }
  $r
}

# =====================================================================
# Batches
# =====================================================================
function Get-AvdBatchGroup {
  <#
    Groups ready items into deployments. Items with the same deployment key (and sandbox and
    region) share one: the lead is the item with the most hours that has both Deploy and
    Teardown, and the others add their "Hours when sharing". Items without a key get their own.
    Groups are ordered by their oldest item, so the queue is first in, first out.
  #>
  param([object[]] $Items = @())
  $buckets = [ordered]@{}
  foreach ($i in @($Items | Where-Object { $_ } | Sort-Object { $_.number })) {
    $k = if ($i.deploymentKey) { "$($i.sandbox)|$($i.region)|$($i.deploymentKey)" } else { "#$($i.number)" }
    if (-not $buckets.Contains($k)) { $buckets[$k] = [System.Collections.Generic.List[object]]::new() }
    $buckets[$k].Add($i)
  }
  $n = 0
  foreach ($k in $buckets.Keys) {
    $members = @($buckets[$k])
    $candidates = @($members | Where-Object { $_.deploy -and $_.teardown } | Sort-Object { - $_.hours }, { $_.number })
    $problems = @()
    if (-not $candidates.Count) { $problems += 'No item in this deployment has both Deploy and Teardown' }
    $lead = if ($candidates.Count) { $candidates[0] } else { $members[0] }
    $others = @($members | Where-Object { $_.number -ne $lead.number })
    $hours = [double]$lead.hours + [double](@($others | ForEach-Object { $_.sharedHours }) | Measure-Object -Sum).Sum
    $rate = [double](@($members | ForEach-Object { $_.rate }) | Measure-Object -Maximum).Maximum
    $fixed = [double](@($members | ForEach-Object { $_.fixed }) | Measure-Object -Sum).Sum
    $alone = [double](@($members | ForEach-Object { [double]$_.rate * [double]$_.hours + [double]$_.fixed }) | Measure-Object -Sum).Sum
    $n++
    [ordered]@{
      id              = "G$n"
      deploymentKey   = $lead.deploymentKey
      sandbox         = $lead.sandbox
      region          = $lead.region
      regionReason    = $lead.regionReason
      kind            = $lead.kind
      lead            = $lead.number
      items           = @($lead.number) + @($others | ForEach-Object { $_.number })
      hours           = [math]::Round($hours, 2)
      deadlineHours   = [math]::Round($hours * $script:DeadlineFactor, 2)
      rate            = $rate
      estimate        = [math]::Round($rate * $hours + $fixed, 2)
      estimateIfAlone = [math]::Round($alone, 2)
      unattended      = -not @($members | Where-Object { -not $_.unattended }).Count
      problems        = @($problems)
    }
  }
}

function Get-AvdBatchPlan {
  <#
    Which groups fit. Groups are taken in queue order; one that is over the per-run cap, or
    would push the batch past the batch cap or what's left of the monthly cap, is left out
    with the reason, and the next one is tried.
  #>
  param(
    [object[]] $Groups = @(),
    [Parameter(Mandatory)][double] $BatchCap,
    [double] $RunCap = 0,
    [double] $MonthlyCap = 0,
    [double] $MonthToDate = 0
  )
  $taken = @(); $left = @(); $total = 0.0
  $remaining = if ($MonthlyCap -gt 0) { [math]::Round($MonthlyCap - $MonthToDate, 2) } else { $null }
  foreach ($g in @($Groups | Where-Object { $_ })) {
    $why = @($g.problems)
    if ($RunCap -gt 0 -and $g.estimate -gt $RunCap) { $why += ('Estimate {0:N2} is over the per-run cap {1:N2}' -f $g.estimate, $RunCap) }
    if ($total + $g.estimate -gt $BatchCap) { $why += ('Would take the batch to {0:N2}, over the batch cap {1:N2}' -f ($total + $g.estimate), $BatchCap) }
    if ($null -ne $remaining -and $total + $g.estimate -gt $remaining) { $why += ('Would take the batch to {0:N2}, over what is left of the monthly cap ({1:N2})' -f ($total + $g.estimate), $remaining) }
    if ($why.Count) { $left += [ordered]@{ group = $g; reasons = @($why) } }
    else { $taken += $g; $total += $g.estimate }
  }
  [ordered]@{ groups = @($taken); leftOut = @($left); total = [math]::Round($total, 2); batchCap = $BatchCap; monthlyRemaining = $remaining }
}

function ConvertTo-AvdBatchCanonical {
  <# Keys sorted, dates as round-trip UTC strings: the same JSON before and after a file round trip. #>
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    $o = [ordered]@{}
    foreach ($k in @($Value.Keys | Sort-Object { "$_" } -CaseSensitive)) { $o["$k"] = ConvertTo-AvdBatchCanonical $Value[$k] }
    return $o
  }
  if ($Value -is [pscustomobject]) {
    $h = [ordered]@{}; foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return ConvertTo-AvdBatchCanonical $h
  }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
  if ($Value -is [string]) { return $Value }
  if ($Value -is [System.Collections.IEnumerable]) { return , @($Value | ForEach-Object { ConvertTo-AvdBatchCanonical $_ }) }
  if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [int] -or $Value -is [long]) { return [decimal]$Value }
  $Value
}

function Get-AvdBatchHash {
  <# SHA-256 of a batch without its own hash field: what an approval is tied to. #>
  param([Parameter(Mandatory)] $Batch)
  $copy = [ordered]@{}
  foreach ($k in $Batch.Keys) { if ($k -ne 'hash') { $copy[$k] = $Batch[$k] } }
  $json = ConvertTo-AvdBatchCanonical $copy | ConvertTo-Json -Depth 30 -Compress
  ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json)))).ToLower()
}

function Get-AvdBatch {
  <#
    The batch record (sandbox-batch/v1) from a plan, the items in it and the pinned commits.
    Pins maps an item's source to { repo, sha }.
  #>
  param(
    [Parameter(Mandatory)] $Plan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items,
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary] $Pins,
    [Parameter(Mandatory)][datetime] $Now,
    # avd-landing-zone at a pinned commit ({ repo, sha }): where the run recorder comes from when a
    # recorded group's lead isn't avd-landing-zone itself.
    [System.Collections.IDictionary] $Recorder,
    # The landing zone's owner/repo, so a lead item from it records with its own commit.
    [string] $RecorderRepo = 'avd-ops/avd-landing-zone'
  )
  $byNumber = @{}; foreach ($i in $Items) { $byNumber[[int]$i.number] = $i }
  $groups = foreach ($g in $Plan.groups) {
    $members = foreach ($n in $g.items) {
      $i = $byNumber[[int]$n]; $pin = $Pins[$i.source]
      [ordered]@{
        number = $i.number; purpose = $i.purpose; source = $i.source; repo = $pin.repo; sha = $pin.sha
        role = $(if ($n -eq $g.lead) { 'lead' } else { 'shares' })
        deploy = $(if ($n -eq $g.lead) { $i.deploy } else { '' }); test = $i.test; teardown = $(if ($n -eq $g.lead) { $i.teardown } else { '' })
        keep = @($i.keep)
      }
    }
    $o = [ordered]@{}; foreach ($k in $g.Keys) { if ($k -ne 'problems') { $o[$k] = $g[$k] } }
    $o.members = @($members)
    $lead = $byNumber[[int]$g.lead]
    $o.record = $null
    if ($lead.record) {
      $leadPin = $Pins[$lead.source]
      $from = if ($leadPin.repo -eq $RecorderRepo) { $leadPin } else { $Recorder }
      if (-not $from -or "$($from.sha)" -notmatch '^[0-9a-f]{40}$') { throw "Group $($g.id) is recorded, but $RecorderRepo isn't pinned to a commit (-Recorder)." }
      $o.record = [ordered]@{ repo = $from.repo; sha = $from.sha }
      foreach ($k in $lead.record.Keys) { $o.record[$k] = $lead.record[$k] }
    }
    $o
  }
  $batch = [ordered]@{
    schema    = 'sandbox-batch/v1'
    batchId   = 'b{0}' -f $Now.ToUniversalTime().ToString('yyyyMMdd-HHmm')
    createdAt = $Now.ToUniversalTime().ToString('o')
    total     = $Plan.total
    batchCap  = $Plan.batchCap
    groups    = @($groups)
    hash      = $null
  }
  $batch.hash = Get-AvdBatchHash -Batch $batch
  $batch
}

# =====================================================================
# Approval
# =====================================================================
function Get-AvdBatchApproval {
  <#
    An approval from the operator's own words: "go batch <id> $<total>". The id and the total must
    be this batch's, so a go given for one batch or one amount never covers another. Via says how
    the words arrived: typed in Cloud Shell, or a reviewer's approval of a protected CI
    environment. A model never approves: the phrase is a person's.
  #>
  param(
    [Parameter(Mandatory)] $Batch,
    [Parameter(Mandatory)][string] $Phrase,
    [Parameter(Mandatory)][string] $ApprovedBy,
    [Parameter(Mandatory)][ValidateSet('cloudshell', 'environment')][string] $Via,
    [Parameter(Mandatory)][datetime] $Now
  )
  if ($Phrase -notmatch '(?i)\bgo\s+batch\s+(\S+)\s+\$?\s*([0-9]+(?:\.[0-9]{1,2})?)\b') { throw "Not an approval. The phrase is: go batch $($Batch.batchId) `$$('{0:N2}' -f $Batch.total)" }
  $id = $Matches[1]; $amount = [double]$Matches[2]
  if ($id -ne $Batch.batchId) { throw "The go is for batch $id, not $($Batch.batchId)." }
  if ([math]::Abs($amount - [double]$Batch.total) -gt 0.005) { throw ('The go is for {0:N2}, but batch {1} totals {2:N2}. Ask again with the right amount.' -f $amount, $Batch.batchId, $Batch.total) }
  [ordered]@{
    schema     = 'sandbox-batch-approval/v1'
    batchId    = $Batch.batchId
    total      = $Batch.total
    hash       = $Batch.hash
    approvedBy = $ApprovedBy
    via        = $Via
    phrase     = $Phrase.Trim()
    approvedAt = $Now.ToUniversalTime().ToString('o')
  }
}

function Test-AvdBatchApproval {
  <# Whether an approval still covers this batch: same id, same total, and the batch unchanged since. #>
  param([Parameter(Mandatory)] $Batch, $Approval)
  $reasons = @()
  if (-not $Approval) { $reasons += 'No approval recorded for this batch.' }
  else {
    if ($Approval.batchId -ne $Batch.batchId) { $reasons += "The approval is for batch $($Approval.batchId)." }
    if ([math]::Abs([double]$Approval.total - [double]$Batch.total) -gt 0.005) { $reasons += 'The approved total differs from the batch total.' }
    if ($Batch.hash -ne (Get-AvdBatchHash -Batch $Batch)) { $reasons += 'The batch file was changed after it was built.' }
    if ($Approval.hash -ne $Batch.hash) { $reasons += 'The batch changed after it was approved. Rebuild it and ask for a new go.' }
  }
  [ordered]@{ valid = -not $reasons.Count; reasons = @($reasons) }
}

# =====================================================================
# Running a group
# =====================================================================
function Get-AvdBatchNextStep {
  <#
    What the runner does after a step, from the stop rules (docs/sandbox-runs.md). Steps: start, deploy, test,
    teardown, close. Returns run-tests, next-test, teardown, close, next-group or stop-batch.
    Every path that deployed anything goes through teardown and close before the next group.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('start', 'deploy', 'test', 'teardown', 'close')][string] $Step,
    [Parameter(Mandatory)][int] $ExitCode,
    [double] $ElapsedHours = 0,
    [double] $DeadlineHours = 0,
    [bool] $MoreTests = $false,
    [double] $MonthToDate = 0,
    [double] $MonthlyCap = 0
  )
  $overDeadline = $DeadlineHours -gt 0 -and $ElapsedHours -gt $DeadlineHours
  $overMonth = $MonthlyCap -gt 0 -and $MonthToDate -gt $MonthlyCap
  $r = { param($action, $why, [bool] $stopAfter = $false) [ordered]@{ action = $action; reason = $why; stopBatchAfter = $stopAfter } }
  switch ($Step) {
    'start' { if ($ExitCode) { return & $r 'stop-batch' 'The spend run did not open (refused or failed). Nothing was deployed.' } ; return & $r 'deploy' 'Spend run open.' }
    'deploy' {
      if ($ExitCode) { return & $r 'teardown' 'Deploy failed: tear down what exists, then the next group.' }
      if ($overDeadline -or $overMonth) { return & $r 'teardown' $(if ($overDeadline) { 'Past the deadline.' } else { 'Monthly cap reached.' }) $true }
      return & $r 'run-tests' 'Deployed.'
    }
    'test' {
      if ($overDeadline) { return & $r 'teardown' 'Past the deadline: skipping the remaining tests.' $true }
      if ($overMonth) { return & $r 'teardown' 'Monthly cap reached: skipping the remaining tests.' $true }
      if ($MoreTests) { return & $r 'next-test' $(if ($ExitCode) { 'Test failed; recorded, carrying on.' } else { 'Test passed.' }) }
      return & $r 'teardown' 'Tests done.'
    }
    'teardown' { return & $r 'close' $(if ($ExitCode) { 'Teardown reported an error; the spend close checks what is left.' } else { 'Torn down.' }) }
    'close' {
      if ($ExitCode) { return & $r 'stop-batch' 'The spend close found leftovers (or failed). Nothing else starts until they are cleaned up.' }
      return & $r 'next-group' 'Closed clean.'
    }
  }
}

function Get-AvdBatchRunId {
  <# The run recorder's run ID for a group (avd-second-brain C17 shape), from the time it starts and the group number. #>
  param([Parameter(Mandatory)][datetime] $Now, [Parameter(Mandatory)][ValidatePattern('^G\d+$')][string] $Group)
  'run-{0}-q{1:d3}' -f $Now.ToUniversalTime().ToString('yyyyMMdd-HHmm'), [int]$Group.Substring(1)
}

function Get-AvdBatchRecorderCall {
  <#
    The run recorder calls for a recorded group (build/specs/run-recorder-spec.md): the script, relative to the recorder checkout, and its arguments. Steps:
    open (Start-AvdRunRecorder: run.json and the expected cost, gated at the approved estimate
    plus 10%), export (Stop-AvdRunRecorder -BeforeCleanup: the AVD logs, before teardown deletes
    the workspace), close (Stop-AvdRunRecorder: status and the first actual cost reading), copy
    (Stop-AvdRunRecorder -CopyTo github: the private companion repo, with read-back). env holds the
    variables the call needs: the parameter file reads the host size from AVD_SESSION_HOST_VM_SIZE,
    so the recorder prices the size the item deploys with deploy.sh --vm-size.
  #>
  param(
    [Parameter(Mandatory)] $Group,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][ValidateSet('open', 'export', 'close', 'copy')][string] $Step,
    [ValidateSet('succeeded', 'failed', 'torn-down', 'abandoned')][string] $Status = 'torn-down',
    [string] $SubscriptionId
  )
  $r = $Group.record
  if (-not $r) { throw "Group $($Group.id) is not recorded." }
  $lz = @('-NamePrefix', $r.namePrefix, '-Environment', $r.environment)
  $call = switch ($Step) {
    'open' {
      # Start-AvdRunRecorder passes a run whose expected total is at most half of -Cap, every line priced.
      $cap = [math]::Max([double]1, [math]::Round(2 * [double]$Group.estimate * $script:RecordTolerance, 2))
      $hours = [math]::Min([double]24, [math]::Max([double]0.5, [double]$Group.hours))
      [ordered]@{ script = 'scripts/ops/Start-AvdRunRecorder.ps1'; args = @('-RunId', $RunId, '-ParameterFile', $r.parameterFile, '-Hours', $hours.ToString([cultureinfo]::InvariantCulture), '-Cap', $cap.ToString([cultureinfo]::InvariantCulture), '-DemoHostCount', "$($r.demoHostCount)", '-Location', $Group.region) }
    }
    'export' { [ordered]@{ script = 'scripts/ops/Stop-AvdRunRecorder.ps1'; args = @('-RunId', $RunId, '-BeforeCleanup') + $lz } }
    'close' { [ordered]@{ script = 'scripts/ops/Stop-AvdRunRecorder.ps1'; args = @('-RunId', $RunId, '-Status', $Status) + $lz } }
    'copy' { [ordered]@{ script = 'scripts/ops/Stop-AvdRunRecorder.ps1'; args = @('-RunId', $RunId, '-CopyTo', 'github') + $lz } }
  }
  if ($SubscriptionId) { $call.args += @('-SubscriptionId', $SubscriptionId) }
  $call.env = [ordered]@{}
  if ($Step -eq 'open' -and $r.Contains('sessionHostVmSize') -and $r.sessionHostVmSize) { $call.env.AVD_SESSION_HOST_VM_SIZE = $r.sessionHostVmSize }
  $call
}

function Get-AvdBatchStepState {
  <#
    A step's state in a group's results: 'done' with its exit code (finished, pass or fail),
    'interrupted' (started, never finished: Cloud Shell timed out or the session dropped), or
    'new'. A resumed run replays done steps, runs interrupted ones again, and runs new ones.
  #>
  param($Results, [Parameter(Mandatory)][string] $Step, [int] $Item = 0)
  $hits = @(if ($Results) { @($Results.steps) | Where-Object { $_ -and $_.step -eq $Step -and [int]$_.item -eq $Item } })
  $last = $hits | Select-Object -Last 1
  if (-not $last) { return [ordered]@{ state = 'new'; exitCode = $null } }
  if ($null -eq $last.exitCode) { return [ordered]@{ state = 'interrupted'; exitCode = $null } }
  [ordered]@{ state = 'done'; exitCode = [int]$last.exitCode }
}

function Test-AvdBatchGroupStart {
  <#
    Whether a group may run now. An approval covers each group once: a group that has results
    may only be resumed (-Resume) or cleaned up (-TeardownOnly), never started again, because a
    second start would spend its estimate twice. Running it again needs a new batch and a new go.
  #>
  param($Results, [ValidateSet('start', 'resume', 'teardown-only')][string] $Mode = 'start')
  $started = $Results -and @(@($Results.steps) | Where-Object { $_ }).Count
  $finished = $Results -and $(if ($Results -is [System.Collections.IDictionary]) { $Results.Contains('finishedAt') -and $Results.finishedAt } else { $Results.PSObject.Properties['finishedAt'] -and $Results.finishedAt })
  switch ($Mode) {
    'start' {
      if ($started) { return [ordered]@{ allowed = $false; reason = "This group already started at $(Format-AvdBatchTime $Results.startedAt) (outcome: $($Results.outcome)). Continue it with -Resume, clean up with -TeardownOnly, or build a new batch to run it again." } }
      return [ordered]@{ allowed = $true; reason = 'Not started yet.' }
    }
    'resume' {
      if (-not $started) { return [ordered]@{ allowed = $false; reason = 'Nothing to resume: this group has not started. Run it without -Resume.' } }
      if ($finished) { return [ordered]@{ allowed = $false; reason = "This group already finished at $(Format-AvdBatchTime $Results.finishedAt) (outcome: $($Results.outcome))." } }
      return [ordered]@{ allowed = $true; reason = 'Resuming.' }
    }
    'teardown-only' { return [ordered]@{ allowed = $true; reason = 'Safety net.' } }
  }
}

# =====================================================================
# Health before spend
# =====================================================================
function Get-AvdHostDevicePrefix {
  <# The computer name prefixes a landing zone's hosts get: session hosts (bicep/main.bicep) and demo hosts (bicep/demo/main.bicep). #>
  param([string] $NamePrefix = 'avdlz', [string] $Environment = 'dev')
  $clean = ($NamePrefix -replace '-', '').ToLowerInvariant()
  foreach ($suffix in 'sh', 'demo') { $n = "$clean$($Environment.Substring(0, 1))$suffix"; $n.Substring(0, [math]::Min(11, $n.Length)) }
}

function Get-AvdStaleHostDevice {
  <#
    Entra devices an earlier run left: the name is exactly a landing zone host name (<prefix>-<n>,
    or a blue/green generation's take(<prefix>, 10) + a or b, bicep/main.bicep) and no VM carries it. A new host with the same name can't join while one is there. The caller
    passes VM names and computer names from every subscription it can read, so a host that lives
    in another subscription is never called stale.
  #>
  param($Devices, [string[]] $Prefix, [string[]] $VmName)
  $vms = @($VmName | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
  foreach ($d in @($Devices | Where-Object { $_ -and $_.displayName })) {
    $name = "$($d.displayName)".ToLowerInvariant()
    $hosts = @($Prefix | Where-Object { $_ } | ForEach-Object { $p = $_.ToLowerInvariant(); "^($([regex]::Escape($p))|$([regex]::Escape($p.Substring(0, [math]::Min(10, $p.Length))))[ab])-\d+$" })
    if (@($hosts | Where-Object { $name -match $_ }).Count -and $name -notin $vms) { $d }
  }
}

function Test-AvdArmAction {
  <# True when ARM permissions (the caller's Microsoft.Authorization/permissions list) allow Action. #>
  param($Permissions, [Parameter(Mandatory)][string] $Action)
  # ARM omits an empty notActions (lesson 0021); JSON gives objects, tests give hashtables.
  $get = { param($o, $k) if ($o -is [System.Collections.IDictionary]) { $o[$k] } elseif ($o.PSObject.Properties[$k]) { $o.$k } }
  foreach ($p in @($Permissions | Where-Object { $_ })) {
    $allowed = @(& $get $p 'actions' | Where-Object { $_ -and $Action -like $_ }).Count
    $denied = @(& $get $p 'notActions' | Where-Object { $_ -and $Action -like $_ }).Count
    if ($allowed -and -not $denied) { return $true }
  }
  $false
}

function Get-AvdSandboxHealthResult {
  <#
    Pass or fail per check, from facts Test-AvdSandboxHealth.ps1 read in Azure, each failure with
    what fixes it. Read only: it never grants a permission or deletes anything, so a missing
    permission or a leftover ends in a step for a person.
  #>
  param([Parameter(Mandatory)][hashtable] $Facts)
  $f = @{}
  foreach ($k in 'signedIn', 'signInError', 'subscriptionName', 'permissions', 'permissionsError', 'graphStatus', 'graphError', 'staleDevices', 'vmError',
    'leftoverGroups', 'groupsError', 'namePrefix', 'environment', 'needsRunStore', 'runStore', 'runStoreError', 'monthlyCap', 'runCap', 'estimate') { $f[$k] = $Facts[$k] }
  $r = [System.Collections.Generic.List[object]]::new()
  $add = { param($Check, $Ok, $Detail, $Fix) $r.Add([ordered]@{ check = $Check; ok = [bool]$Ok; detail = $Detail; fix = $(if ($Ok) { '' } else { $Fix }) }) }
  $lz = "-NamePrefix $($f.namePrefix) -Environment $($f.environment)"

  & $add 'Azure sign-in' $f.signedIn $(if ($f.signedIn) { "Signed in to '$($f.subscriptionName)'." } else { "Not signed in to Azure: $($f.signInError)" }) `
    'Sign in as the sandbox owner (Connect-AzAccount, or a new Cloud Shell) with the sandbox subscription selected (Set-AzContext).'
  if (-not $f.signedIn) { return $r.ToArray() }
  $grant = 'Ask an owner of the sandbox subscription for Contributor and Role Based Access Control Administrator (or Owner) on it.'
  $deploy = Test-AvdArmAction $f.permissions 'Microsoft.Resources/deployments/write'
  & $add 'Can deploy' $deploy $(if ($deploy) { 'Deployments allowed on the subscription.' } elseif ($f.permissionsError) { "Could not read your permissions: $($f.permissionsError)" } else { 'No Microsoft.Resources/deployments/write on the subscription (Contributor).' }) $grant
  $roles = Test-AvdArmAction $f.permissions 'Microsoft.Authorization/roleAssignments/write'
  & $add 'Can assign roles' $roles $(if ($roles) { 'Role assignments allowed (the landing zone assigns roles).' } elseif ($f.permissionsError) { "Could not read your permissions: $($f.permissionsError)" } else { 'No Microsoft.Authorization/roleAssignments/write (Role Based Access Control Administrator).' }) $grant
  $graph = $f.graphStatus -eq 200
  & $add 'Microsoft Graph devices' $graph $(if ($graph) { 'Devices readable.' } else { "Reading devices returned $($f.graphStatus): $($f.graphError)" }) `
    'Your account needs to read devices in Entra ID (any directory reader role; deleting them at teardown needs Cloud Device Administrator).'
  if ($graph) {
    $left = @($f.staleDevices | Where-Object { $_ } | ForEach-Object { $_.displayName })
    & $add 'Devices from earlier runs' (-not $left.Count -and -not $f.vmError) $(if ($f.vmError) { "Could not look up VMs with those names in Resource Graph: $($f.vmError)" } elseif ($left.Count) { "Still there with no VM of that name in any subscription you can read: $($left -join ', '). A new host with the same name can't join Entra ID." } else { 'None left by an earlier run.' }) `
      "Delete them in the Entra admin center (Devices, All devices) and in Intune if they are enrolled, then run this check again. Nothing here deletes them for you."
  }
  $groups = @($f.leftoverGroups | Where-Object { $_ })
  & $add 'Resource groups from earlier runs' (-not $groups.Count -and -not $f.groupsError) $(if ($f.groupsError) { "Could not list resource groups: $($f.groupsError)" } elseif ($groups.Count) { "Still there: $($groups -join ', '). They may still bill." } else { 'None.' }) `
    "Tear down the group that left them (Invoke-AvdSandboxBatch.ps1 -TeardownOnly), or remove the landing zone: ./scripts/ops/Remove-AvdDemo.ps1 $lz -IncludeLandingZone -Force (it refuses to delete the logs until they are kept; then add -DiscardLastCopy)."
  if ($f.needsRunStore) {
    & $add 'Run store' ([bool]$f.runStore) $(if ($f.runStore) { "Run store $($f.runStore) in avdlz-runs-rg." } elseif ($f.runStoreError) { "Could not read the run store: $($f.runStoreError)" } else { 'No run store (avdlz-runs-rg): needed for records, kept output and recorded runs.' }) `
      'Set it up once (cents a month): ./scripts/ops/Initialize-AvdRunStore.ps1'
  }
  $capsSet = [double]$f.monthlyCap -gt 0 -and [double]$f.runCap -gt 0
  & $add 'Spend caps' $capsSet $(if ($capsSet) { "Monthly cap $(Format-AvdBatchMoney $f.monthlyCap), run cap $(Format-AvdBatchMoney $f.runCap)." } else { 'A monthly or run cap is not set.' }) 'Pass -MonthlyCap and -RunCap, or set SPEND_MONTHLY_CAP and SPEND_RUN_CAP.'
  if ($capsSet -and $null -ne $f.estimate) {
    $fits = [double]$f.estimate -le [double]$f.runCap
    & $add 'Estimate within the run cap' $fits "Estimate $(Format-AvdBatchMoney $f.estimate), run cap $(Format-AvdBatchMoney $f.runCap)." 'Split the group or rebuild the batch: a run past its cap never starts.'
  }
  $r.ToArray()
}

function Format-AvdBatchTime {
  <# A time from a record (ISO text, or a date ConvertFrom-Json already parsed) as yyyy-MM-dd HH:mm UTC. #>
  param($Value)
  if (-not $Value) { return '' }
  $d = if ($Value -is [datetime]) { $Value } else { [datetime]::Parse("$Value", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
  $d.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
}
function Format-AvdBatchMoney {
  param($Amount)
  if ($null -eq $Amount) { return 'n/a' }
  '${0:N2}' -f [double]$Amount
}

Export-ModuleMember -Function ConvertFrom-AvdBatchItemFile, Get-AvdBatchStepState, Test-AvdBatchGroupStart, ConvertFrom-AvdBatchIssueBody, ConvertFrom-AvdBatchRecordField, Get-AvdBatchItem, Get-AvdBatchGroup, Get-AvdBatchPlan, Get-AvdBatchHash, Get-AvdBatch, Get-AvdBatchApproval, Test-AvdBatchApproval, Get-AvdBatchNextStep, Get-AvdBatchRunId, Get-AvdBatchRecorderCall, Format-AvdBatchMoney, Format-AvdBatchTime,
  Get-AvdHostDevicePrefix, Get-AvdStaleHostDevice, Test-AvdArmAction, Get-AvdSandboxHealthResult
