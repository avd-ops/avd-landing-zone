#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Turns an approved target-state manifest from the migration factory into the preflight and
  deploy.sh commands for one host pool. Changes nothing in Azure.

.DESCRIPTION
  Reads an avd-target-state/v1 manifest and its avd-target-approval/v1 file (avd-second-brain
  contract C14, schemas vendored in contracts/). Refuses, with the reason, anything this landing
  zone can't deploy (contracts/target-state-capabilities.json): no approval or a changed manifest,
  stale evidence, another renderer or listed gaps, a lane other than Entra-only, hub-peered
  networking, more than one host pool without -HostPool, personal or RemoteApp pools, GPU sizes,
  low-confidence values the approval doesn't accept, or a schedule in another time zone than the
  parameter file's. Otherwise prints a self-contained Cloud Shell block: the pre-deployment
  preflight and deploy.sh with the manifest's sizing as flags (deploy.sh overwrites the AVD_*
  sizing variables with its flags, so variables alone would deploy the file's defaults).

  Exit code 0 with a block, 1 when refused, 2 when the files can't be read.

.EXAMPLE
  ./scripts/ops/ConvertFrom-AvdTargetState.ps1 -Path ~/engagement/manifest.json -ParameterFile parameters/prod.bicepparam -AlertEmail ops@example.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $Path,
  [string] $ApprovalPath,
  [ValidatePattern('^tp-[0-9]{2}$')] [string] $HostPool,
  [string] $ParameterFile = 'parameters/prod.bicepparam',
  [string] $UsersGroup = 'AVD Users',
  [string] $AdminsGroup = 'AVD Admins',
  [string] $AlertEmail
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'AvdTargetState.psm1') -Force
$contracts = Join-Path $repoRoot 'contracts'

function Read-ValidJson {
  param([string] $File, [string] $Schema, [string] $What)
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $text = Get-Content -LiteralPath $File -Raw
  $errs = $null
  if (-not (Test-Json -Json $text -SchemaFile (Join-Path $contracts "schemas/$Schema") -ErrorAction SilentlyContinue -ErrorVariable errs)) {
    Write-Host "RESULT FAIL the $What doesn't match $Schema`: $((@($errs) | ForEach-Object { $_.Exception.Message } | Select-Object -First 2) -join ' | ')"
    exit 1
  }
  $text | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $Path)) { Write-Host "RESULT ERROR no manifest at $Path"; exit 2 }
$paramPath = if ([IO.Path]::IsPathRooted($ParameterFile)) { $ParameterFile } else { Join-Path $repoRoot $ParameterFile }
if (-not (Test-Path -LiteralPath $paramPath)) { Write-Host "RESULT ERROR no parameter file at $ParameterFile"; exit 2 }
if (-not $ApprovalPath) { $ApprovalPath = [regex]::Replace($Path, '\.json$', '') + '.approval.json' }

$manifest = Read-ValidJson -File $Path -Schema 'target-state.schema.json' -What 'manifest'
$approval = Read-ValidJson -File $ApprovalPath -Schema 'target-approval.schema.json' -What 'approval'
$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
$capabilities = Get-Content -LiteralPath (Join-Path $contracts 'target-state-capabilities.json') -Raw | ConvertFrom-Json

$plan = Get-AvdTargetStatePlan -Manifest $manifest -ManifestSha256 $sha -Approval $approval -Capabilities $capabilities `
  -ParameterFileText (Get-Content -LiteralPath $paramPath -Raw) -ParameterFile $ParameterFile -HostPool $HostPool `
  -UsersGroup $UsersGroup -AdminsGroup $AdminsGroup -AlertEmail $AlertEmail

if ($plan.Refusals.Count) {
  foreach ($r in $plan.Refusals) { Write-Host "  REFUSED  $r" }
  Write-Host "RESULT FAIL $($plan.Refusals.Count) reason(s) this landing zone won't deploy the manifest"
  exit 1
}
foreach ($s in $plan.SetByHand) { Write-Host "  BY HAND  $s" }
Write-Host ''
Write-Host $plan.Block
Write-Host ''
Write-Host "RESULT PASS $($plan.Pool): $($plan.Values.SessionHostCount) x $($plan.Values.SessionHostVmSize), $($plan.Values.MaxSessionLimit) sessions per host, $($plan.Values.ProfileQuotaGiB) GiB profile share, $($plan.Values.Location)"
