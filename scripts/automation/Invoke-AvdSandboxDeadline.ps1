# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  The deadline teardown for a sandbox batch group (decision 0021): runs once, at the group's
  deadline, whether or not anyone is there.

.DESCRIPTION
  Runs as the run store's Azure Automation runbook (bicep/recorder/deadline.bicep), started by the
  one-time schedule Invoke-AvdSandboxBatch.ps1 sets before a group starts. The schedule fires
  after the runner's own deadline and teardown budget, so it only matters when the runner is
  gone: Cloud Shell closed or timed out, the session dropped, the script stopped.

    1. Reads the group's results from the run store's records container. A group that closed
       clean needs nothing: it says so and stops.
    2. Finds the resource groups named <ResourceGroupPrefix>* (the group's landing zone, by its
       naming convention).
    3. Action Delete (the approved teardown passes -DiscardLastCopy): deletes them and waits until
       they are gone. Log Analytics workspaces go to their 14-day soft delete, recoverable.
       Action Deallocate (it doesn't): deallocates their VMs, which stops the compute meter and
       keeps every disk, share and log for the person to tear down.
    4. Writes deadline-<group>.json next to the results: what it found, what it did, what is left.

  It never touches the run store's own resource group, and never anything outside the prefix.
  The next block run for the batch closes the spend run with teardown evidence.

  No modules: ARM and Blob REST with tokens from the managed identity endpoint (or
  Get-AzAccessToken in Cloud Shell). Written for Windows PowerShell 5.1, the Automation sandbox
  default: no PowerShell 7-only syntax (build/lessons/0011).

.EXAMPLE
  ./scripts/automation/Invoke-AvdSandboxDeadline.ps1 -SubscriptionId $sub -StorageAccount avdlzruns0a1b2c3d4e5f `
    -ResultsBlob queue/2026-10/b20261021-1700/results-G1.json -BatchId b20261021-1700 -Group G1 `
    -ResourceGroupPrefix rg-avdlz-dev- -Action Delete -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string] $SubscriptionId,
  [Parameter(Mandatory)][ValidatePattern('^avdlzruns[0-9a-f]{12}$')][string] $StorageAccount,
  [Parameter(Mandatory)][ValidatePattern('^queue/[0-9]{4}-[0-9]{2}/b[0-9]{8}-[0-9]{4}/results-G[0-9]+\.json$')][string] $ResultsBlob,
  [Parameter(Mandatory)][ValidatePattern('^b[0-9]{8}-[0-9]{4}$')][string] $BatchId,
  [Parameter(Mandatory)][ValidatePattern('^G[0-9]+$')][string] $Group,
  # rg-<prefix>-<env>- : bicep/main.bicep's resource group names, nothing broader.
  [Parameter(Mandatory)][ValidatePattern('^rg-[a-z0-9]{2,8}-(dev|test|prod)-$')][string] $ResourceGroupPrefix,
  [Parameter(Mandatory)][ValidateSet('Delete', 'Deallocate')][string] $Action,
  # How long to wait for deletes to finish before writing what is left.
  [int] $WaitMinutes = 120
)

$ErrorActionPreference = 'Stop'
$apiRg = '2021-04-01'; $apiVm = '2024-07-01'; $blobVersion = '2021-08-06'
$protected = 'avdlz-runs-rg'

# ---------------------------------------------------------------- tokens
function Get-Token {
  param([Parameter(Mandatory)][string] $Resource)
  if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
    $h = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' }
    return (Invoke-RestMethod -Uri ($env:IDENTITY_ENDPOINT + '?resource=' + $Resource) -Method Get -Headers $h).access_token
  }
  $t = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
  if ($t.Token -is [System.Security.SecureString]) { return [System.Net.NetworkCredential]::new('', $t.Token).Password }
  return $t.Token
}

function Get-ErrorText {
  # Everything the API returned (build/lessons/0012). 5.1 keeps the body on the response stream;
  # PowerShell 7 puts it in ErrorDetails.
  param($ErrorRecord)
  $status = ''; $body = ''
  $resp = $ErrorRecord.Exception.Response
  if ($resp) {
    try { $status = [int]$resp.StatusCode } catch { $status = '' }
    try { $stream = $resp.GetResponseStream(); if ($stream) { $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd() } } catch { $body = '' }
  }
  if (-not $body -and $ErrorRecord.ErrorDetails) { $body = $ErrorRecord.ErrorDetails.Message }
  ("HTTP {0} {1} {2}" -f $status, $body, $ErrorRecord.Exception.Message).Trim()
}

function Get-StatusCode {
  param($ErrorRecord)
  $resp = $ErrorRecord.Exception.Response
  if ($resp) { try { return [int]$resp.StatusCode } catch { Write-Verbose "No status code on the response: $($_.Exception.Message)" } }
  if ("$($ErrorRecord.Exception.Message)" -match '\b(4\d\d|5\d\d)\b') { return [int]$Matches[1] }
  return 0
}

function Invoke-Arm {
  param([string] $Method = 'GET', [Parameter(Mandatory)][string] $Path)
  $p = @{ Uri = "https://management.azure.com$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $script:ArmToken" }; ContentType = 'application/json' }
  try { Invoke-RestMethod @p }
  catch { throw "ARM $Method $Path failed: $(Get-ErrorText $_)" }
}

function Get-ArmList {
  # Every item, following nextLink; stops on an error, an empty page or 20 pages (build/lessons/0008).
  param([Parameter(Mandatory)][string] $Path)
  $next = $Path; $page = 0
  while ($next -and $page -lt 20) {
    $page++
    $r = Invoke-Arm -Path $next
    if (-not $r -or -not $r.value) { break }
    $r.value
    $next = if ($r.nextLink) { ([uri]$r.nextLink).PathAndQuery } else { $null }
  }
}

# ---------------------------------------------------------------- records
$blobBase = "https://$StorageAccount.blob.core.windows.net/records"
function Read-Record {
  # The results JSON, or $null when there is none (404). Any other failure throws.
  param([Parameter(Mandatory)][string] $Name)
  $h = @{ Authorization = "Bearer $script:BlobToken"; 'x-ms-version' = $blobVersion }
  try { $r = Invoke-RestMethod -Uri "$blobBase/$Name" -Method Get -Headers $h }
  catch {
    if ((Get-StatusCode $_) -eq 404) { return $null }
    throw "Reading records/$Name failed: $(Get-ErrorText $_)"
  }
  if ($r -is [byte[]]) { $r = [System.Text.Encoding]::UTF8.GetString($r) }
  if ($r -is [string]) { return ($r.TrimStart([char]0xFEFF) | ConvertFrom-Json) }
  return $r
}

function Write-Record {
  # A new blob, never over an existing one (If-None-Match: *): a second firing writes beside it.
  param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Json)
  $h = @{ Authorization = "Bearer $script:BlobToken"; 'x-ms-version' = $blobVersion; 'x-ms-blob-type' = 'BlockBlob'; 'If-None-Match' = '*' }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  foreach ($n in @($Name, ($Name -replace '\.json$', ('-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '.json')))) {
    try { Invoke-RestMethod -Uri "$blobBase/$n" -Method Put -Headers $h -Body $bytes -ContentType 'application/json' | Out-Null; return $n }
    catch { if ((Get-StatusCode $_) -notin 409, 412) { throw "Writing records/$n failed: $(Get-ErrorText $_)" } }
  }
  throw "Writing records/$Name failed: it and its timestamped twin already exist."
}

function Test-ClosedClean {
  param($Results)
  if (-not $Results -or -not $Results.finishedAt) { return $false }
  return [bool](@($Results.steps | Where-Object { $_ -and $_.step -eq 'close' -and $_.exitCode -eq 0 }).Count)
}

# ---------------------------------------------------------------- run
$script:ArmToken = Get-Token -Resource 'https://management.azure.com/'
$script:BlobToken = Get-Token -Resource 'https://storage.azure.com/'
$recordName = ($ResultsBlob -replace 'results-(G[0-9]+)\.json$', 'deadline-$1.json')
$report = [ordered]@{
  schema = 'sandbox-deadline/v1'; batchId = $BatchId; group = $Group; firedAt = (Get-Date).ToUniversalTime().ToString('o')
  action = $Action; resourceGroupPrefix = $ResourceGroupPrefix; outcome = $null; found = @(); deleted = @(); deallocated = @(); remaining = @(); errors = @()
}
Write-Output "Deadline teardown: batch $BatchId group $Group, $Action $ResourceGroupPrefix*"

$results = $null
try { $results = Read-Record -Name $ResultsBlob }
catch { $report.errors += "$($_.Exception.Message)"; Write-Output "  $($_.Exception.Message) Going ahead: the meter rule comes first." }
if (Test-ClosedClean $results) {
  $report.outcome = 'not-needed'
  Write-Output "  The group closed clean at $($results.finishedAt); nothing to do."
}
else {
  if ($results) { Write-Output "  The group did not close clean (outcome: $($results.outcome)); its runner is past its deadline and teardown budget." }
  $groups = @(Get-ArmList -Path "/subscriptions/$SubscriptionId/resourcegroups?api-version=$apiRg" | Where-Object { $_.name -like "$ResourceGroupPrefix*" -and $_.name -ne $protected })
  $report.found = @($groups | ForEach-Object { $_.name })
  if (-not $groups.Count) { Write-Output "  No resource group named $ResourceGroupPrefix* is left." }
  foreach ($g in $groups) {
    $rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$($g.name)"
    if ($Action -eq 'Delete') {
      if ($PSCmdlet.ShouldProcess($g.name, 'Delete the resource group')) {
        try { Invoke-Arm -Method DELETE -Path "$rgPath`?api-version=$apiRg" | Out-Null; Write-Output "  $($g.name): deleting" }
        catch { $report.errors += "$($_.Exception.Message)"; Write-Output "  $($g.name): $($_.Exception.Message)" }
      }
    }
    else {
      foreach ($vm in @(Get-ArmList -Path "$rgPath/providers/Microsoft.Compute/virtualMachines?api-version=$apiVm")) {
        if ($PSCmdlet.ShouldProcess($vm.name, 'Deallocate')) {
          try { Invoke-Arm -Method POST -Path "$($vm.id)/deallocate?api-version=$apiVm" | Out-Null; $report.deallocated += $vm.name; Write-Output "  $($vm.name): deallocating" }
          catch { $report.errors += "$($_.Exception.Message)"; Write-Output "  $($vm.name): $($_.Exception.Message)" }
        }
      }
    }
  }
  if ($Action -eq 'Delete' -and $groups.Count -and -not $WhatIfPreference) {
    # Resource group deletes run in the background: wait (within the Automation job's three hours) and check.
    $until = (Get-Date).AddMinutes($WaitMinutes)
    do {
      $left = @(Get-ArmList -Path "/subscriptions/$SubscriptionId/resourcegroups?api-version=$apiRg" | Where-Object { $_.name -in $report.found } | ForEach-Object { $_.name })
      if (-not $left.Count -or (Get-Date) -gt $until) { break }
      Write-Output "  waiting for $($left.Count) resource group(s) to go ..."
      Start-Sleep -Seconds 60
    } while ($true)
    $report.remaining = @($left)
    $report.deleted = @($report.found | Where-Object { $_ -notin $left })
  }
  elseif ($Action -eq 'Deallocate') { $report.remaining = @($report.found) }
  $report.outcome = if ($WhatIfPreference) { 'what-if' }
  elseif ($Action -eq 'Delete') { if ($report.remaining.Count -or $report.errors.Count) { 'incomplete' } else { 'torn-down' } }
  elseif ($report.errors.Count) { 'incomplete' } else { 'deallocated' }
}

$json = $report | ConvertTo-Json -Depth 6
if ($WhatIfPreference) { Write-Output $json }
else {
  $written = Write-Record -Name $recordName -Json $json
  Write-Output "  Recorded in records/$written."
}
Write-Output ("Done: {0}. Found {1}, deleted {2}, deallocated {3}, left {4}." -f $report.outcome, $report.found.Count, $report.deleted.Count, $report.deallocated.Count, $report.remaining.Count)
# A teardown that didn't finish fails the job, so it shows as Failed in the Automation account.
if ($report.outcome -eq 'incomplete') { throw "Deadline teardown incomplete for $BatchId $Group`: $($report.remaining -join ', ') $($report.errors -join ' ')" }
