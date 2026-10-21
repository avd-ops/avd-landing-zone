#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Records a person's go on a sandbox batch: checks "go batch <id> $<total>" against batch.json and
  writes approval.json next to it (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell). Without -Phrase it asks you to type the phrase: the
  person typing is the approval. The phrase must name this batch and its exact total, and the
  approval is bound to the batch file's hash, so any later change to the batch voids it.

  -Via environment is for a CI job whose protected environment a reviewer approved; the job passes
  the phrase. A model or an agent never approves: it can build and price a batch, never type the go.

.EXAMPLE
  ./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId b20261021-1700
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, ParameterSetName = 'Id')][ValidatePattern('^b\d{8}-\d{4}$')][string] $BatchId,
  [Parameter(Mandatory, ParameterSetName = 'Path')][string] $BatchPath,
  [string] $Phrase,
  [string] $ApprovedBy = 'operator',
  [ValidateSet('cloudshell', 'environment')][string] $Via = 'cloudshell',
  [string] $SubscriptionId,
  [string] $RecordsPath,
  [switch] $Local,
  [datetime] $Now = (Get-Date)
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force
if (-not $RecordsPath) { $RecordsPath = Get-AvdRecordsDefaultPath }

$store = $null
if ($PSCmdlet.ParameterSetName -eq 'Id') {
  $subId = if ($Local) { $SubscriptionId } else { (Initialize-AvdAzContext -SubscriptionId $SubscriptionId).Subscription.Id }
  $store = Open-AvdRunRecordStore -RecordsPath $RecordsPath -SubscriptionId $subId -Local:$Local
  $BatchPath = Get-ChildItem -Path (Join-Path $RecordsPath 'queue') -Recurse -Filter 'batch.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq $BatchId } | Select-Object -First 1 -ExpandProperty FullName
  if (-not $BatchPath) { throw "No batch $BatchId in $RecordsPath. Build it with New-AvdSandboxBatch.ps1." }
}
$batch = Get-Content -LiteralPath $BatchPath -Raw | ConvertFrom-Json -Depth 30 -AsHashtable
if ($batch.hash -ne (Get-AvdBatchHash -Batch $batch)) { throw 'batch.json was changed after it was built. Rebuild the batch (New-AvdSandboxBatch.ps1).' }
$path = Join-Path (Split-Path $BatchPath) 'approval.json'
if (Test-Path -LiteralPath $path) { throw "Batch $($batch.batchId) already has an approval ($path). An approval is given once; to change the batch, build a new one." }

Get-Content -LiteralPath (Join-Path (Split-Path $BatchPath) 'batch.md') -ErrorAction SilentlyContinue | Select-Object -First 30 | Write-Host
if (-not $Phrase) {
  if ($Via -ne 'cloudshell') { throw '-Phrase is required with -Via environment.' }
  Write-Host ''
  $Phrase = Read-Host ('Type the go phrase to approve this batch (go batch {0} ${1:N2}), or press Enter to stop' -f $batch.batchId, $batch.total)
  if (-not $Phrase.Trim()) { Write-Host 'Not approved. Nothing was written.'; exit 1 }
}
$approval = Get-AvdBatchApproval -Batch $batch -Phrase $Phrase -ApprovedBy $ApprovedBy -Via $Via -Now $Now
$approval | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding utf8NoBOM
if ($store) { Save-AvdRunRecordStore -Store $store }
Write-Host ('Approved: batch {0} at ${1:N2}, by {2} via {3}. Recorded in {4}' -f $batch.batchId, $batch.total, $ApprovedBy, $Via, $path) -ForegroundColor Green
