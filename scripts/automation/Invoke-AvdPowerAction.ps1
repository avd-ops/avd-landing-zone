# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Stops, locks or resumes the landing zone's session hosts (auto shutdown, decision 0011).

.DESCRIPTION
  Runs as the landing zone's Azure Automation runbook, started by the auto-shutdown schedule or a
  budget alert, with the Automation account's managed identity. It also runs from Cloud Shell for
  a manual stop, lock or resume, with your own sign-in.

    Stop    Deallocates the session hosts that have no user sessions (all of them with
            -Force $true). The scaling plan and Start VM on Connect still start hosts when users
            come back.
    Lock    For a budget alert. The hosts stop taking new sessions (drain mode), the scaling plan
            skips them (its exclusion tag), Start VM on Connect is turned off, signed-in users get
            a message, and every host is deallocated. They stay off until Resume.
    Resume  Undoes Lock. Hosts start again on the next connection or the scaling plan's ramp-up.

  No modules: ARM REST with a token from the managed identity endpoint (or Get-AzAccessToken in
  Cloud Shell). Written for Windows PowerShell 5.1, the Automation sandbox default: no
  PowerShell 7-only syntax (build/lessons/0011).

.EXAMPLE
  ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume -NamePrefix avdlz -Environment dev
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateSet('Stop', 'Lock', 'Resume')][string] $Action,
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  # Required in Automation; in Cloud Shell the current subscription.
  [string] $SubscriptionId,
  # Why it ran (schedule, budget, manual): recorded on the host pool when locking.
  [string] $Reason = 'manual',
  # Stop: also deallocate hosts that have user sessions.
  [bool] $Force = $false
)

$ErrorActionPreference = 'Stop'
$apiAvd = '2024-04-03'; $apiVm = '2024-07-01'; $apiTags = '2021-04-01'
$lockTag = 'avdlz-power-lock'          # on the host pool while locked: "<reason> <UTC time>"
$exclusionTag = 'avd-scaling-exclude'  # the scaling plan's exclusion tag (bicep/modules/controlPlane.bicep)
$lockValue = 'avdlz-lock'

# ---------------------------------------------------------------- ARM
function Get-ArmToken {
  if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
    # Automation managed identity (no Az modules needed).
    $h = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True' }
    return (Invoke-RestMethod -Uri ($env:IDENTITY_ENDPOINT + '?resource=https://management.azure.com/') -Method Get -Headers $h).access_token
  }
  $t = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
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

function Invoke-Arm {
  param([string] $Method = 'GET', [Parameter(Mandatory)][string] $Path, $Body)
  $p = @{ Uri = "https://management.azure.com$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $script:Token" }; ContentType = 'application/json' }
  if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
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

# ---------------------------------------------------------------- landing zone
$script:Token = Get-ArmToken
if (-not $SubscriptionId) { $SubscriptionId = (Get-AzContext).Subscription.Id }
if (-not $SubscriptionId) { throw 'Pass -SubscriptionId.' }
$base = "$($NamePrefix.ToLower().Replace('-', ''))-$Environment"
$avdRg = "/subscriptions/$SubscriptionId/resourceGroups/rg-$base-avd"
$pools = @(Get-ArmList -Path "$avdRg/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$apiAvd")
$hp = $pools | Where-Object { $_.name -eq "vdpool-$base" } | Select-Object -First 1
if (-not $hp) { throw "No host pool vdpool-$base in rg-$base-avd." }
Write-Output "Auto shutdown: $Action for $($hp.name) ($Reason)"

$summary = [ordered]@{ action = $Action; hostPool = $hp.name; reason = $Reason; deallocated = @(); skipped = @(); alreadyStopped = @(); messaged = 0; changes = 0 }
$hosts = @(Get-ArmList -Path "$($hp.id)/sessionHosts?api-version=$apiAvd")

function Set-HostPoolLock {
  [CmdletBinding(SupportsShouldProcess)]
  param([bool] $Locked)
  $tags = @{}
  if ($hp.tags) { foreach ($p in $hp.tags.PSObject.Properties) { $tags[$p.Name] = $p.Value } }
  if ($Locked) { $tags[$lockTag] = "$Reason $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))" } else { $tags.Remove($lockTag) }
  # Resume restores what the deployment chose: the template tags the host pool
  # avdlz-start-vm-on-connect = false when Start VM on Connect is off.
  $startOnConnect = (-not $Locked) -and ($tags['avdlz-start-vm-on-connect'] -ne 'false')
  $verb = if ($Locked) { 'Turn off Start VM on Connect and mark the host pool locked' } elseif ($startOnConnect) { 'Turn Start VM on Connect back on and clear the lock' } else { 'Clear the lock (Start VM on Connect stays off, as deployed)' }
  if ($PSCmdlet.ShouldProcess($hp.name, $verb)) {
    Invoke-Arm -Method PATCH -Path "$($hp.id)?api-version=$apiAvd" -Body @{ tags = $tags; properties = @{ startVMOnConnect = $startOnConnect } } | Out-Null
    $summary.changes++
    Write-Output "  $($hp.name): $verb"
  }
}

function Get-PowerState {
  param([string] $VmId)
  $iv = Invoke-Arm -Path "$VmId/instanceView?api-version=$apiVm"
  $s = @($iv.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1)
  if ($s) { return ($s[0].code -replace '^PowerState/', '') }
  return 'unknown'
}

if ($Action -eq 'Lock') { Set-HostPoolLock -Locked $true }

foreach ($sh in $hosts) {
  $shName = ($sh.name -split '/')[-1]
  $vmId = $sh.properties.resourceId
  $sessions = [int]$sh.properties.sessions
  $shPath = "$($hp.id)/sessionHosts/$shName"

  if ($Action -eq 'Lock' -or $Action -eq 'Resume') {
    $locking = $Action -eq 'Lock'
    if ($PSCmdlet.ShouldProcess($shName, $(if ($locking) { 'Drain, and exclude from the scaling plan' } else { 'Allow new sessions, and include in the scaling plan' }))) {
      Invoke-Arm -Method PATCH -Path "$shPath`?api-version=$apiAvd" -Body @{ properties = @{ allowNewSession = (-not $locking) } } | Out-Null
      if ($vmId) {
        Invoke-Arm -Method PATCH -Path "$vmId/providers/Microsoft.Resources/tags/default?api-version=$apiTags" -Body @{ operation = $(if ($locking) { 'Merge' } else { 'Delete' }); properties = @{ tags = @{ $exclusionTag = $lockValue } } } | Out-Null
      }
      $summary.changes++
      Write-Output "  $shName`: $(if ($locking) { 'drained, excluded from the scaling plan' } else { 'taking sessions, back in the scaling plan' })"
    }
    if ($locking -and $sessions -gt 0) {
      foreach ($us in @(Get-ArmList -Path "$shPath/userSessions?api-version=$apiAvd")) {
        $id = ($us.name -split '/')[-1]
        if ($PSCmdlet.ShouldProcess("$shName session $id", 'Send the shutdown message')) {
          Invoke-Arm -Method POST -Path "$shPath/userSessions/$id/sendMessage?api-version=$apiAvd" -Body @{ messageTitle = 'Desktop shutting down'; messageBody = 'The desktop is shutting down because its budget has been reached. Save your work now.' } | Out-Null
          $summary.messaged++
        }
      }
    }
  }

  if ($Action -eq 'Resume' -or -not $vmId) { continue }
  if ($Action -eq 'Stop' -and $sessions -gt 0 -and -not $Force) {
    $summary.skipped += $shName
    Write-Output "  $shName`: skipped ($sessions user session(s); -Force `$true stops it anyway)"
    continue
  }
  $state = Get-PowerState -VmId $vmId
  if ($state -eq 'deallocated' -or $state -eq 'deallocating') { $summary.alreadyStopped += $shName; Write-Output "  $shName`: already $state"; continue }
  if ($PSCmdlet.ShouldProcess($shName, 'Deallocate')) {
    Invoke-Arm -Method POST -Path "$vmId/deallocate?api-version=$apiVm" | Out-Null
    $summary.deallocated += $shName; $summary.changes++
    Write-Output "  $shName`: deallocating (was $state)"
  }
}

if ($Action -eq 'Resume') { Set-HostPoolLock -Locked $false }

Write-Output ("Done: {0} deallocated, {1} skipped, {2} already stopped, {3} user(s) messaged." -f $summary.deallocated.Count, $summary.skipped.Count, $summary.alreadyStopped.Count, $summary.messaged)
# Machine-readable result (tests, and the deployment portal when run from Cloud Shell).
$state = [ordered]@{ v = 1; stage = 'power'; status = $(if ($Action -eq 'Lock') { 'locked' } elseif ($Action -eq 'Resume') { 'resumed' } else { 'stopped' }); context = [ordered]@{ namePrefix = $NamePrefix; environment = $Environment }; power = $summary }
Write-Output "<<<AVDLZ-STATE $($state | ConvertTo-Json -Compress -Depth 6) AVDLZ-STATE>>>"
