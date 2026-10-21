#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Is the sandbox ready to spend? Read-only checks before a run or a batch group starts, each
  failure with what fixes it (docs/sandbox-runs.md).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell), signed in. Checks: the sign-in; deployments and role
  assignments allowed on the subscription (your ARM permissions); Entra devices readable, and none
  named exactly like this landing zone's hosts (<prefix><e>sh-<n>, <prefix><e>demo-<n>, and the
  blue/green generations) while no
  VM in any subscription you can read carries that name, because a new host of the same name
  can't join; no resource groups rg-<prefix>-<env>-* left by an earlier run; the run store when
  asked; the caps set, and the estimate within the run cap.

  It reads and never writes: it grants no permission and deletes nothing, leftover devices
  included. API errors are reported as they came back, never read as "nothing there".
  Invoke-AvdSandboxBatch.ps1 runs it before a group starts.

  Exit 0 healthy, 1 a check failed. -JsonPath also writes the results as JSON.

.EXAMPLE
  ./scripts/ops/Test-AvdSandboxHealth.ps1 -MonthlyCap 150 -RunCap 25 -Estimate 2.75

.EXAMPLE
  ./scripts/ops/Test-AvdSandboxHealth.ps1 -NamePrefix lab1 -Environment dev -NeedsRunStore
#>
[CmdletBinding()]
param(
  [ValidateLength(2, 8)][string] $NamePrefix = 'avdlz',
  [ValidateSet('dev', 'test', 'prod')][string] $Environment = 'dev',
  [double] $MonthlyCap = $(if ($env:SPEND_MONTHLY_CAP) { [double]$env:SPEND_MONTHLY_CAP } else { 0 }),
  [double] $RunCap = $(if ($env:SPEND_RUN_CAP) { [double]$env:SPEND_RUN_CAP } else { 0 }),
  [Nullable[double]] $Estimate,
  [switch] $NeedsRunStore,
  [string] $SubscriptionId,
  [string] $JsonPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSpend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdSandboxBatch.psm1') -Force

# Every page of a list (ARM nextLink, Graph @odata.nextLink), at most 50 (lesson 0008).
function Get-HealthList([string] $Url) {
  $items = @(); $page = 0
  while ($Url -and $page -lt 50) {
    $page++
    $r = Invoke-AvdSpendArm -Path $Url
    $items += @($r.value | Where-Object { $_ })
    $Url = if ($r.PSObject.Properties['@odata.nextLink']) { $r.'@odata.nextLink' } elseif ($r.PSObject.Properties['nextLink']) { $r.nextLink } else { $null }
  }
  $items
}

Write-Host 'Checking the sandbox before anything is spent ...' -ForegroundColor DarkGray
$prefixes = @(Get-AvdHostDevicePrefix -NamePrefix $NamePrefix -Environment $Environment)
$facts = @{ namePrefix = $NamePrefix; environment = $Environment; monthlyCap = $MonthlyCap; runCap = $RunCap; estimate = $Estimate; needsRunStore = [bool]$NeedsRunStore }
try { $ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId; $facts.signedIn = $true }
catch { $facts.signedIn = $false; $facts.signInError = $_.Exception.Message }
if ($facts.signedIn) {
  $sub = $ctx.Subscription.Id
  $facts.subscriptionName = $ctx.Subscription.Name

  Write-Host '  Reading your permissions on the subscription ...' -ForegroundColor DarkGray
  try { $facts.permissions = @(Get-HealthList "/subscriptions/$sub/providers/Microsoft.Authorization/permissions?api-version=2022-04-01") }
  catch { $facts.permissions = @(); $facts.permissionsError = $_.Exception.Message }

  Write-Host '  Listing resource groups from Resource Graph ...' -ForegroundColor DarkGray
  try { $facts.leftoverGroups = @(Get-AvdSpendInventory -SubscriptionId $sub | Where-Object { $_.type -eq 'microsoft.resources/subscriptions/resourcegroups' -and $_.name -like "rg-$NamePrefix-$Environment-*" } | ForEach-Object { $_.name }) }
  catch { $facts.groupsError = $_.Exception.Message }

  # One read per host prefix also proves Graph access.
  Write-Host '  Reading Entra devices named like the landing zone hosts ...' -ForegroundColor DarkGray
  $devices = @(); $facts.graphStatus = 200
  # Ten characters, so a blue/green generation's hosts (take(prefix, 10) + a or b) come back too.
  foreach ($p in @($prefixes | ForEach-Object { $_.Substring(0, [math]::Min(10, $_.Length)) } | Select-Object -Unique)) {
    try { $devices += @(Get-HealthList "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$p')&`$select=displayName") }
    catch {
      $msg = $_.Exception.Message
      $facts.graphStatus = if ($msg -match 'failed \((\d{3})\)') { [int]$Matches[1] } else { 0 }
      $facts.graphError = $msg; break
    }
  }
  if ($facts.graphStatus -eq 200 -and $devices.Count) {
    # VMs in every subscription you can read (Resource Graph with no subscription list), by
    # resource name and computer name, so a host in another subscription is never called stale.
    Write-Host '  Looking for VMs with those names in every subscription you can read ...' -ForegroundColor DarkGray
    $vmNames = @(); $skip = $null; $page = 0
    try {
      do {
        $page++
        $body = @{ query = "resources | where type =~ 'microsoft.compute/virtualmachines' | project name, type = tolower(type), computerName = tostring(properties.osProfile.computerName)"; options = @{ '$top' = 1000 } }
        if ($skip) { $body.options['$skipToken'] = $skip }
        $r = Invoke-AvdSpendArm -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body $body
        $vmNames += @($r.data | Where-Object { $_ -and $_.type -eq 'microsoft.compute/virtualmachines' } | ForEach-Object { $_.name; if ($_.PSObject.Properties['computerName']) { $_.computerName } })
        $skip = if ($r.PSObject.Properties['$skipToken']) { $r.'$skipToken' } else { $null }
      } while ($skip -and $page -lt 50)
      $facts.staleDevices = @(Get-AvdStaleHostDevice -Devices $devices -Prefix $prefixes -VmName $vmNames)
    }
    # Without the VM list no device can be called stale or clean: report it as it came back.
    catch { $facts.vmError = $_.Exception.Message }
  }

  if ($NeedsRunStore) {
    $name = Get-AvdRunStoreName -SubscriptionId $sub
    try { $facts.runStore = if (Invoke-AvdSpendArm -Path "/subscriptions/$sub/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/$name`?api-version=2023-05-01" -AllowNotFound) { $name } else { '' } }
    catch {
      $facts.runStore = ''
      # No resource group yet is the ordinary "not set up"; anything else is reported as it came.
      if ($_.Exception.Message -notmatch 'ResourceGroupNotFound') { $facts.runStoreError = $_.Exception.Message }
    }
  }
}

$results = @(Get-AvdSandboxHealthResult -Facts $facts)
foreach ($c in $results) {
  $tag = if ($c.ok) { '[PASS ]' } else { '[FAIL ]' }
  Write-Host "  $tag $($c.check): $($c.detail)" -ForegroundColor $(if ($c.ok) { 'Green' } else { 'Red' })
  if (-not $c.ok -and $c.fix) { Write-Host "          -> $($c.fix)" -ForegroundColor Yellow }
}
$failed = @($results | Where-Object { -not $_.ok }).Count
if ($JsonPath) { [ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); healthy = -not $failed; results = $results } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JsonPath -Encoding utf8NoBOM }
if ($failed) { Write-Host "Not healthy: $failed check(s) failed. Nothing was deployed or spent." -ForegroundColor Red; exit 1 }
Write-Host 'Healthy.' -ForegroundColor Green
exit 0
