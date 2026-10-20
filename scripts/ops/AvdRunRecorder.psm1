#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  The run recorder's rules (build/specs/run-recorder-spec.md sections 6.5, 9.2, 9.3 and 9.3a), as
  pure functions that take data and return data, tested offline (build/tests/RunRecorder.Tests.ps1).
  The files they build follow avd-second-brain contract C17 (contracts/schemas/run-*.schema.json).

  Never delete the last copy (spec R9; family decision 0017): Get-AvdTeardownLogPlan only marks a
  file deletable when a copy's read-back hash matches the manifest.
#>

$script:CommitLimit = 50MB          # GitHub warns above 50 MiB and blocks over 100 MiB (spec section 12, F8)
$script:ReleaseAssetLimit = 2GB     # each release asset must be under 2 GiB
$script:SettleHours = 72
$script:HoursPerMonth = 730

function Get-AvdRunId {
  # run-yyyyMMdd-HHmm-xxxx, the shape the portal generates and the journal accepts.
  [CmdletBinding()]
  [OutputType([string])]
  param([datetime] $Now = [datetime]::UtcNow, [string] $Suffix)
  if (-not $Suffix) { $Suffix = -join (1..4 | ForEach-Object { 'abcdefghijkmnpqrstuvwxyz23456789'[(Get-Random -Maximum 32)] }) }
  if ($Suffix -cnotmatch '^[a-z0-9]{4}$') { throw "Suffix must be 4 lowercase letters or digits, not '$Suffix'." }
  'run-{0}-{1}' -f $Now.ToUniversalTime().ToString('yyyyMMdd-HHmm'), $Suffix
}

function Get-AvdRunStoreName {
  # The run store's storage account name: one per subscription, the same every time (24 characters at most).
  [CmdletBinding()]
  [OutputType([string])]
  param([Parameter(Mandatory)][string] $SubscriptionId)
  $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant()))
  'avdlzruns' + (-join ($hash[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function Get-AvdRunRecord {
  # run.json (avd-run-record/v1) when a run starts: no files yet, teardown not started.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string] $RunId,
    [string] $UseCase = 'landing-zone',
    [Parameter(Mandatory)][string] $Commit,
    [string] $Entry,
    [string] $Region,
    [datetime] $Started = [datetime]::UtcNow,
    [ValidateSet('Keep', 'Ask', 'Delete')][string] $TeardownLogs = 'Keep',
    [hashtable] $Extension
  )
  $r = [ordered]@{
    schema   = 'avd-run-record/v1'
    runId    = $RunId
    useCase  = $UseCase
    level    = 'private'
    producer = [ordered]@{ repo = 'avd-landing-zone'; commit = $Commit }
    started  = $Started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    status   = 'running'
    files    = @()
    teardown = [ordered]@{ status = 'not-started'; logs = $TeardownLogs }
  }
  if ($Entry) { $r.producer.entry = $Entry }
  if ($Region) { $r.region = $Region }
  if ($Extension) { $r.extensions = [ordered]@{ $UseCase = $Extension } }
  $r
}

function Get-AvdRunCostExpected {
  <#
    cost.json (avd-run-cost/v1) before anything is deployed, from Get-AvdCostEstimate's monthly lines:
    hourly meters (the session hosts) for HostCount x Hours, everything else prorated from the month.
    A line Get-AvdCostEstimate couldn't price stays unpriced (spec R7). Gate: the expected total must
    be at most GateFraction of the cap (spec section 13a: $5 for the $10 cap).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Estimate,
    [Parameter(Mandatory)][double] $Hours,
    [Parameter(Mandatory)][int] $HostCount,
    [Parameter(Mandatory)][string] $RunId,
    [double] $Cap = 10,
    [double] $GateFraction = 0.5,
    [datetime] $PricedAt = [datetime]::UtcNow
  )
  $lines = @()
  foreach ($l in @($Estimate.lines)) {
    $hourly = $l.unitOfMeasure -eq '1 Hour' -and $l.key -eq 'compute'
    # Per-host monthly lines (OS disks) count every host of the run, the demo's included.
    $monthlyQty = if ($l.key -eq 'osdisk') { $HostCount } else { [double]$l.quantity }
    $qty = if ($hourly) { $HostCount * $Hours } else { [math]::Round($monthlyQty * $Hours / $script:HoursPerMonth, 4) }
    $lines += [ordered]@{ item = $l.item; match = 'exact'; meter = $l.meter; unitPrice = [double]$l.unitPrice; unit = $l.unitOfMeasure
      quantity = $qty; cost = [math]::Round([double]$l.unitPrice * $qty, 4) }
  }
  foreach ($u in @($Estimate.unpriced)) {
    $lines += [ordered]@{ item = $u.item; match = $(if (@($u.seen).Count -gt 1) { 'several' } else { 'none' }); cost = $null; metersSeen = @($u.seen) }
  }
  $total = [math]::Round((@($lines | Where-Object { $null -ne $_.cost } | ForEach-Object { $_.cost }) | Measure-Object -Sum).Sum, 2)
  $limit = [math]::Round($Cap * $GateFraction, 2)
  $unpriced = @($lines | Where-Object { $null -eq $_.cost }).Count
  [ordered]@{
    schema   = 'avd-run-cost/v1'
    runId    = $RunId
    currency = $Estimate.currency
    cap      = $Cap
    # An unpriced line means the total is incomplete, so the gate can't pass on it.
    gate     = [ordered]@{ rule = "expected total at most $([int]($GateFraction * 100))% of the cap, every line priced"; limit = $limit; passed = ($total -le $limit -and $unpriced -eq 0) }
    expected = [ordered]@{ pricedAt = $PricedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); source = 'Get-AvdCostEstimate (retail prices API)'; hours = $Hours
      lines = $lines; total = $total; unpriced = $unpriced }
    actuals  = @()
  }
}

function Add-AvdRunCostReading {
  <#
    Appends one Cost Management reading to cost.json and recomputes the comparison; never replaces a
    reading. Settled once the total has not changed for 72 hours of readings.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] $Cost,
    [Parameter(Mandatory)][datetime] $ReadAt,
    [Nullable[double]] $Total,
    [object[]] $ByMeter = @(),
    [string] $Unavailable,
    [switch] $BillingAfterTeardown
  )
  $readings = @($Cost.actuals)
  $settled = $false
  if ($null -ne $Total) {
    # The earliest reading of the unbroken run of readings with this same total.
    $since = $ReadAt
    for ($i = $readings.Count - 1; $i -ge 0; $i--) {
      if ($null -ne $readings[$i].total -and [math]::Round([double]$readings[$i].total, 2) -eq [math]::Round($Total, 2)) { $since = [datetime]$readings[$i].readAt } else { break }
    }
    $settled = ($ReadAt - $since).TotalHours -ge $script:SettleHours
  }
  $reading = [ordered]@{ readAt = $ReadAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); settled = $settled; total = $(if ($null -ne $Total) { [math]::Round($Total, 2) } else { $null }) }
  if ($Unavailable) { $reading.unavailable = $Unavailable }
  if ($ByMeter.Count) { $reading.byMeter = @($ByMeter | ForEach-Object { [ordered]@{ meter = $_.meter; cost = [math]::Round([double]$_.cost, 2) } }) }
  $set = { param($k, $v) if ($Cost -is [System.Collections.IDictionary]) { $Cost[$k] = $v } else { $Cost | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force } }
  & $set 'actuals' (@($readings) + @($reading))
  if ($null -ne $Total) {
    $known = @($Cost.expected.lines | Where-Object { $_.meter } | ForEach-Object { $_.meter })
    # Cost Management names the meter; the estimate names product / meter.
    $unexpected = @($ByMeter | Where-Object { $m = $_.meter; -not ($known | Where-Object { $_ -eq $m -or $_ -like "*/ $m" }) } | ForEach-Object { $_.meter })
    & $set 'comparison' ([ordered]@{ difference = [math]::Round($Total - [double]$Cost.expected.total, 2); unexpectedMeters = $unexpected; billingAfterTeardown = [bool]$BillingAfterTeardown })
  }
  $Cost
}

function Get-AvdRunFileRoute {
  <#
    Where each file's free copy goes (spec section 9.2 step 4): committed under 50 MiB compressed, a
    release asset under 2 GiB, otherwise kept in Azure only. Splitting is not part of the free tier.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][object[]] $File)
  foreach ($f in $File) {
    $size = if ($null -ne $f.gzBytes) { [long]$f.gzBytes } else { [long]$f.bytes }
    $route = if ($size -lt $script:CommitLimit) { 'github' } elseif ($size -lt $script:ReleaseAssetLimit) { 'github-release' } else { 'kept-in-azure' }
    [pscustomobject]@{ Path = $f.path; Bytes = $size; Route = $route }
  }
}

function Test-AvdCopyReceipt {
  <#
    Compares what a destination read back with the manifest. A file passes only when the hash read
    back equals the manifest's (the compressed hash for a gzip copy). Returns one result per file.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][object[]] $File, [Parameter(Mandatory)][hashtable] $ReadBack)
  foreach ($f in $File) {
    $got = $ReadBack[$f.path]
    $want = @($f.sha256, $f.gzSha256) | Where-Object { $_ }
    $reason = if (-not $got) { 'not read back' } elseif ($want -notcontains $got) { 'hash mismatch' } else { $null }
    [pscustomobject]@{ Path = $f.path; Verified = -not $reason; Reason = $reason }
  }
}

function Get-AvdTeardownLogPlan {
  <#
    What teardown may do with a run folder (spec section 9.2 step 3, R9). Keep deletes nothing. Ask and
    Delete may delete files that have a verified copy; a file with no verified copy is the last copy
    and needs the operator to type the run ID. Ask also needs a yes before anything is deleted.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $File, [Parameter(Mandatory)][ValidateSet('Keep', 'Ask', 'Delete')][string] $Preference)
  $copied = @(); $last = @()
  foreach ($f in $File) {
    $ok = @($f.copies | Where-Object { $_ -and $_.sha256 -and ($_.sha256 -eq $f.sha256 -or ($f.gzSha256 -and $_.sha256 -eq $f.gzSha256)) })
    if ($ok.Count) { $copied += $f.path } else { $last += $f.path }
  }
  [pscustomobject]@{
    Preference            = $Preference
    Delete                = $(if ($Preference -eq 'Keep') { @() } else { $copied })
    NeedsTypedRunId       = $(if ($Preference -eq 'Keep') { @() } else { $last })
    NeedsYes              = ($Preference -eq 'Ask')
    Keep                  = $(if ($Preference -eq 'Keep') { @($File | ForEach-Object { $_.path }) } else { @() })
  }
}

function Test-AvdPrivateRepoName {
  # AVD_PRIVATE_REPO is owner/repo (spec section 9.3).
  [CmdletBinding()]
  [OutputType([bool])]
  param([string] $Name)
  [bool]($Name -match '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$')
}

Export-ModuleMember -Function Get-AvdRunId, Get-AvdRunStoreName, Get-AvdRunRecord, Get-AvdRunCostExpected, Add-AvdRunCostReading,
Get-AvdRunFileRoute, Test-AvdCopyReceipt, Get-AvdTeardownLogPlan, Test-AvdPrivateRepoName
