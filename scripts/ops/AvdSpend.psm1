#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Sandbox spend: a run estimate from the preflight, the cap gate, teardown evidence and run cost
  (docs/sandbox-runs.md, decision 0020). Pure functions take data and return data; the ARM and
  storage calls go through Invoke-AvdSpendArm and the record store functions, so tests mock a
  few seams. Runs in Azure Cloud Shell with Az PowerShell, signed in.

  Records are JSON files in one folder per sandbox (<sandbox>/<yyyy-MM>/<run-id>.json) and one per
  batch (queue/<yyyy-MM>/<batch-id>/). When the subscription has a run store
  (Initialize-AvdRunStore.ps1), its 'records' container is the one copy that counts; the local
  folder is a cache that Sync-AvdRunRecordStore pulls into and pushes from, with conditional
  writes, so two writers never overwrite each other silently.
#>

$script:HoursPerMonth = 730
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:RecordsContainer = 'records'
$script:StateFile = '.records-state.json'

# =====================================================================
# ARM
# =====================================================================
function Invoke-AvdSpendArm {
  <#
    One ARM REST call. Cost Management throttles hard (per-scope query units): a 429, or a
    transient 500/502/503/504, waits and retries, up to about ten minutes in all. Any other failure throws with the status and body
    (lesson 0012).
  #>
  param(
    [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string] $Method = 'GET',
    [Parameter(Mandatory)][string] $Path,
    $Body,
    [switch] $AllowNotFound
  )
  $p = @{ Path = ($Path -replace '^https://management\.azure\.com', ''); Method = $Method; ErrorAction = 'Stop' }
  if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 20 -Compress) }
  for ($attempt = 1; ; $attempt++) {
    $r = Invoke-AzRestMethod @p
    if ($AllowNotFound -and $r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -lt 400) { return $(if ($r.Content) { $r.Content | ConvertFrom-Json -Depth 50 } else { $null }) }
    # Throttling and transient server errors wait and retry; everything else fails at once.
    if ($r.StatusCode -in 429, 500, 502, 503, 504 -and $attempt -le 6) {
      $wait = [math]::Min(30 * $attempt, 150)
      # Honor the service's own Retry-After when it sends one (seconds), within the same ceiling.
      $after = if ($r.PSObject.Properties['Headers'] -and $r.Headers -and $r.Headers.RetryAfter -and $r.Headers.RetryAfter.Delta) { [int]$r.Headers.RetryAfter.Delta.TotalSeconds } else { 0 }
      if ($after -gt 0) { $wait = [math]::Min($after, 300) }
      Write-Host "  ARM answered $($r.StatusCode) on $Method $($p.Path); waiting ${wait}s (attempt $attempt of 6) ..." -ForegroundColor DarkGray
      Start-Sleep -Seconds $wait
      continue
    }
    throw "ARM $Method $($p.Path) failed ($($r.StatusCode)): $($r.Content)"
  }
}

function Get-AvdSpendInventory {
  <#
    Every resource and resource group in the subscription, from Resource Graph. Paged by skip
    token; stops when there is none, or after 50 pages (lesson 0008).
  #>
  param([Parameter(Mandatory)][string] $SubscriptionId)
  $query = "resources | project id = tolower(id), type = tolower(type), resourceGroup = tolower(resourceGroup), name | union (resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups' | project id = tolower(id), type = tolower(type), resourceGroup = tolower(name), name)"
  $rows = @(); $skip = $null; $page = 0
  do {
    $page++
    $body = @{ subscriptions = @($SubscriptionId); query = $query; options = @{ '$top' = 1000 } }
    if ($skip) { $body.options['$skipToken'] = $skip }
    $r = Invoke-AvdSpendArm -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body $body
    if (-not $r -or -not $r.PSObject.Properties['data'] -or -not $r.data) { break }
    $rows += @($r.data)
    $skip = if ($r.PSObject.Properties['$skipToken']) { $r.'$skipToken' } else { $null }
  } while ($skip -and $page -lt 50)
  $rows
}

function Get-AvdSpendCost {
  <#
    Actual cost (billing currency) from Cost Management for a date range, grouped by one
    dimension. Returns rows of @{ date (yyyy-MM-dd or $null); key; cost; currency }.
  #>
  param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][datetime] $From,
    [Parameter(Mandatory)][datetime] $To,
    [ValidateSet('ResourceGroupName', 'ServiceName', 'None')][string] $GroupBy = 'ResourceGroupName',
    [switch] $Daily
  )
  $dataset = @{
    granularity = $(if ($Daily) { 'Daily' } else { 'None' })
    aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
  }
  if ($GroupBy -ne 'None') { $dataset.grouping = @(@{ type = 'Dimension'; name = $GroupBy }) }
  $body = @{
    type       = 'ActualCost'
    timeframe  = 'Custom'
    timePeriod = @{ from = $From.ToString('yyyy-MM-ddT00:00:00Z'); to = $To.ToString('yyyy-MM-ddT23:59:59Z') }
    dataset    = $dataset
  }
  $path = "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
  $page = 0
  while ($path -and $page -lt 20) {
    $page++
    $r = Invoke-AvdSpendArm -Method POST -Path $path -Body $body
    if (-not $r -or -not $r.PSObject.Properties['properties']) { break }
    $cols = @($r.properties.columns | Where-Object { $_ } | ForEach-Object { $_.name })
    foreach ($row in @($r.properties.rows | Where-Object { $null -ne $_ })) {
      $get = { param($n) $i = [array]::IndexOf($cols, $n); if ($i -ge 0) { $row[$i] } else { $null } }
      $d = & $get 'UsageDate'
      [pscustomobject]@{
        date     = $(if ($d) { [datetime]::ParseExact("$d", 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } else { $null })
        key      = $(if ($GroupBy -eq 'ResourceGroupName') { "$(& $get $GroupBy)".ToLower() } elseif ($GroupBy -ne 'None') { "$(& $get $GroupBy)" } else { '' })
        cost     = [double](& $get 'Cost')
        currency = "$(& $get 'Currency')"
      }
    }
    $path = if ($r.properties.PSObject.Properties['nextLink'] -and $r.properties.nextLink) { $r.properties.nextLink } else { $null }
  }
}

function Get-AvdSpendMonthToDate {
  <# This calendar month's actual cost for the subscription, from Cost Management. #>
  param([Parameter(Mandatory)][string] $SubscriptionId, [datetime] $Now = (Get-Date))
  $utc = $Now.ToUniversalTime()
  [double](@(Get-AvdSpendCost -SubscriptionId $SubscriptionId -From ([datetime]::new($utc.Year, $utc.Month, 1)) -To $utc -GroupBy None | ForEach-Object { $_.cost }) | Measure-Object -Sum).Sum
}

function Get-AvdSpendBudget {
  <# Cost budgets on the subscription: name, amount, current spend. Empty when there are none. #>
  param([Parameter(Mandatory)][string] $SubscriptionId)
  $r = Invoke-AvdSpendArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets?api-version=2023-11-01"
  foreach ($b in @($r.value | Where-Object { $_ })) {
    [pscustomobject]@{
      name         = $b.name
      amount       = [double]$b.properties.amount
      timeGrain    = $b.properties.timeGrain
      currentSpend = $(if ($b.properties.PSObject.Properties['currentSpend']) { [double]$b.properties.currentSpend.amount } else { $null })
    }
  }
}

# =====================================================================
# Estimates (pure)
# =====================================================================
function Get-AvdSpendPreflightEstimate {
  <#
    The monthly estimate from the pre-deployment preflight: either its whole output (the
    <<<AVDLZ-STATE ... AVDLZ-STATE>>> line) or the JSON of context.estimate.
  #>
  param([Parameter(Mandatory)][string] $Text)
  $json = if ($Text -match '<<<AVDLZ-STATE\s+(\{.*\})\s+AVDLZ-STATE>>>') { $Matches[1] } else { $Text.Trim() }
  $o = $json | ConvertFrom-Json -Depth 20 -AsHashtable
  if ($o.ContainsKey('context')) {
    if (-not $o.context.ContainsKey('estimate')) { throw 'The preflight output has no cost estimate. Run the pre-deployment preflight with the sizing flags, then pass its output.' }
    return $o.context.estimate
  }
  if (-not $o.ContainsKey('lines')) { throw 'Not a preflight estimate: expected the AVDLZ-STATE line or JSON with "lines".' }
  $o
}

function Get-AvdSpendRunEstimate {
  <#
    Cost of one run of RunHours from a monthly list-price estimate (Get-AvdCostEstimate's shape).
    Session hosts are priced as running for the whole run (upper bound). Every other line is a
    730-hour monthly amount, prorated by the hour, which is how Azure bills them. Usage-based
    charges the preflight leaves out are covered by an allowance, not guessed.
  #>
  param(
    [Parameter(Mandatory)][System.Collections.IDictionary] $Monthly,
    [Parameter(Mandatory)][double] $RunHours,
    [int] $Hosts = 1,
    [double] $UsageAllowancePercent = 20
  )
  $share = $RunHours / $script:HoursPerMonth
  $lines = foreach ($l in @($Monthly.lines | Where-Object { $_ })) {
    $cost = if ($l.key -eq 'compute') { [double]$l.unitPrice * $Hosts * $RunHours } else { [double]$l.monthly * $share }
    [ordered]@{ key = $l.key; item = $l.item; meter = $l.meter; cost = [math]::Round($cost, 2)
      basis = $(if ($l.key -eq 'compute') { '{0} host(s) x {1} h x {2:N4}/h' -f $Hosts, $RunHours, [double]$l.unitPrice } else { '{0:N2}/month x {1} h / 730' -f [double]$l.monthly, $RunHours }) }
  }
  $lines = @($lines)
  $subtotal = [math]::Round((@($lines | ForEach-Object { $_.cost }) | Measure-Object -Sum).Sum, 2)
  $allowance = [math]::Round($subtotal * $UsageAllowancePercent / 100, 2)
  $perDay = if ($Monthly.Contains('alwaysOnTotal') -and $null -ne $Monthly.alwaysOnTotal) { [double]$Monthly.alwaysOnTotal } else { [double]$Monthly.total }
  [ordered]@{
    method                = 'preflight'
    currency              = $(if ($Monthly.Contains('currency') -and $Monthly.currency) { $Monthly.currency } else { 'USD' })
    location              = $(if ($Monthly.Contains('location')) { $Monthly.location } else { $null })
    runHours              = $RunHours
    lines                 = $lines
    unpriced              = @($(if ($Monthly.Contains('unpriced')) { $Monthly.unpriced }) | Where-Object { $_ } | ForEach-Object { $_.item })
    excluded              = @($(if ($Monthly.Contains('excluded')) { $Monthly.excluded }) | Where-Object { $_ })
    subtotal              = $subtotal
    usageAllowancePercent = $UsageAllowancePercent
    usageAllowance        = $allowance
    total                 = [math]::Round($subtotal + $allowance, 2)
    costPerDayIfLeftUp    = [math]::Round($perDay * 24 / $script:HoursPerMonth * (1 + $UsageAllowancePercent / 100), 2)
  }
}

function Get-AvdSpendManualEstimate {
  <# A run the preflight doesn't price (image builds, experiments): an amount and how it was worked out. #>
  param([Parameter(Mandatory)][double] $Amount, [Parameter(Mandatory)][string] $Note, [double] $RunHours, [string] $Currency = 'USD')
  [ordered]@{
    method = 'manual'; currency = $Currency; runHours = $RunHours
    lines = @([ordered]@{ key = 'manual'; item = $Note; cost = [math]::Round($Amount, 2); basis = 'entered by hand' })
    unpriced = @(); excluded = @(); subtotal = [math]::Round($Amount, 2); usageAllowancePercent = 0; usageAllowance = 0
    total = [math]::Round($Amount, 2); costPerDayIfLeftUp = $null
  }
}

function Get-AvdSpendCalibration {
  <#
    How far actual cost has landed from the estimate on settled runs of the same kind: the
    median of actual / estimate over the last Count runs. $null until there's one.
  #>
  param([object[]] $Runs = @(), [Parameter(Mandatory)][string] $Kind, [int] $Count = 5)
  $ratios = @($Runs | Where-Object { $_ -and $_.kind -eq $Kind -and $_.status -eq 'settled' -and $_.estimate.total -gt 0 -and $null -ne $_.actual } |
      Sort-Object { $_.startedAt } -Descending | Select-Object -First $Count | ForEach-Object { [double]$_.actual.runCost / [double]$_.estimate.total } | Sort-Object)
  if (-not $ratios.Count) { return $null }
  $mid = [int][math]::Floor($ratios.Count / 2)
  $median = if ($ratios.Count % 2) { $ratios[$mid] } else { ($ratios[$mid - 1] + $ratios[$mid]) / 2 }
  [ordered]@{ runs = $ratios.Count; medianActualToEstimate = [math]::Round($median, 2) }
}

function Get-AvdSpendGateDecision {
  <#
    Whether a run may start. Refuses when the estimate (or the calibrated one, if higher)
    exceeds the per-run cap or what's left of the monthly cap after month-to-date spend, when a
    line couldn't be priced and AllowUnpriced wasn't given, or when no cap is set.
  #>
  param(
    [Parameter(Mandatory)] $Estimate,
    [double] $MonthlyCap = 0,
    [double] $RunCap = 0,
    [double] $MonthToDate = 0,
    $Calibration,
    [switch] $AllowUnpriced
  )
  $worst = [double]$Estimate.total
  if ($Calibration -and $Calibration.medianActualToEstimate -gt 1) { $worst = [math]::Round($worst * $Calibration.medianActualToEstimate, 2) }
  $unpriced = @($Estimate.unpriced | Where-Object { $_ })
  $reasons = @()
  if ($RunCap -gt 0 -and $worst -gt $RunCap) { $reasons += ('Estimate {0:N2} is over the per-run cap {1:N2}.' -f $worst, $RunCap) }
  $remaining = $null
  if ($MonthlyCap -gt 0) {
    $remaining = [math]::Round($MonthlyCap - $MonthToDate, 2)
    if ($worst -gt $remaining) { $reasons += ('Estimate {0:N2} is over what is left of the monthly cap: {1:N2} of {2:N2} (month to date {3:N2}).' -f $worst, $remaining, $MonthlyCap, $MonthToDate) }
  }
  if ($unpriced.Count -and -not $AllowUnpriced) { $reasons += "Not priced: $($unpriced -join '; '). Run again with -AllowUnpriced once you've judged them." }
  if ($MonthlyCap -le 0 -and $RunCap -le 0) { $reasons += 'No cap set. Pass -MonthlyCap and -RunCap (or set SPEND_MONTHLY_CAP and SPEND_RUN_CAP).' }
  [ordered]@{
    decision    = $(if ($reasons.Count) { 'refused' } else { 'allowed' })
    checkedCost = $worst
    monthlyCap  = $MonthlyCap
    runCap      = $RunCap
    monthToDate = [math]::Round($MonthToDate, 2)
    remaining   = $remaining
    reasons     = @($reasons)
  }
}

# =====================================================================
# Baseline, teardown and attribution (pure)
# =====================================================================
function Get-AvdSpendHash {
  param([Parameter(Mandatory)][string] $Text)
  $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text.ToLower()))
  ([System.Convert]::ToHexString($bytes)).ToLower().Substring(0, 32)
}

function Get-AvdSpendBaseline {
  <#
    What existed before the run. Resource IDs are stored as hashes (they contain the
    subscription ID); resource group names are kept so cost can be attributed by group.
  #>
  param([object[]] $Inventory = @(), [datetime] $Now = (Get-Date))
  $resources = @($Inventory | Where-Object { $_ -and $_.type -ne 'microsoft.resources/subscriptions/resourcegroups' })
  [ordered]@{
    takenAt        = $Now.ToUniversalTime().ToString('o')
    resourceCount  = $resources.Count
    resourceGroups = @($Inventory | Where-Object { $_ -and $_.type -eq 'microsoft.resources/subscriptions/resourcegroups' } | ForEach-Object { $_.resourceGroup } | Sort-Object -Unique)
    resourceHashes = @($resources | ForEach-Object { Get-AvdSpendHash $_.id } | Sort-Object -Unique)
  }
}

function Get-AvdSpendLeftover {
  <# Resources and groups present now that weren't in the baseline. #>
  param([Parameter(Mandatory)] $Baseline, [object[]] $Inventory = @())
  $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Baseline.resourceHashes | Where-Object { $_ }))
  $groups = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Baseline.resourceGroups | Where-Object { $_ }), [System.StringComparer]::OrdinalIgnoreCase)
  foreach ($r in @($Inventory | Where-Object { $_ })) {
    if ($r.type -eq 'microsoft.resources/subscriptions/resourcegroups') {
      if (-not $groups.Contains($r.resourceGroup)) { [ordered]@{ type = $r.type; resourceGroup = $r.resourceGroup; name = $r.name } }
    }
    elseif (-not $known.Contains((Get-AvdSpendHash $r.id))) { [ordered]@{ type = $r.type; resourceGroup = $r.resourceGroup; name = $r.name } }
  }
}

function Get-AvdSpendRunCost {
  <#
    A run's cost from daily cost rows grouped by resource group: groups that weren't in the
    baseline, plus groups matching ResourceGroupPattern. Cost on days after the close date is
    the tail: evidence that charges stopped (zero) or didn't.
  #>
  param(
    [Parameter(Mandatory)] $Run,
    [object[]] $Rows = @(),
    [string] $ResourceGroupPattern
  )
  $baseline = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Run.baseline.resourceGroups | Where-Object { $_ }), [System.StringComparer]::OrdinalIgnoreCase)
  $pattern = $ResourceGroupPattern
  $isRun = { param($g) $g -and ((-not $baseline.Contains($g)) -or ($pattern -and $g -match $pattern)) }
  $closedDay = if ($Run.closedAt) { ([datetime]$Run.closedAt).ToUniversalTime().ToString('yyyy-MM-dd') } else { $null }
  $byGroup = [ordered]@{}; $run = 0.0; $tail = 0.0; $standing = 0.0; $subLevel = 0.0
  foreach ($r in @($Rows | Where-Object { $_ })) {
    if (& $isRun $r.key) {
      $run += $r.cost
      if (-not $byGroup.Contains($r.key)) { $byGroup[$r.key] = 0.0 }
      $byGroup[$r.key] += $r.cost
      if ($closedDay -and $r.date -and $r.date -gt $closedDay) { $tail += $r.cost }
    }
    elseif ($r.key) { $standing += $r.cost }
    else { $subLevel += $r.cost }
  }
  foreach ($k in @($byGroup.Keys)) { $byGroup[$k] = [math]::Round($byGroup[$k], 2) }
  [ordered]@{
    runCost               = [math]::Round($run, 2)
    byResourceGroup       = $byGroup
    chargesAfterCloseDay  = [math]::Round($tail, 2)
    standingCostSameDays  = [math]::Round($standing, 2)
    subscriptionLevelCost = [math]::Round($subLevel, 2)
    currency              = $(@($Rows | Where-Object { $_ -and $_.currency }) | Select-Object -First 1 | ForEach-Object { $_.currency })
  }
}

# =====================================================================
# Records: files
# =====================================================================
function Get-AvdSpendRunId {
  <#
    A new run's ID: <yyyyMMdd-HHmm>-<kind>, with a letter after the minute (b, c, ...) when a run
    with that ID exists, so a record is never overwritten and the IDs still sort in start order.
  #>
  param([Parameter(Mandatory)][datetime] $Now, [Parameter(Mandatory)][string] $Kind, [string[]] $Existing = @())
  $stamp = $Now.ToUniversalTime().ToString('yyyyMMdd-HHmm')
  foreach ($s in @('') + @([char[]](98..122) | ForEach-Object { "$_" })) {
    $id = "$stamp$s-$Kind"
    if ($id -notin $Existing) { return $id }
  }
  throw "More than 25 runs of kind $Kind started in the minute $stamp."
}

function Get-AvdSpendRunPath {
  param([Parameter(Mandatory)][string] $RecordsPath, [Parameter(Mandatory)] $Run)
  Join-Path $RecordsPath $Run.sandbox ([datetime]$Run.startedAt).ToUniversalTime().ToString('yyyy-MM') "$($Run.runId).json"
}

function Get-AvdSpendRun {
  <# Run records for a sandbox, oldest first (by start time). Statements and other files that aren't runs are skipped. #>
  param([Parameter(Mandatory)][string] $RecordsPath, [Parameter(Mandatory)][string] $Sandbox)
  $dir = Join-Path $RecordsPath $Sandbox
  if (-not (Test-Path $dir)) { return }
  @(Get-ChildItem -Path $dir -Recurse -Filter '*.json' | Where-Object { $_.Name -notlike 'statement*' } | ForEach-Object {
      $o = Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
      if ($o -is [System.Collections.IDictionary] -and $o.ContainsKey('schema') -and $o.schema -eq 'spend-run/v1') { $o }
    }) | Sort-Object { ([datetime]$_.startedAt).ToUniversalTime() }, { $_.runId }
}

function Hide-AvdSpendId {
  <# Replaces every GUID in a string with <id>, so a record holds no tenant, subscription or object ID. #>
  param([AllowEmptyString()][string] $Text)
  $Text -replace $script:GuidPattern, '<id>'
}

function Test-AvdSpendPrivateValue {
  <#
    What a batch must not hold, because its approval freezes it: GUIDs, email addresses and
    tenant domains. Returns the kinds found. Replace them with a variable the command reads at
    run time.
  #>
  param([AllowEmptyString()][string] $Text)
  $found = @()
  if ($Text -match $script:GuidPattern) { $found += 'a GUID' }
  if ($Text -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { $found += 'an email address' }
  if ($Text -match '(?i)\b[a-z0-9-]+\.onmicrosoft\.com\b') { $found += 'a tenant domain' }
  $found
}

function Save-AvdSpendRun {
  param([Parameter(Mandatory)][string] $RecordsPath, [Parameter(Mandatory)] $Run)
  $path = Get-AvdSpendRunPath -RecordsPath $RecordsPath -Run $Run
  New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
  Hide-AvdSpendId ($Run | ConvertTo-Json -Depth 30) | Set-Content -Path $path -Encoding utf8NoBOM
  $path
}

function Write-AvdSpendSummary {
  <# Markdown to the console, and to the job summary when there is one. #>
  param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]] $Markdown)
  $text = Hide-AvdSpendId ($Markdown -join "`n")
  Write-Host $text
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $text -Encoding utf8NoBOM }
}

function Format-AvdSpendMoney {
  param($Amount, [string] $Currency = 'USD')
  if ($null -eq $Amount) { return 'n/a' }
  '{0:N2} {1}' -f [double]$Amount, $Currency
}

function Get-AvdRecordsDefaultPath {
  <# Where records are cached on this machine: ~/clouddrive/avd-runs when Cloud Shell storage is mounted, else ~/avd-runs. #>
  param([string] $HomePath = $HOME)
  $cloud = Join-Path $HomePath 'clouddrive'
  if (Test-Path -LiteralPath $cloud) { return (Join-Path $cloud 'avd-runs') }
  Join-Path $HomePath 'avd-runs'
}

# =====================================================================
# Records: the run store (seams first, then the sync, which is pure over them)
# =====================================================================
function Get-AvdRecordStoreBlob {
  <# Name and ETag of every blob in the run store's records container. Throws when the container is missing. #>
  param([Parameter(Mandatory)] $Context)
  $container = Get-AzStorageContainer -Name $script:RecordsContainer -Context $Context -ErrorAction SilentlyContinue
  if (-not $container) { throw "The run store has no '$($script:RecordsContainer)' container. Run Initialize-AvdRunStore.ps1 again to add it (it updates the store in place)." }
  foreach ($b in @(Get-AzStorageBlob -Container $script:RecordsContainer -Context $Context -ErrorAction Stop | Where-Object { $_ })) {
    $etag = if ($b.BlobProperties) { $b.BlobProperties.ETag } else { $b.BlobClient.GetProperties().Value.ETag }
    [pscustomobject]@{ name = $b.Name; etag = "$etag" }
  }
}

function Read-AvdRecordStoreBlob {
  <# Downloads one blob to a file; returns its ETag. #>
  param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Destination)
  New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
  $client = (Get-AzStorageContainer -Name $script:RecordsContainer -Context $Context -ErrorAction Stop).BlobContainerClient.GetBlobClient($Name)
  $r = $client.DownloadTo($Destination)
  "$($r.Headers.ETag)"
}

function Write-AvdRecordStoreBlob {
  <#
    Uploads one file only if the blob is still what this machine last saw: If-Match on its ETag,
    or If-None-Match * when it is new here. Returns the new ETag. Throws 'conflict' when another
    writer got there first (HTTP 412 or 409), so nothing is overwritten silently.
  #>
  param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Path, [string] $ETag)
  $client = (Get-AzStorageContainer -Name $script:RecordsContainer -Context $Context -ErrorAction Stop).BlobContainerClient.GetBlobClient($Name)
  $conditions = [Azure.Storage.Blobs.Models.BlobRequestConditions]::new()
  if ($ETag) { $conditions.IfMatch = [Azure.ETag]::new($ETag) } else { $conditions.IfNoneMatch = [Azure.ETag]::All }
  $options = [Azure.Storage.Blobs.Models.BlobUploadOptions]::new()
  $options.Conditions = $conditions
  $stream = [IO.File]::OpenRead($Path)
  try { "$($client.Upload($stream, $options).Value.ETag)" }
  catch {
    $status = $_.Exception.InnerException.Status
    if ($status -in 409, 412) { throw "conflict: $Name changed in the run store since this machine last read it." }
    throw
  }
  finally { $stream.Dispose() }
}

function Get-AvdRecordFileHash {
  param([Parameter(Mandatory)][string] $Path)
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Sync-AvdRunRecordStore {
  <#
    Keeps the local records folder and the run store's records container in step.
      Pull: every blob that changed in the store since this machine last saw it is downloaded
            (local edits not yet pushed are kept, and reported).
      Push: every local file that changed since the last sync is uploaded with a conditional
            write. A conflict stops with the file named: pull, look, and run the step again.
    The state file (.records-state.json) holds each blob's ETag and hash as last synced.
    Never deletes anything on either side. Returns what it did.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('Pull', 'Push')][string] $Direction,
    [Parameter(Mandatory)][string] $RecordsPath,
    [Parameter(Mandatory)] $Context,
    # Push only these files (paths relative to RecordsPath, with forward slashes).
    [string[]] $Only
  )
  New-Item -ItemType Directory -Force -Path $RecordsPath | Out-Null
  $statePath = Join-Path $RecordsPath $script:StateFile
  $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
  if ($null -eq $state) { $state = @{} }
  $done = [System.Collections.Generic.List[object]]::new()
  $saveState = { $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM }
  if ($Direction -eq 'Pull') {
    foreach ($b in @(Get-AvdRecordStoreBlob -Context $Context)) {
      $known = if ($state.ContainsKey($b.name)) { $state[$b.name] } else { $null }
      if ($known -and $known.etag -eq $b.etag) { continue }
      $local = Join-Path $RecordsPath ($b.name -replace '/', [IO.Path]::DirectorySeparatorChar)
      if ($known -and (Test-Path -LiteralPath $local) -and (Get-AvdRecordFileHash $local) -ne $known.sha256) {
        $done.Add([pscustomobject]@{ name = $b.name; action = 'kept-local'; reason = 'changed here and in the store' })
        continue
      }
      $etag = Read-AvdRecordStoreBlob -Context $Context -Name $b.name -Destination $local
      $state[$b.name] = @{ etag = $etag; sha256 = (Get-AvdRecordFileHash $local) }
      $done.Add([pscustomobject]@{ name = $b.name; action = 'pulled' })
    }
    & $saveState
    return $done
  }
  $files = Get-ChildItem -LiteralPath $RecordsPath -Recurse -File | Where-Object { $_.Name -ne $script:StateFile }
  foreach ($f in $files) {
    $name = [IO.Path]::GetRelativePath($RecordsPath, $f.FullName) -replace '\\', '/'
    if ($Only -and $name -notin $Only) { continue }
    $hash = Get-AvdRecordFileHash $f.FullName
    $known = if ($state.ContainsKey($name)) { $state[$name] } else { $null }
    if ($known -and $known.sha256 -eq $hash) { continue }
    $etag = Write-AvdRecordStoreBlob -Context $Context -Name $name -Path $f.FullName -ETag $(if ($known) { $known.etag } else { $null })
    $state[$name] = @{ etag = $etag; sha256 = $hash }
    & $saveState
    $done.Add([pscustomobject]@{ name = $name; action = 'pushed' })
  }
  & $saveState
  $done
}

function Open-AvdRunRecordStore {
  <#
    The records for this subscription: the run store's records container when the store exists
    (the one copy that counts), pulled into the local folder first. -Local keeps records on this
    disk only and says so. Returns @{ path; context; local }.
  #>
  param(
    [Parameter(Mandatory)][string] $RecordsPath,
    [string] $SubscriptionId,
    [switch] $Local
  )
  if ($Local) {
    Write-Host "Records stay on this disk only ($RecordsPath). Cloud Shell's disk is not a durable copy, and an ephemeral session loses it." -ForegroundColor Yellow
    return [pscustomobject]@{ path = $RecordsPath; context = $null; local = $true }
  }
  if (-not $SubscriptionId) { throw 'No subscription for the run store. Sign in (Cloud Shell does it), or pass -Local to keep records on this disk only.' }
  $name = Get-AvdRunStoreName -SubscriptionId $SubscriptionId
  $store = Invoke-AvdSpendArm -Path "/subscriptions/$SubscriptionId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/$($name)?api-version=2023-05-01" -AllowNotFound
  if (-not $store) { throw "No run store ($name in avdlz-runs-rg) in this subscription. Set it up once with Initialize-AvdRunStore.ps1, or pass -Local to keep records on this disk only." }
  Write-Host "Reading records from the run store ($name) ..." -ForegroundColor DarkGray
  $ctx = New-AzStorageContext -StorageAccountName $name -UseConnectedAccount
  $pulled = @(Sync-AvdRunRecordStore -Direction Pull -RecordsPath $RecordsPath -Context $ctx)
  foreach ($k in @($pulled | Where-Object { $_.action -eq 'kept-local' })) { Write-Host "  $($k.name): changed here and in the store; kept the local copy. Push fails until you resolve it." -ForegroundColor Yellow }
  [pscustomobject]@{ path = $RecordsPath; context = $ctx; local = $false }
}

function Save-AvdRunRecordStore {
  <# Pushes local record changes to the run store; nothing to do in -Local mode. #>
  param([Parameter(Mandatory)] $Store, [string[]] $Only)
  if ($Store.local -or -not $Store.context) { return }
  $null = Sync-AvdRunRecordStore -Direction Push -RecordsPath $Store.path -Context $Store.context -Only $Only
}

Export-ModuleMember -Function *-AvdSpend*, *-AvdRecord*, Sync-AvdRunRecordStore, Open-AvdRunRecordStore, Save-AvdRunRecordStore
