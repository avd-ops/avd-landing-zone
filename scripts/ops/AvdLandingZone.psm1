#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
  Shared functions for the landing-zone operations scripts:
    Test-AvdLandingZoneReadiness.ps1  preflight (check / -Fix)
    Deploy-AvdDemo.ps1                demo host pool + login-readiness validation
    Remove-AvdDemo.ps1                cleanup

  Designed for Azure Cloud Shell (PowerShell): Az modules are already signed
  in there, and Microsoft Graph is reached through Microsoft.Graph.Authentication
  (device-code sign-in in Cloud Shell).
#>

# =====================================================================
# Result reporting
# =====================================================================
$script:Results = [System.Collections.Generic.List[object]]::new()

function Clear-AvdCheckResult { $script:Results.Clear() }

function Get-AvdCheckResult { , $script:Results.ToArray() }

function Write-AvdSection {
  param([Parameter(Mandatory)][string] $Title)
  Write-Host ''
  Write-Host "== $Title" -ForegroundColor White
}

function Add-AvdCheckResult {
  param(
    [Parameter(Mandatory)][string] $Area,
    [Parameter(Mandatory)][string] $Check,
    [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Fixed', 'Skip')][string] $Status,
    [string] $Detail = '',
    [string] $Remediation = '',
    # Stable identifier and structured data for the deployment portal (see Write-AvdPortalState).
    [string] $Id = '',
    [hashtable] $Data
  )
  $script:Results.Add([pscustomobject]@{
      Area        = $Area
      Check       = $Check
      Status      = $Status
      Detail      = $Detail
      Remediation = $Remediation
      Id          = $Id
      Data        = $Data
    })
  if ($env:AVDLZ_RECORD) { Write-AvdJournalEvent 'check' ([ordered]@{ step = $script:JournalStep.Name; id = $Id; status = $Status; area = $Area; check = $Check; data = $Data }) }
  $color = @{ Pass = 'Green'; Fixed = 'Cyan'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Status]
  Write-Host ('  [{0,-5}] {1}' -f $Status.ToUpper(), $Check) -ForegroundColor $color
  if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
  if ($Remediation -and $Status -in 'Fail', 'Warn') { Write-Host "          -> $Remediation" -ForegroundColor DarkYellow }
}

# The portal the scripts point operators to: the published one on GitHub Pages, or a copy in the
# operator's own subscription (Publish-AvdPortal.ps1 prints the AVD_PORTAL_URL to set; decision 0017).
$script:DefaultPortalUrl = 'https://nickprignano.github.io/avd-landing-zone/portal/'

function Get-AvdPortalUrl {
  <# The portal URL to print: $env:AVD_PORTAL_URL when it is an https URL, else the GitHub Pages portal. #>
  param([string] $Url = $env:AVD_PORTAL_URL)
  if ($Url -match '^https://[A-Za-z0-9.-]+(/[^\s"''<>]*)?$') { return $(if ($Url.EndsWith('/')) { $Url } else { "$Url/" }) }
  $script:DefaultPortalUrl
}

function Get-AvdRepoCommit {
  <# The short commit of this checkout, once per run; $null without git or outside a clone. #>
  if ($script:RepoCommitRead) { return $script:RepoCommit }
  $script:RepoCommitRead = $true
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $c = git -C $PSScriptRoot rev-parse --short HEAD 2>$null
    if (-not $LASTEXITCODE -and "$c" -match '^[0-9a-f]{7,40}$') { $script:RepoCommit = "$c" }
  }
  $script:RepoCommit
}

function Get-AvdPortalState {
  <#
    Machine-readable result of a run for the deployment portal (site/portal): what stage ran,
    whether it succeeded, the context needed to build the next command, and every failure and
    warning with its stable Id and Data. Schema: site/portal/README.md.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('predeploy', 'postdeploy', 'demo', 'cleanup', 'verify', 'resume', 'recovery', 'rotation')][string] $Stage,
    [switch] $Fix,
    [hashtable] $Context = @{},
    # A stage-specific outcome (verify: verified, failed, notverified) instead of ready/notready.
    [string] $Status
  )
  $all = @(Get-AvdCheckResult | ForEach-Object { $_ })
  $trim = { param($t) if ($t -and $t.Length -gt 400) { $t.Substring(0, 400) + '...' } else { $t } }
  $item = {
    param($r)
    $o = [ordered]@{ id = $r.Id; area = $r.Area; check = $r.Check; detail = (& $trim $r.Detail); remediation = (& $trim $r.Remediation) }
    if ($r.Data) { $o.data = $r.Data }
    $o
  }
  $failed = @($all | Where-Object Status -eq 'Fail')
  $counts = [ordered]@{}
  foreach ($st in 'Pass', 'Fail', 'Warn', 'Fixed', 'Skip') { $counts[$st.ToLower()] = @($all | Where-Object Status -eq $st).Count }
  [ordered]@{
    v        = 1
    stage    = $Stage
    status   = if ($Status) { $Status } elseif ($failed.Count) { 'notready' } else { 'ready' }
    fix      = [bool]$Fix
    context  = $Context
    counts   = $counts
    failures = @($failed | ForEach-Object { & $item $_ })
    warnings = @($all | Where-Object Status -eq 'Warn' | ForEach-Object { & $item $_ })
  }
}

function Write-AvdPortalState {
  <# Prints the portal state between markers. The portal reads it from anything pasted around it. #>
  param([Parameter(Mandatory)] $State)
  # The commit the scripts ran from, so the portal can tell when it is older than them (red team PH-8).
  $commit = Get-AvdRepoCommit
  if ($commit -and $State.context -is [System.Collections.IDictionary] -and -not $State.context.Contains('commit')) { $State.context['commit'] = $commit }
  $json = $State | ConvertTo-Json -Compress -Depth 8
  Write-Host ''
  $portal = Get-AvdPortalUrl
  Write-Host "Deployment portal: paste this output into $portal for the next step." -ForegroundColor DarkGray
  # An override is spelled out, so an unexpected host stands out (red team PH-5).
  if ($portal -ne $script:DefaultPortalUrl) { Write-Host "Portal host: $(([uri]$portal).Host), set by AVD_PORTAL_URL" -ForegroundColor DarkGray }
  Write-Host "<<<AVDLZ-STATE $json AVDLZ-STATE>>>" -ForegroundColor DarkGray
  if ($env:AVDLZ_RECORD) {
    $sec = if ($script:JournalStep) { [math]::Round(([datetime]::UtcNow - $script:JournalStep.Started).TotalSeconds, 1) } else { $null }
    Write-AvdJournalEvent 'step.end' ([ordered]@{ step = $script:JournalStep.Name; durationSec = $sec; state = $State })
  }
}

function Write-AvdSummary {
  $all = Get-AvdCheckResult
  $counts = $all | Group-Object Status | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
  Write-Host ''
  Write-Host "== Summary: $($counts -join ', ')" -ForegroundColor White
  $open = @($all | Where-Object Status -in 'Fail', 'Warn')
  if ($open.Count) {
    $open | Format-Table Status, Area, Check, Remediation -AutoSize -Wrap | Out-String -Width 200 | Write-Host
  }
  return [pscustomobject]@{
    Failed  = @($all | Where-Object Status -eq 'Fail').Count
    Warned  = @($all | Where-Object Status -eq 'Warn').Count
    Results = $all
  }
}

# =====================================================================
# Run journal (build/specs/run-recorder-spec.md section 6): opt in with AVDLZ_RECORD and
# AVDLZ_RUN_ID; one JSON object per line, schema contracts/schemas/run-journal.schema.json
# (avd-second-brain contract C17, vendored). Without both
# variables nothing is written. A journal that can't be written warns once and never stops the run.
# =====================================================================
$script:JournalRunIdPattern = '^run-\d{8}-\d{4}-[a-z0-9]{4}$'
$script:JournalSecretName = '(?i)password|secret|token|credential|sas|key'
$script:JournalWarned = $false
$script:JournalStep = $null

function Get-AvdJournalSetting {
  <# Where the journal goes, from the two variables and the shell's home. Pure: returns Enabled and Path, or Enabled $false and Reason. #>
  param(
    [string] $Record,
    [string] $RunId,
    [Parameter(Mandatory)][string] $HomePath,
    [bool] $CloudDriveExists
  )
  if (-not $Record -or $Record -eq 'off') { return [pscustomobject]@{ Enabled = $false; Reason = 'off' } }
  if ($Record -notin 'on', 'azure') { return [pscustomobject]@{ Enabled = $false; Reason = "AVDLZ_RECORD must be on, azure or off, not '$Record'." } }
  if ($RunId -cnotmatch $script:JournalRunIdPattern) { return [pscustomobject]@{ Enabled = $false; Reason = 'AVDLZ_RUN_ID is missing or not a run ID (run-yyyyMMdd-HHmm-xxxx); the portal generates one.' } }
  # Azure mode writes the local journal too; the run store upload comes with Start-AvdRunRecorder (section 6.3).
  $root = if ($CloudDriveExists) { Join-Path $HomePath 'clouddrive' } else { $HomePath }
  $folder = Join-Path (Join-Path $root 'avdlz-runs') $RunId
  [pscustomobject]@{ Enabled = $true; Mode = $Record; RunId = $RunId; Folder = $folder; Path = (Join-Path $folder 'journal.jsonl'); Durable = $CloudDriveExists }
}

function Get-AvdJournalParam {
  <# A script's parameters for the journal: secrets and anything named like one become '<set>', switches become booleans. #>
  param([System.Collections.IDictionary] $Parameter)
  $o = [ordered]@{}
  if (-not $Parameter) { return $o }
  foreach ($k in @($Parameter.Keys | Sort-Object)) {
    $v = $Parameter[$k]
    $o[$k] = if ($v -is [securestring] -or $v -is [pscredential] -or $k -match $script:JournalSecretName) { '<set>' }
    elseif ($v -is [switch]) { [bool]$v }
    elseif ($null -eq $v) { $null }
    elseif ($v -is [array]) { @($v | ForEach-Object { "$_" }) }
    else { "$v" }
  }
  $o
}

function Get-AvdJournalEvent {
  <# One journal line as an ordered dictionary: v, event, runId, ts, then the event's fields. #>
  param(
    [Parameter(Mandatory)][ValidateSet('step.start', 'check', 'api.error', 'step.end', 'operator.note')][string] $Name,
    [Parameter(Mandatory)][string] $RunId,
    [System.Collections.IDictionary] $Field = @{},
    [datetime] $Now = [datetime]::UtcNow
  )
  $e = [ordered]@{ v = 1; event = $Name; runId = $RunId; ts = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
  foreach ($k in $Field.Keys) { $e[$k] = $Field[$k] }
  $e
}

function Write-AvdJournalEvent {
  param(
    [Parameter(Mandatory, Position = 0)][string] $Name,
    [Parameter(Position = 1)][System.Collections.IDictionary] $Field = @{},
    [string] $HomePath = $(if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') })
  )
  $cfg = Get-AvdJournalSetting -Record $env:AVDLZ_RECORD -RunId $env:AVDLZ_RUN_ID -HomePath $HomePath -CloudDriveExists (Test-Path (Join-Path $HomePath 'clouddrive'))
  if (-not $cfg.Enabled) {
    if ($cfg.Reason -ne 'off' -and -not $script:JournalWarned) { $script:JournalWarned = $true; Write-Warning "Run journal off: $($cfg.Reason)" }
    return
  }
  try {
    if (-not (Test-Path $cfg.Folder)) { $null = New-Item -ItemType Directory -Path $cfg.Folder -Force -ErrorAction Stop }
    $line = Get-AvdJournalEvent -Name $Name -RunId $cfg.RunId -Field $Field | ConvertTo-Json -Compress -Depth 10
    Add-Content -LiteralPath $cfg.Path -Value $line -Encoding utf8 -ErrorAction Stop
  }
  catch {
    if (-not $script:JournalWarned) { $script:JournalWarned = $true; Write-Warning "Run journal not written ($($cfg.Path)): $($_.Exception.Message)" }
  }
}

function Start-AvdRunJournal {
  <# step.start for the script that called Initialize-AvdAzContext: its name, parameters and commit. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([System.Management.Automation.InvocationInfo] $Invocation)
  if (-not $env:AVDLZ_RECORD -or $env:AVDLZ_RECORD -eq 'off' -or -not $Invocation) { return }
  if (-not $PSCmdlet.ShouldProcess('run journal', 'Write step.start')) { return }
  $script:JournalStep = [pscustomobject]@{ Name = if ($Invocation.MyCommand.Name) { $Invocation.MyCommand.Name } else { 'interactive' }; Started = [datetime]::UtcNow }
  $commit = Get-AvdRepoCommit
  Write-AvdJournalEvent 'step.start' ([ordered]@{
      step = $script:JournalStep.Name; portalStep = $env:AVDLZ_PORTAL_STEP; params = (Get-AvdJournalParam $Invocation.BoundParameters)
      repoCommit = $commit; shell = 'pwsh'; cloudShell = (Test-AvdCloudShell)
    })
}

function Add-AvdRunNote {
  <# Records what was done by hand ("I set X in the Azure portal") in the run journal. #>
  param([Parameter(Mandatory, Position = 0)][string] $Text)
  if (-not $env:AVDLZ_RECORD -or $env:AVDLZ_RECORD -eq 'off') { Write-Warning 'Recording is off: set AVDLZ_RECORD and AVDLZ_RUN_ID as the portal shows.'; return }
  Write-AvdJournalEvent 'operator.note' ([ordered]@{ step = $script:JournalStep.Name; text = $Text })
}

# =====================================================================
# Azure context, ARM and Graph helpers
# =====================================================================
function Test-AvdCloudShell {
  [bool]$env:ACC_CLOUD -or ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*')
}

function Initialize-AvdAzContext {
  param([string] $SubscriptionId)
  foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Storage') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "PowerShell module $m is required (preinstalled in Azure Cloud Shell)." }
  }
  $ctx = Get-AzContext
  if (-not $ctx) { throw 'Not signed in to Azure. Run Connect-AzAccount (Cloud Shell does this for you).' }
  if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
    $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
  }
  if ($env:AVDLZ_RECORD) { Start-AvdRunJournal -Invocation (Get-PSCallStack)[1].InvocationInfo }
  return $ctx
}

function Invoke-AvdArm {
  param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('GET', 'PUT', 'PATCH', 'DELETE', 'POST')][string] $Method = 'GET',
    [object] $Body,
    [switch] $AllowNotFound
  )
  $p = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
  if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 30 -Compress) }
  $r = Invoke-AzRestMethod @p
  if ($AllowNotFound -and $r.StatusCode -eq 404) { return $null }
  if ($r.StatusCode -ge 400) {
    if ($env:AVDLZ_RECORD) {
      $code = try { ($r.Content | ConvertFrom-Json -ErrorAction Stop).error.code } catch { $null }
      $corr = if ($r.Headers) { try { @($r.Headers['x-ms-correlation-request-id'])[0] } catch { $null } }
      $body = if ($r.Content -and $r.Content.Length -gt 2000) { $r.Content.Substring(0, 2000) + '...' } else { $r.Content }
      Write-AvdJournalEvent 'api.error' ([ordered]@{ step = $script:JournalStep.Name; api = 'arm'; method = $Method; path = $Path; status = [int]$r.StatusCode; code = $code; body = $body; correlationId = $corr })
    }
    throw "ARM $Method $Path failed ($($r.StatusCode)): $($r.Content)"
  }
  if ($r.Content) { return $r.Content | ConvertFrom-Json -Depth 30 }
}

# One scope set for every script, so the first Microsoft Graph sign-in covers the whole Cloud Shell
# session: preflight, -Fix, the demo and the cleanup (decision 0016). The purposes only change the message.
$script:GraphScopes = @(
  'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess',
  'Group.ReadWrite.All', 'Directory.Read.All', 'Device.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All'
)
$script:GraphPurposes = @{
  Read         = 'the tenant checks'
  Fix          = 'the tenant fixes'
  PreDeployFix = 'creating the groups and the AVD service principal'
  Cleanup      = "deleting the hosts' device objects"
  SignIn       = 'every landing zone script in this Cloud Shell session'
}
# Created by Initialize-AvdGraphApp.ps1, which keeps its own copy of the scopes (a unit test compares them).
$script:GraphOperatorAppName = 'avd-opsbot'

function Get-AvdGraphScope {
  <# The scopes a purpose signs in with: the same set for every one (decision 0016). #>
  param([ValidateSet('Read', 'Fix', 'PreDeployFix', 'Cleanup', 'SignIn')][string] $Purpose = 'Read')
  $null = $Purpose
  $script:GraphScopes
}

function Get-AvdGraphClientId {
  <# The operator app's client ID: the parameter, else $env:AVD_GRAPH_CLIENT_ID; empty means Microsoft's default app. #>
  param([string] $ClientId)
  $id = if ($ClientId) { $ClientId } else { $env:AVD_GRAPH_CLIENT_ID }
  if (-not $id) { return $null }
  $id = $id.Trim()
  $guid = [guid]::Empty
  if (-not [guid]::TryParse($id, [ref]$guid)) { throw "AVD_GRAPH_CLIENT_ID '$id' is not a client ID (a GUID). Run scripts/ops/Initialize-AvdGraphApp.ps1, or clear it: Remove-Item Env:AVD_GRAPH_CLIENT_ID" }
  return $id
}

function Connect-AvdGraph {
  param(
    [ValidateSet('Read', 'Fix', 'PreDeployFix', 'Cleanup', 'SignIn')][string] $Purpose = 'Read',
    # Defaults to $env:AVD_GRAPH_CLIENT_ID; without one, Microsoft's default app.
    [string] $ClientId
  )
  $scopes = Get-AvdGraphScope -Purpose $Purpose
  $ClientId = Get-AvdGraphClientId -ClientId $ClientId
  if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
  }
  Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
  $tenantId = (Get-AzContext).Tenant.Id
  $ctx = Get-MgContext
  # An existing sign-in is reused when it covers every scope ('X.ReadWrite.All' covers 'X.Read.All').
  # With a client ID set, only a sign-in through that app counts: a default-app sign-in that already
  # has the scopes (from earlier consent) would otherwise keep the operator app from ever being used.
  $missing = @($scopes | Where-Object { $_ -notin $ctx.Scopes -and $_.Replace('.Read.', '.ReadWrite.') -notin $ctx.Scopes })
  $sameApp = -not $ClientId -or $ctx.ClientId -eq $ClientId
  if ($ctx -and $ctx.TenantId -eq $tenantId -and $sameApp -and -not $missing.Count) {
    if (Test-AvdGraphToken) { return }
    Write-Host '  The existing Microsoft Graph sign-in cannot get a token; signing in again.' -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
  }
  $app = if ($ClientId) { "the $script:GraphOperatorAppName app ($ClientId)" } else { "Microsoft's default app (no AVD_GRAPH_CLIENT_ID set)" }
  Write-Host "  Signing in to Microsoft Graph for $($script:GraphPurposes[$Purpose]), through $app" -ForegroundColor DarkGray
  Write-Host "  Scopes: $($scopes -join ', ')" -ForegroundColor DarkGray
  $connect = @{ Scopes = $scopes; TenantId = $tenantId; NoWelcome = $true; ErrorAction = 'Stop' }
  if ($ClientId) { $connect.ClientId = $ClientId }
  if (Test-AvdCloudShell) {
    $connect.UseDeviceCode = $true
    Write-Host '  ACTION NEEDED: open https://microsoft.com/devicelogin and enter the code below. The script waits until you sign in.' -ForegroundColor Yellow
  }
  # Connect-MgGraph writes the device-code message to the output stream. Send it to the
  # host so it is shown even when this runs inside a function whose output is captured.
  try { Connect-MgGraph @connect | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow } }
  catch {
    if (-not $ClientId) { throw }
    # The full error first (lesson 0012); the codes below are the usual causes with the operator app.
    throw ("Microsoft Graph sign-in through $app failed: $($_.Exception.Message)`n" +
      "AADSTS50105: you are not assigned to the app; add yourself to its operators group, or run Initialize-AvdGraphApp.ps1 again as an administrator.`n" +
      "AADSTS65001: consent is missing for a scope; run Initialize-AvdGraphApp.ps1 again.`n" +
      "AADSTS700016: the app does not exist in this tenant; check AVD_GRAPH_CLIENT_ID.`n" +
      'To use Microsoft''s default app instead: Remove-Item Env:AVD_GRAPH_CLIENT_ID')
  }
  if (-not (Test-AvdGraphToken)) {
    throw 'Signed in to Microsoft Graph, but requests still fail to get a token. Run Disconnect-MgGraph, close and reopen Cloud Shell, and try again.'
  }
}

function Test-AvdGraphToken {
  <#
    False only when the sign-in cannot produce a token. A permission error (403)
    still proves a token was issued, so it counts as working.
  #>
  $graphErr = $null; $r = $null
  try { $r = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id' -OutputType PSObject -ErrorAction Stop -ErrorVariable graphErr }
  catch { $graphErr = @($_) }
  if ($graphErr) { return "$($graphErr[0])" -notmatch 'authentication failed|Credential|token' }
  return $null -ne $r
}

function Invoke-AvdGraph {
  param(
    [Parameter(Mandatory)][string] $Uri,
    [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method = 'GET',
    [object] $Body
  )
  $p = @{ Method = $Method; OutputType = 'PSObject'; ErrorAction = 'Stop' }
  if ($null -ne $Body) {
    $p.Body = ($Body | ConvertTo-Json -Depth 30)
    $p.ContentType = 'application/json'
  }
  if ($Method -ne 'GET') { return Invoke-MgGraphRequest @p -Uri $Uri }
  $items = [System.Collections.Generic.List[object]]::new()
  $next = $Uri
  while ($next) {
    $graphErr = $null
    $r = Invoke-MgGraphRequest @p -Uri $next -ErrorVariable graphErr
    # A failed request must end the loop, even if the error came back non-terminating.
    if ($graphErr) { throw "Graph GET $next failed: $($graphErr[0])" }
    if ($null -eq $r) { throw "Graph GET $next returned no response." }
    if ($r.PSObject.Properties['value']) {
      foreach ($v in $r.value) { $items.Add($v) }
      $link = $r.PSObject.Properties['@odata.nextLink']
      $next = if ($link) { $link.Value } else { $null }
    }
    else { return $r }
  }
  # Emit the items (not one array object) so callers can wrap the call in @() safely.
  return $items.ToArray()
}

function Get-AvdGraphFilterUri {
  param([Parameter(Mandatory)][string] $Collection, [Parameter(Mandatory)][string] $Filter, [string] $Select)
  $uri = "v1.0/$Collection`?`$filter=$([uri]::EscapeDataString($Filter))"
  if ($Select) { $uri += "&`$select=$Select" }
  return $uri
}

# =====================================================================
# Identity helpers
# =====================================================================
function ConvertTo-AvdEntraSid {
  <# The SID Windows and Azure Files use for a cloud (Entra ID) object. #>
  param([Parameter(Mandatory)][guid] $ObjectId)
  $bytes = $ObjectId.ToByteArray()
  $parts = 0..3 | ForEach-Object { [BitConverter]::ToUInt32($bytes, $_ * 4) }
  return "S-1-12-1-$($parts -join '-')"
}

function Get-AvdGroupSid {
  <# Synced groups keep their AD SID in Kerberos tickets; cloud groups use the S-1-12-1 form. #>
  param([Parameter(Mandatory)][string] $GroupId)
  $g = Invoke-AvdGraph -Uri "v1.0/groups/$GroupId`?`$select=id,displayName,onPremisesSecurityIdentifier"
  $sid = if ($g.onPremisesSecurityIdentifier) { $g.onPremisesSecurityIdentifier } else { ConvertTo-AvdEntraSid $g.id }
  return [pscustomobject]@{ Id = $g.id; DisplayName = $g.displayName; Sid = $sid; Synced = [bool]$g.onPremisesSecurityIdentifier }
}

function Get-AvdRandomPassword {
  <# 24 random characters with every Windows complexity class, as a SecureString. #>
  param([int] $Length = 24)
  $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%*-_=+?')
  $all = -join $sets
  $chars = [System.Collections.Generic.List[char]]::new()
  foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
  while ($chars.Count -lt $Length) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
  $secure = [System.Security.SecureString]::new()
  $chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) } | ForEach-Object { $secure.AppendChar($_) }
  $secure.MakeReadOnly()
  return $secure
}

# =====================================================================
# Landing zone discovery
# =====================================================================
function Get-AvdRoleAssigneeId {
  <# Object ID holding a role at exactly this scope (not inherited). #>
  param([Parameter(Mandatory)][string] $Scope, [Parameter(Mandatory)][string] $RoleName, [string] $ObjectType)
  $a = Get-AzRoleAssignment -Scope $Scope -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue |
    Where-Object { $_.Scope -eq $Scope -and (-not $ObjectType -or $_.ObjectType -eq $ObjectType) } |
    Select-Object -First 1
  if ($a) { return $a.ObjectId }
}

function Get-AvdPrivateEndpointDnsZoneId {
  <#
    Private DNS zone behind the private endpoint that fronts $TargetResourceId, or $null.
    Searches the whole subscription: the template puts each private endpoint in its
    target's resource group (storage, avd, demo), not the network one.
  #>
  param([Parameter(Mandatory)][string] $SubscriptionId, [Parameter(Mandatory)][string] $TargetResourceId)
  $pes = Invoke-AvdArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Network/privateEndpoints?api-version=2024-05-01"
  foreach ($pe in @($pes.value)) {
    $targets = @($pe.properties.privateLinkServiceConnections) + @($pe.properties.manualPrivateLinkServiceConnections) |
      Where-Object { $_ } | ForEach-Object { $_.properties.privateLinkServiceId }
    if ($targets -contains $TargetResourceId) {
      $groups = Invoke-AvdArm -Path "$($pe.id)/privateDnsZoneGroups?api-version=2024-05-01"
      $zone = @($groups.value) | ForEach-Object { $_.properties.privateDnsZoneConfigs } | Select-Object -First 1
      return [pscustomobject]@{ PrivateEndpointId = $pe.id; DnsZoneId = if ($zone) { $zone.properties.privateDnsZoneId } else { $null } }
    }
  }
}

function Find-AvdLandingZone {
  <# Landing zones in the current subscription, from their rg-<prefix>-<env>-network resource groups. #>
  @(Get-AzResourceGroup -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.ResourceGroupName -match '^rg-(?<prefix>[a-z0-9]+)-(?<env>dev|test|prod)-network$') {
        [pscustomobject]@{ NamePrefix = $Matches.prefix; Environment = $Matches.env; Location = $_.Location }
      }
    })
}

function Get-AvdLandingZone {
  <#
    Finds every landing-zone resource the scripts need from the naming
    convention in bicep/main.bicep, and the Entra groups / AVD service
    principal from the role assignments the landing zone created.
  #>
  param(
    [Parameter(Mandatory)][string] $NamePrefix,
    [Parameter(Mandatory)][string] $Environment,
    [string] $ProfileShareName = 'profiles'
  )
  $ctx = Get-AzContext
  $clean = $NamePrefix.ToLower().Replace('-', '')
  $base = "$clean-$Environment"
  $sub = "/subscriptions/$($ctx.Subscription.Id)"
  $rg = [ordered]@{
    Network      = "rg-$base-network"
    Management   = "rg-$base-management"
    Storage      = "rg-$base-storage"
    ControlPlane = "rg-$base-avd"
    Hosts        = "rg-$base-hosts"
    Demo         = "rg-$base-demo"
    # The deployment portal, when Publish-AvdPortal.ps1 put a copy in this subscription (decision 0017).
    Portal       = "rg-$base-portal"
  }
  $existingRgs = @(Get-AzResourceGroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ResourceGroupName)
  $rgExists = @{}; foreach ($k in $rg.Keys) { $rgExists[$k] = $existingRgs -contains $rg[$k] }

  $lz = [ordered]@{
    NamePrefix       = $clean
    Environment      = $Environment
    BaseName         = $base
    SubscriptionId   = $ctx.Subscription.Id
    TenantId         = $ctx.Tenant.Id
    ResourceGroups   = $rg
    ResourceGroupIds = @{}
    RgExists         = $rgExists
    Location         = $null
    Vnet             = $null
    SessionHostSubnetId     = $null
    PrivateEndpointSubnetId = $null
    StorageAccount   = $null
    StorageFqdn      = $null
    ProfileShareName = $ProfileShareName
    ProfileShareUnc  = $null
    KeyVault         = $null
    LogAnalyticsId   = $null
    DataCollectionRuleId = $null
    HostPool         = $null
    AppGroup         = $null
    AvdDnsZoneId     = $null
    StorageDnsZoneId = $null
    UsersGroupId     = $null
    AdminsGroupId    = $null
    AvdServicePrincipalId = $null
    RecoveryVault    = $null
  }
  foreach ($k in $rg.Keys) { $lz.ResourceGroupIds[$k] = "$sub/resourceGroups/$($rg[$k])" }

  if ($rgExists.Network) {
    $lz.Vnet = Get-AzResource -ResourceGroupName $rg.Network -ResourceType Microsoft.Network/virtualNetworks -Name "vnet-$base" -ErrorAction SilentlyContinue
    if ($lz.Vnet) {
      $lz.Location = $lz.Vnet.Location
      $lz.SessionHostSubnetId = "$($lz.Vnet.ResourceId)/subnets/snet-session-hosts"
      $lz.PrivateEndpointSubnetId = "$($lz.Vnet.ResourceId)/subnets/snet-private-endpoints"
    }
  }
  if ($rgExists.Storage) {
    $lz.StorageAccount = Get-AzStorageAccount -ResourceGroupName $rg.Storage -ErrorAction SilentlyContinue |
      Where-Object Kind -eq 'FileStorage' | Select-Object -First 1
    if ($lz.StorageAccount) {
      $lz.StorageFqdn = "$($lz.StorageAccount.StorageAccountName).file.$($ctx.Environment.StorageEndpointSuffix)"
      $lz.ProfileShareUnc = "\\$($lz.StorageFqdn)\$ProfileShareName"
      $pe = Get-AvdPrivateEndpointDnsZoneId -SubscriptionId $lz.SubscriptionId -TargetResourceId $lz.StorageAccount.Id
      if ($pe) { $lz.StorageDnsZoneId = $pe.DnsZoneId }
    }
    $lz.RecoveryVault = Get-AzResource -ResourceGroupName $rg.Storage -ResourceType Microsoft.RecoveryServices/vaults -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($rgExists.Management) {
    $lz.KeyVault = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.KeyVault/vaults -ErrorAction SilentlyContinue | Select-Object -First 1
    $law = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.OperationalInsights/workspaces -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($law) { $lz.LogAnalyticsId = $law.ResourceId }
    $dcr = Get-AzResource -ResourceGroupName $rg.Management -ResourceType Microsoft.Insights/dataCollectionRules -ErrorAction SilentlyContinue |
      Where-Object Name -like 'microsoft-avdi-*' | Select-Object -First 1
    if ($dcr) { $lz.DataCollectionRuleId = $dcr.ResourceId }
  }
  if ($rgExists.ControlPlane) {
    $lz.HostPool = Get-AzResource -ResourceGroupName $rg.ControlPlane -ResourceType Microsoft.DesktopVirtualization/hostPools -ErrorAction SilentlyContinue | Select-Object -First 1
    $lz.AppGroup = Get-AzResource -ResourceGroupName $rg.ControlPlane -ResourceType Microsoft.DesktopVirtualization/applicationGroups -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lz.AppGroup) { $lz.UsersGroupId = Get-AvdRoleAssigneeId -Scope $lz.AppGroup.ResourceId -RoleName 'Desktop Virtualization User' -ObjectType Group }
    $lz.AvdServicePrincipalId = Get-AvdRoleAssigneeId -Scope $lz.ResourceGroupIds.ControlPlane -RoleName 'Desktop Virtualization Power On Off Contributor'
    if ($lz.HostPool) {
      $pe = Get-AvdPrivateEndpointDnsZoneId -SubscriptionId $lz.SubscriptionId -TargetResourceId $lz.HostPool.ResourceId
      if ($pe) { $lz.AvdDnsZoneId = $pe.DnsZoneId }
    }
  }
  if ($rgExists.Hosts) {
    $lz.AdminsGroupId = Get-AvdRoleAssigneeId -Scope $lz.ResourceGroupIds.Hosts -RoleName 'Virtual Machine Administrator Login' -ObjectType Group
  }
  return [pscustomobject]$lz
}

# =====================================================================
# Checks - subscription
# =====================================================================
function Test-AvdTooling {
  $area = 'Tooling'
  Add-AvdCheckResult $area "PowerShell $($PSVersionTable.PSVersion)" 'Pass'
  if (Test-AvdCloudShell) { Add-AvdCheckResult $area 'Running in Azure Cloud Shell' 'Pass' }
  else { Add-AvdCheckResult $area 'Not running in Azure Cloud Shell' 'Warn' -Detail 'Supported, but Cloud Shell is the tested environment.' }
  $bicep = Get-Command bicep -ErrorAction SilentlyContinue
  if ($bicep) { Add-AvdCheckResult $area 'Bicep CLI on PATH' 'Pass' -Detail $bicep.Source }
  else { Add-AvdCheckResult $area 'Bicep CLI on PATH' 'Warn' -Detail 'Needed by Deploy-AvdDemo.ps1 (New-AzSubscriptionDeployment).' -Remediation 'Install from https://aka.ms/bicep-install or use Cloud Shell.' }
  if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) { Add-AvdCheckResult $area 'Microsoft.Graph.Authentication module' 'Pass' }
  else { Add-AvdCheckResult $area 'Microsoft.Graph.Authentication module' 'Fail' -Remediation 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
}

function Test-AvdCallerPermission {
  param([Parameter(Mandatory)][string] $SubscriptionId, [switch] $NeedsPolicy)
  $area = 'Subscription'
  $scope = "/subscriptions/$SubscriptionId"
  try {
    $me = Get-AzADUser -SignedIn -ErrorAction Stop
    # -ExpandPrincipalGroups (group-inherited roles) can't be combined with -Scope; filter by scope below.
    $roles = @(Get-AzRoleAssignment -ObjectId $me.Id -ExpandPrincipalGroups -ErrorAction Stop |
        Where-Object { $scope.StartsWith($_.Scope, [StringComparison]::OrdinalIgnoreCase) -or $_.Scope -eq '/' -or $_.Scope -like '/providers/Microsoft.Management/managementGroups/*' } |
        Select-Object -ExpandProperty RoleDefinitionName -Unique)
    $canWrite = $roles -contains 'Owner' -or $roles -contains 'Contributor'
    $canAssign = $roles -contains 'Owner' -or $roles -contains 'User Access Administrator' -or $roles -contains 'Role Based Access Control Administrator'
    if ($canWrite -and $canAssign) { Add-AvdCheckResult $area "Caller $($me.UserPrincipalName) can deploy and assign roles" 'Pass' -Detail ($roles -join ', ') }
    else { Add-AvdCheckResult $area "Caller $($me.UserPrincipalName) lacks deploy/role-assignment rights" 'Fail' -Detail "Roles: $($roles -join ', ')" -Remediation 'Needs Owner, or Contributor + Role Based Access Control Administrator, on the subscription.' }
    if ($NeedsPolicy) {
      if ($roles -contains 'Owner' -or $roles -contains 'Resource Policy Contributor') { Add-AvdCheckResult $area 'Caller can create the policy guardrail assignments' 'Pass' }
      else { Add-AvdCheckResult $area 'Caller can create the policy guardrail assignments' 'Fail' -Remediation 'Needs Owner or Resource Policy Contributor, or set enablePolicyGuardrails = false.' }
    }
  }
  catch {
    Add-AvdCheckResult $area 'Caller permissions' 'Warn' -Detail "Could not evaluate: $($_.Exception.Message)"
  }
}

function Register-AvdResourceProvider {
  <# Starts a provider registration and returns at once (Register-AzResourceProvider can block for minutes). #>
  param([Parameter(Mandatory)][string] $Namespace)
  Invoke-AvdArm -Method POST -Path "/subscriptions/$((Get-AzContext).Subscription.Id)/providers/$Namespace/register?api-version=2021-04-01" | Out-Null
}

function Get-AvdProviderState {
  <# Registration state per namespace from one ARM call; falls back to one lookup per namespace. #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Namespace)
  $state = [ordered]@{}
  if (-not $Namespace.Count) { return $state }
  $all = $null
  try { $all = @((Invoke-AvdArm -Path "/subscriptions/$((Get-AzContext).Subscription.Id)/providers?api-version=2021-04-01").value) }
  catch { $all = $null }
  foreach ($ns in $Namespace) {
    $p = if ($all) { $all | Where-Object namespace -eq $ns | Select-Object -First 1 }
    $state[$ns] = if ($p) { $p.registrationState } else { (Get-AzResourceProvider -ProviderNamespace $ns -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState }
  }
  return $state
}

function Wait-AvdRegistration {
  <# Polls until the providers (and optionally the EncryptionAtHost feature) are Registered. Returns what is still pending. #>
  param([string[]] $Namespace = @(), [switch] $EncryptionAtHost, [int] $TimeoutMinutes = 15)
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  while ($true) {
    $states = Get-AvdProviderState -Namespace $Namespace
    $pending = @($Namespace | Where-Object { $states[$_] -ne 'Registered' })
    if ($EncryptionAtHost -and (Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost -ErrorAction SilentlyContinue).RegistrationState -ne 'Registered') {
      $pending += 'Microsoft.Compute/EncryptionAtHost'
    }
    if (-not $pending.Count -or (Get-Date) -ge $deadline) { return , $pending }
    Write-Host "  Waiting for registration: $($pending -join ', ') (up to $TimeoutMinutes min; EncryptionAtHost takes ~15)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
  }
}

function Test-AvdResourceProvider {
  <#
    Check: reports each provider and the EncryptionAtHost feature.
    -Fix: registers what is missing, waits until registration completes (up to
    -WaitMinutes), then re-registers Microsoft.Compute so the feature takes effect.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [switch] $Fix,
    [switch] $SkipEncryptionAtHost,
    [string[]] $Namespace = @('Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Storage', 'Microsoft.Network',
      'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.KeyVault', 'Microsoft.RecoveryServices', 'Microsoft.GuestConfiguration'),
    [int] $WaitMinutes = 15
  )
  $area = 'Subscription'
  $featureName = 'Feature Microsoft.Compute/EncryptionAtHost registered'
  Write-Host "  Checking $($Namespace.Count) resource providers$(if (-not $SkipEncryptionAtHost) { ' and the EncryptionAtHost feature' })..." -ForegroundColor DarkGray
  $state = Get-AvdProviderState -Namespace $Namespace
  $featureState = if ($SkipEncryptionAtHost) { 'Skipped' } else { (Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost -ErrorAction SilentlyContinue).RegistrationState }

  # ---- Fix: start every registration, then wait for all of them together ----
  $started = @(); $featureStarted = $false
  if ($Fix) {
    foreach ($ns in @($state.Keys | Where-Object { $state[$_] -notin 'Registered', 'Registering' })) {
      if ($PSCmdlet.ShouldProcess($ns, 'Register resource provider')) { Register-AvdResourceProvider -Namespace $ns; $started += $ns }
    }
    if ($featureState -notin 'Registered', 'Registering', 'Skipped' -and $PSCmdlet.ShouldProcess('Microsoft.Compute/EncryptionAtHost', 'Register feature')) {
      Register-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost | Out-Null
      $featureStarted = $true
    }
  }
  $waitFor = @($state.Keys | Where-Object { $_ -in $started -or $state[$_] -eq 'Registering' })
  $waitFeature = $featureStarted -or $featureState -eq 'Registering'
  $stillPending = @()
  if ($Fix -and -not $WhatIfPreference -and ($waitFor.Count -or $waitFeature)) {
    $stillPending = Wait-AvdRegistration -Namespace $waitFor -EncryptionAtHost:$waitFeature -TimeoutMinutes $WaitMinutes
  }

  foreach ($ns in $state.Keys) {
    $s = $state[$ns]
    if ($s -eq 'Registered') { Add-AvdCheckResult $area "Provider $ns registered" 'Pass' }
    elseif ($Fix -and $ns -in $waitFor -and -not $WhatIfPreference) {
      if ($ns -in $stillPending) { Add-AvdCheckResult $area "Provider $ns registered" 'Warn' -Detail "Still registering after $WaitMinutes min." -Remediation 'Rerun in a few minutes.' -Id 'registering' }
      else { Add-AvdCheckResult $area "Provider $ns registered" 'Fixed' }
    }
    elseif ($s -eq 'Registering') { Add-AvdCheckResult $area "Provider $ns registered" 'Warn' -Id 'registering' -Detail 'Registration in progress.' -Remediation 'Wait a few minutes and rerun (or rerun with -Fix to wait for it).' }
    else { Add-AvdCheckResult $area "Provider $ns registered" 'Fail' -Detail "State: $s" -Remediation "Register-AzResourceProvider -ProviderNamespace $ns (or rerun with -Fix)" }
  }
  if ($SkipEncryptionAtHost) { return }

  $featureDone = $featureState -eq 'Registered' -or ($waitFeature -and -not $WhatIfPreference -and 'Microsoft.Compute/EncryptionAtHost' -notin $stillPending)
  $computeNote = ''
  if ($Fix -and $featureDone -and $PSCmdlet.ShouldProcess('Microsoft.Compute', 'Re-register so the EncryptionAtHost feature takes effect')) {
    Write-Host '  Re-registering Microsoft.Compute so EncryptionAtHost takes effect' -ForegroundColor DarkGray
    Register-AvdResourceProvider -Namespace Microsoft.Compute
    $computePending = Wait-AvdRegistration -Namespace Microsoft.Compute -TimeoutMinutes $WaitMinutes
    $computeNote = if ($computePending.Count) { "Microsoft.Compute re-registration still running after $WaitMinutes min; it completes in the background." } else { 'Microsoft.Compute re-registered so the feature takes effect.' }
  }
  if ($featureState -eq 'Registered') { Add-AvdCheckResult $area $featureName 'Pass' -Detail $computeNote }
  elseif ($featureDone) { Add-AvdCheckResult $area $featureName 'Fixed' -Detail $computeNote }
  elseif ($Fix -and $waitFeature -and -not $WhatIfPreference) { Add-AvdCheckResult $area $featureName 'Warn' -Id 'registering' -Detail "Still registering after $WaitMinutes min." -Remediation 'Rerun with -Fix in a few minutes; it re-registers Microsoft.Compute once the feature is on.' }
  elseif ($featureState -eq 'Registering') { Add-AvdCheckResult $area $featureName 'Warn' -Id 'registering' -Detail 'Registration in progress (can take ~15 minutes).' -Remediation 'Rerun with -Fix to wait for it and re-register Microsoft.Compute.' }
  else { Add-AvdCheckResult $area $featureName 'Fail' -Detail "State: $featureState" -Remediation 'Rerun with -Fix, or set encryptionAtHost = false.' }
}

# Memory-optimized by default: multi-session hosts run out of memory before CPU (decision 0010).
$script:DefaultVmSize = 'Standard_E4as_v5'

function Get-AvdHostVmSize {
  <# The size of the landing zone's deployed session hosts (the first one), or $null. #>
  param([Parameter(Mandatory)] $Lz)
  if (-not $Lz.RgExists.Hosts) { return $null }
  $vm = @(Get-AzVM -ResourceGroupName $Lz.ResourceGroups.Hosts -ErrorAction SilentlyContinue) | Select-Object -First 1
  if ($vm -and $vm.HardwareProfile) { return [string]$vm.HardwareProfile.VmSize }
  return $null
}

function Get-AvdDeployedHostSize {
  <# The size of each session host the landing zone already runs (one item per VM). #>
  param([Parameter(Mandatory)] $Lz)
  if (-not $Lz.RgExists.Hosts) { return }
  @(Get-AzVM -ResourceGroupName $Lz.ResourceGroups.Hosts -ErrorAction SilentlyContinue) |
    Where-Object { $_ -and $_.HardwareProfile } | ForEach-Object { [string]$_.HardwareProfile.VmSize }
}

function Test-AvdVmCapacity {
  param(
    [Parameter(Mandatory)][string] $Location, [Parameter(Mandatory)][string] $VmSize, [int] $Count = 1, [int[]] $Zones = @(),
    # Sizes of the landing zone's own hosts. Their vCPUs already count as used, and a redeploy keeps
    # them, so only the difference is needed (a deployed host would otherwise be counted twice).
    [string[]] $DeployedSizes = @()
  )
  $area = 'Subscription'
  $skus = @(Get-AzComputeResourceSku -Location $Location -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq 'virtualMachines' })
  $sku = $skus | Where-Object { $_.Name -eq $VmSize } | Select-Object -First 1
  if (-not $sku) { Add-AvdCheckResult $area "VM size $VmSize offered in $Location" 'Fail' -Remediation 'Choose a size available in the region.'; return }
  $blocked = @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' })
  if ($blocked | Where-Object Type -eq 'Location') {
    Add-AvdCheckResult $area "VM size $VmSize available to this subscription" 'Fail' -Remediation 'Request access to the size or choose another.'
    return
  }
  $zoneBlocked = @($blocked | Where-Object Type -eq 'Zone' | ForEach-Object { $_.RestrictionInfo.Zones })
  $offered = @($sku.LocationInfo | ForEach-Object { $_.Zones } | Where-Object { $_ -and $_ -notin $zoneBlocked })
  if ($Zones.Count) {
    $missing = @($Zones | Where-Object { "$_" -notin $offered })
    if ($missing.Count) {
      Add-AvdCheckResult $area "VM size $VmSize in zones $($Zones -join ', ')" 'Fail' -Detail "Not available in zone(s) $($missing -join ', '); available: $(if ($offered) { $offered -join ', ' } else { 'none (regional only)' })" -Remediation 'Set availabilityZones to the available zones (or [] for regional), or pick another size.'
    }
    else { Add-AvdCheckResult $area "VM size $VmSize available in $Location zones $($Zones -join ', ')" 'Pass' }
  }
  elseif ($zoneBlocked.Count) { Add-AvdCheckResult $area "VM size $VmSize zones" 'Warn' -Detail "Not available in zone(s): $($zoneBlocked -join ', ')" -Remediation 'Narrow availabilityZones.' }
  else { Add-AvdCheckResult $area "VM size $VmSize available in $Location" 'Pass' }

  $vcpu = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value)
  $memoryGiB = [double](($sku.Capabilities | Where-Object Name -eq 'MemoryGB').Value)
  $need = $vcpu * $Count
  $usage = Get-AzVMUsage -Location $Location
  foreach ($name in @($sku.Family, 'cores')) {
    $u = $usage | Where-Object { $_.Name.Value -eq $name } | Select-Object -First 1
    if (-not $u) { continue }
    $free = $u.Limit - $u.CurrentValue
    $mine = 0
    foreach ($s in $DeployedSizes) {
      $d = $skus | Where-Object { $_.Name -eq $s } | Select-Object -First 1
      if ($d -and ($name -eq 'cores' -or $d.Family -eq $name)) { $mine += [int](($d.Capabilities | Where-Object Name -eq 'vCPUs').Value) }
    }
    $extra = [math]::Max(0, $need - $mine)
    $label = if ($name -eq 'cores') { 'Regional vCPU quota' } else { "$name vCPU quota" }
    $detail = "$free free, $need needed" + $(if ($mine) { " ($mine already used by this landing zone's hosts, so $extra more)" } else { '' })
    $quota = @{ location = $Location; quotaName = $name; limit = [int]$u.Limit; used = [int]$u.CurrentValue; needed = $extra; deployed = $mine }
    if ($free -ge $extra) { Add-AvdCheckResult $area $label 'Pass' -Detail $detail -Id 'quota' -Data $quota }
    else { Add-AvdCheckResult $area $label 'Fail' -Detail $detail -Remediation 'Request a quota increase (Portal > Quotas) or reduce host count/size.' -Id 'quota' -Data $quota }
  }
  return [pscustomobject]@{ Vcpu = $vcpu; MemoryGiB = $memoryGiB }
}

function Test-AvdHostPoolRegion {
  <# The template puts the host pool (AVD metadata) in the same region as everything else. #>
  param([Parameter(Mandatory)][string] $Location, [string] $SubscriptionId = (Get-AzContext).Subscription.Id)
  $area = 'Subscription'
  # The ARM provider API lists every region per resource type. (Get-AzResourceProvider
  # returns one object per region, each with only that region's types.)
  $type = $null
  try {
    $provider = Invoke-AvdArm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization?api-version=2021-04-01"
    $type = @($provider.resourceTypes | Where-Object resourceType -eq 'hostpools') | Select-Object -First 1
  }
  catch { $type = $null }
  if (-not $type) { Add-AvdCheckResult $area "AVD host pools offered in $Location" 'Warn' -Detail 'Could not read the Microsoft.DesktopVirtualization regions.'; return }
  $regions = @($type.locations | ForEach-Object { ($_ -replace '\s', '').ToLower() })
  if ($regions -contains $Location.ToLower()) { Add-AvdCheckResult $area "AVD host pools offered in $Location" 'Pass' }
  else {
    Add-AvdCheckResult $area "AVD host pools offered in $Location" 'Fail' -Id 'hostpool-region' -Data @{ location = $Location; regions = @($regions | Sort-Object) } -Detail "Host pool regions: $(($regions | Sort-Object) -join ', ')" -Remediation 'The landing zone deploys the host pool in its own region: pick one of these (the deployment portal ranks them by latency).'
  }
}

# =====================================================================
# Checks - recovery (build/specs/recovery-spec.md). Warnings, never failures: recovery is optional,
# and nothing here stops a deployment or a sign-in.
# =====================================================================
# Built-in "Allowed locations" (resources) and "Allowed locations for resource groups".
$script:AllowedLocationDefinitions = @('e56962a6-4747-49cd-b67b-bf8b01975c4c', 'e765b5de-1225-4ba3-bd56-1ac6695af988')

function Get-AvdLocationPolicyVerdict {
  <#
    The allowed-locations policy assignments that leave Location out. Pure: takes the assignments read
    from ARM ($filter=atScope(), so inherited ones too). Managed: the landing zone's own (avdlz-*), set by
    its allowedLocations parameter. Enforced: false for DoNotEnforce, which only reports.
    Initiatives (policy sets) that include the definitions are not read.
  #>
  param([AllowEmptyCollection()][object[]] $Assignment = @(), [Parameter(Mandatory)][string] $Location)
  foreach ($a in @($Assignment | Where-Object { $_ })) {
    $p = $a.properties
    if (-not $p -or -not $p.policyDefinitionId) { continue }
    if ((("$($p.policyDefinitionId)" -split '/')[-1]) -notin $script:AllowedLocationDefinitions) { continue }
    $allowed = @($p.parameters.listOfAllowedLocations.value | Where-Object { $_ } | ForEach-Object { "$_".ToLower() })
    if (-not $allowed.Count -or $allowed -contains $Location.ToLower()) { continue }
    [pscustomobject]@{
      Name     = $a.name
      Display  = $(if ($p.displayName) { $p.displayName } else { $a.name })
      Managed  = ($a.name -like 'avdlz-*')
      Enforced = ($p.enforcementMode -ne 'DoNotEnforce')
      Allowed  = $allowed
    }
  }
}

function Get-AvdProfileBackupVerdict {
  <#
    The profile share's backup, from the storage account and the vault's protected items. Pure; returns
    findings (Id, Check, Status, Detail, Remediation). Get-AvdRecoveryStatus.ps1 maps the same findings.
    Property names: AzureFileshareProtectedItem (protectionState, healthStatus, lastBackupStatus,
    lastBackupTime). ARM leaves out what has not happened yet, such as lastBackupTime before the first backup.
  #>
  param(
    $StorageAccount,
    [AllowEmptyCollection()][object[]] $ProtectedItem = @(),
    [datetime] $Now = [datetime]::UtcNow,
    [string] $VaultName = 'the vault',
    # A backup older than this is stale: the policy is daily.
    [int] $MaxAgeHours = 26
  )
  $items = @($ProtectedItem | Where-Object { $_ })
  $sa = if ($StorageAccount) { $StorageAccount.properties }
  # Microsoft's prerequisites: key access, or public network access disabled. The vaulted tier needs key access.
  if ($sa) {
    $keys = $sa.allowSharedKeyAccess -ne $false
    $public = $sa.publicNetworkAccess -ne 'Disabled'
    $access = [ordered]@{ Id = 'profile-backup-access'; Check = 'Azure Backup can reach the profile storage account'; Status = 'Pass'; Detail = ''; Remediation = '' }
    if (-not $keys -and $public) {
      $access.Status = 'Warn'; $access.Detail = 'Key access is off and public network access is not disabled; Azure Backup needs one of the two.'
      $access.Remediation = 'Redeploy the storage module (bicep/modules/storage.bicep disables public network access).'
    }
    else { $access.Detail = $(if ($keys) { 'Key access on (vaulted tier); SMB stays Kerberos-only.' } else { 'Key access off, public network access disabled (enough for the snapshot tier).' }) }
    [pscustomobject]$access
  }
  $f = [ordered]@{ Id = 'profile-backup'; Check = 'Profile share backup'; Status = 'Pass'; Detail = ''; Remediation = '' }
  if (-not $items.Count) {
    $f.Status = 'Warn'; $f.Detail = "No protected item in $VaultName."
    $f.Remediation = 'Set enableProfileBackup = true in the parameter file and deploy again.'
    return [pscustomobject]$f
  }
  $problems = @(); $fix = ''
  foreach ($i in $items) {
    $p = $i.properties
    $name = $(if ($p.friendlyName) { $p.friendlyName } else { $i.name })
    if ($p.protectionState -and $p.protectionState -ne 'Protected') { $problems += "$name protection state $($p.protectionState)" }
    if ($p.lastBackupStatus -and $p.lastBackupStatus -ne 'Healthy') {
      $problems += "$name last backup $($p.lastBackupStatus)"
      if ($sa -and $sa.allowSharedKeyAccess -eq $false) { $fix = 'If the failed job says UserErrorStorageKeyBasedAuthenticationNotPermitted, the tier needs key access: set profileBackupTier = Vaulted (it turns key access on) or tell us in an issue.' }
    }
    if ($p.healthStatus -and $p.healthStatus -notin 'Passed') { $problems += "$name health $($p.healthStatus)" }
    if (-not $p.lastBackupTime) { $problems += "$name has no backup yet" }
    else {
      $age = ($Now - ([datetime]$p.lastBackupTime).ToUniversalTime()).TotalHours
      if ($age -gt $MaxAgeHours) { $problems += ('{0} last backup {1:N0} hours ago' -f $name, $age) }
    }
  }
  if ($problems.Count) {
    $f.Status = 'Warn'; $f.Detail = $problems -join '; '
    $f.Remediation = (@('Open the vault''s Backup jobs for the error code (Portal > Recovery Services vault > Backup jobs).', $fix) | Where-Object { $_ }) -join ' '
  }
  else {
    $last = @($items | ForEach-Object { [datetime]$_.properties.lastBackupTime } | Sort-Object)[0]
    $f.Detail = "$($items.Count) protected item(s) in $VaultName, healthy; oldest last backup $($last.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC"
  }
  [pscustomobject]$f
}

function Test-AvdRecoveryRegion {
  <#
    The recovery region (recovery spec section 4.1): allowed by every allowed-locations policy, and vCPU
    quota there for recovery test hosts. PlannedAllowedLocations: what this deployment writes into the
    landing zone's own guardrail (pre-deployment); empty after deployment.
  #>
  param(
    [Parameter(Mandatory)][string] $Location,
    [string] $RecoveryLocation,
    [string[]] $PlannedAllowedLocations = @(),
    [string] $VmSize = $script:DefaultVmSize,
    [int] $Count = 1,
    [string] $SubscriptionId = (Get-AzContext).Subscription.Id
  )
  $area = 'Recovery'
  if (-not $RecoveryLocation) { Add-AvdCheckResult $area 'Recovery region' 'Skip' -Detail 'None set (AVD_RECOVERY_LOCATION or -RecoveryLocation).'; return }
  $rl = $RecoveryLocation.ToLower()
  if ($rl -eq $Location.ToLower()) {
    Add-AvdCheckResult $area "Recovery region $rl" 'Warn' -Id 'recovery-region-policy' -Data @{ location = $rl; blocking = @() } -Detail 'It is the landing zone''s own region, so a regional outage takes both.' -Remediation 'Set AVD_RECOVERY_LOCATION to another region, normally the Azure region pair.'
    return
  }
  Write-Host "  Reading the policy assignments that apply to the subscription..." -ForegroundColor DarkGray
  try {
    $assignments = @(Get-AvdArmList -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2024-04-01&`$filter=atScope()")
    $blocking = @(Get-AvdLocationPolicyVerdict -Assignment $assignments -Location $rl | Where-Object Enforced)
    $planned = @($PlannedAllowedLocations | ForEach-Object { "$_".ToLower() }) -contains $rl
    $foreign = @($blocking | Where-Object { -not $_.Managed })
    $own = @($blocking | Where-Object Managed)
    $data = @{ location = $rl; blocking = @($blocking | ForEach-Object { @{ name = $_.Name; managed = $_.Managed; allowed = @($_.Allowed) } }) }
    $check = "Recovery region $rl allowed by Azure Policy"
    if ($foreign.Count) {
      Add-AvdCheckResult $area $check 'Warn' -Id 'recovery-region-policy' -Data $data -Detail ('Blocked by: ' + (($foreign | ForEach-Object { "$($_.Display) (allows $($_.Allowed -join ', '))" }) -join '; ')) `
        -Remediation 'These assignments are not the landing zone''s: ask their owner to add the region, or pick a region they allow.'
    }
    elseif ($own.Count -and -not $planned) {
      Add-AvdCheckResult $area $check 'Warn' -Id 'recovery-region-policy' -Data $data -Detail "The landing zone's guardrail allows only $($own[0].Allowed -join ', ')." `
        -Remediation "Run export AVD_RECOVERY_LOCATION=$rl and deploy the landing zone again (deploy.sh); its guardrail then allows the region."
    }
    elseif ($own.Count) { Add-AvdCheckResult $area $check 'Pass' -Detail 'This deployment adds it to the landing zone''s guardrail.' }
    else { Add-AvdCheckResult $area $check 'Pass' }
  }
  catch { Add-AvdCheckResult $area "Recovery region $rl allowed by Azure Policy" 'Warn' -Detail "Could not read policy assignments: $($_.Exception.Message)" }

  $sku = @(Get-AzComputeResourceSku -Location $rl -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize }) | Select-Object -First 1
  if (-not $sku -or @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location' }).Count) {
    Add-AvdCheckResult $area "VM size $VmSize in $rl" 'Warn' -Id 'recovery-quota' -Data @{ location = $rl; vmSize = $VmSize } -Detail 'Not offered to this subscription there.' -Remediation 'Pick a size offered in both regions, or another recovery region.'
    return
  }
  $need = [int](($sku.Capabilities | Where-Object Name -eq 'vCPUs').Value) * $Count
  $usage = @(Get-AzVMUsage -Location $rl)
  $short = @(foreach ($name in @($sku.Family, 'cores')) {
      $u = $usage | Where-Object { $_.Name.Value -eq $name } | Select-Object -First 1
      if ($u -and ($u.Limit - $u.CurrentValue) -lt $need) { "$name $($u.Limit - $u.CurrentValue) free" }
    })
  $data = @{ location = $rl; vmSize = $VmSize; needed = $need }
  if ($short.Count) { Add-AvdCheckResult $area "vCPU quota in $rl for $Count x $VmSize" 'Warn' -Id 'recovery-quota' -Data $data -Detail "$need needed; $($short -join ', ')." -Remediation 'Request a quota increase in the recovery region (Portal > Quotas) before a recovery test or failover. Quota is not capacity: Microsoft guarantees neither in a regional outage.' }
  else { Add-AvdCheckResult $area "vCPU quota in $rl for $Count x $VmSize" 'Pass' -Detail "$need needed" }
}

function Test-AvdProfileBackup {
  <# The profile share's backup: reachable and recent (Get-AvdProfileBackupVerdict). #>
  param([Parameter(Mandatory)] $Lz)
  $area = 'Recovery'
  if (-not $Lz.RecoveryVault) { Add-AvdCheckResult $area 'Profile share backup' 'Skip' -Detail 'No Recovery Services vault (enableProfileBackup = false).'; return }
  try {
    $sa = if ($Lz.StorageAccount) { Invoke-AvdArm -Path "$($Lz.StorageAccount.Id)?api-version=2023-05-01" }
    $vid = "$($Lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($Lz.RecoveryVault.Name)"
    $filter = [uri]::EscapeDataString("backupManagementType eq 'AzureStorage'")
    $items = @(Get-AvdArmList -Path "$vid/backupProtectedItems?api-version=2024-04-01&`$filter=$filter")
    foreach ($r in @(Get-AvdProfileBackupVerdict -StorageAccount $sa -ProtectedItem $items -VaultName $Lz.RecoveryVault.Name)) {
      Add-AvdCheckResult $area $r.Check $r.Status -Detail $r.Detail -Remediation $r.Remediation -Id $r.Id
    }
  }
  catch { Add-AvdCheckResult $area 'Profile share backup' 'Warn' -Detail "Could not read the backup: $($_.Exception.Message)" }
}

# =====================================================================
# Checks - landing zone resources and RBAC
# =====================================================================
function Test-AvdLandingZoneResource {
  param([Parameter(Mandatory)] $Lz)
  $area = 'Landing zone'
  foreach ($k in 'Network', 'Management', 'Storage', 'ControlPlane', 'Hosts') {
    if ($Lz.RgExists[$k]) { Add-AvdCheckResult $area "Resource group $($Lz.ResourceGroups[$k])" 'Pass' }
    else { Add-AvdCheckResult $area "Resource group $($Lz.ResourceGroups[$k])" 'Fail' -Remediation 'Deploy the landing zone first (scripts/deploy/deploy.sh), or check -NamePrefix/-Environment.' }
  }
  $items = [ordered]@{
    'Spoke VNet'                 = $Lz.Vnet
    'Profile storage account'    = $Lz.StorageAccount
    'Key Vault'                  = $Lz.KeyVault
    'Log Analytics workspace'    = $Lz.LogAnalyticsId
    'AVD Insights DCR'           = $Lz.DataCollectionRuleId
    'Landing zone host pool'     = $Lz.HostPool
  }
  foreach ($k in $items.Keys) {
    if ($items[$k]) { Add-AvdCheckResult $area $k 'Pass' } else { Add-AvdCheckResult $area $k 'Fail' -Remediation 'Redeploy the landing zone.' }
  }

  $sa = $Lz.StorageAccount
  if ($sa) {
    $auth = $sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
    if ($auth -eq 'AADKERB') { Add-AvdCheckResult $area 'Storage uses Entra Kerberos (AADKERB)' 'Pass' }
    else { Add-AvdCheckResult $area 'Storage uses Entra Kerberos (AADKERB)' 'Fail' -Detail "DirectoryServiceOptions: $auth" -Remediation 'Redeploy the landing zone storage module.' }
    # With AES-256-GCM as the only channel encryption, Azure Files denies Entra Kerberos sessions (build/lessons/0028).
    $smb = (Invoke-AvdArm -Path "$($sa.Id)/fileServices/default?api-version=2023-05-01").properties.protocolSettings.smb
    $channel = "$($smb.channelEncryption)"
    if (-not $channel -or $channel -match 'AES-128-GCM') { Add-AvdCheckResult $area 'Profile share allows AES-128-GCM channel encryption' 'Pass' -Detail $(if ($channel) { $channel } else { 'Azure default' }) }
    else { Add-AvdCheckResult $area 'Profile share allows AES-128-GCM channel encryption' 'Fail' -Detail "channelEncryption: $channel" -Id 'smb-channel' -Data @{ channelEncryption = $channel } `
        -Remediation 'Entra Kerberos sign-ins to the share are denied without it. Deploy the landing zone again with scripts/deploy/deploy.sh; the storage module allows AES-128-GCM and AES-256-GCM.' }
    if ($sa.PublicNetworkAccess -eq 'Disabled') { Add-AvdCheckResult $area 'Storage public network access disabled' 'Pass' }
    else { Add-AvdCheckResult $area 'Storage public network access disabled' 'Warn' -Detail "PublicNetworkAccess: $($sa.PublicNetworkAccess)" }
    if ($Lz.StorageDnsZoneId) { Add-AvdCheckResult $area 'Storage private endpoint with DNS zone group' 'Pass' -Detail ($Lz.StorageDnsZoneId -split '/')[-1] }
    else { Add-AvdCheckResult $area 'Storage private endpoint with DNS zone group' 'Fail' -Remediation 'Profiles will not resolve privately. Check the storage private endpoint.' }
  }
  if ($Lz.HostPool) {
    $hpResource = Get-AzResource -ResourceId $Lz.HostPool.ResourceId -ExpandProperties
    # Auto shutdown (decision 0011): a budget alert (or an operator) locked the hosts off.
    $lock = if ($hpResource.Tags) { $hpResource.Tags['avdlz-power-lock'] }
    if ($lock) {
      Add-AvdCheckResult $area 'Session hosts not locked by auto shutdown' 'Warn' -Id 'power-locked' -Data @{ lock = $lock } `
        -Detail "Locked ($lock): hosts are drained and deallocated, the scaling plan skips them and Start VM on Connect is off." `
        -Remediation "Resume when the cost is dealt with: ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume -NamePrefix $($Lz.NamePrefix) -Environment $($Lz.Environment)"
    }
    $hpAccess = $hpResource.Properties.publicNetworkAccess
    if ($hpAccess -eq 'EnabledForClientsOnly' -and -not $Lz.AvdDnsZoneId) {
      Add-AvdCheckResult $area 'AVD Private Link DNS zone' 'Fail' -Detail 'Host pool is private for session hosts but its endpoint has no DNS zone.' -Remediation 'Link privatelink.wvd.microsoft.com to the spoke or pass central zones.'
    }
    elseif ($Lz.AvdDnsZoneId) { Add-AvdCheckResult $area 'AVD Private Link DNS zone' 'Pass' -Detail ($Lz.AvdDnsZoneId -split '/')[-1] }
    else { Add-AvdCheckResult $area 'AVD Private Link' 'Pass' -Detail 'Not in use (host pool public).' }
  }
}

function Test-AvdLandingZoneRbac {
  param([Parameter(Mandatory)] $Lz)
  $area = 'RBAC'
  $ids = [ordered]@{
    'AVD Users group (Desktop Virtualization User on app group)'  = $Lz.UsersGroupId
    'AVD Admins group (VM Administrator Login on hosts RG)'        = $Lz.AdminsGroupId
    'AVD service principal (Power On Off Contributor on avd RG)'   = $Lz.AvdServicePrincipalId
  }
  foreach ($k in $ids.Keys) {
    if ($ids[$k]) { Add-AvdCheckResult $area $k 'Pass' -Detail $ids[$k] }
    else { Add-AvdCheckResult $area $k 'Fail' -Remediation 'Redeploy the landing zone; the demo reuses these assignments.' }
  }
  if ($Lz.StorageAccount -and $Lz.UsersGroupId) {
    $hasSmb = Get-AvdRoleAssigneeId -Scope $Lz.StorageAccount.Id -RoleName 'Storage File Data SMB Share Contributor' -ObjectType Group
    if ($hasSmb -eq $Lz.UsersGroupId) { Add-AvdCheckResult $area 'AVD Users have SMB Share Contributor on the profile storage' 'Pass' }
    else { Add-AvdCheckResult $area 'AVD Users have SMB Share Contributor on the profile storage' 'Fail' -Remediation 'Redeploy the landing zone storage module.' }
  }
}

# =====================================================================
# Checks - Entra tenant (the three post-deployment steps live here)
# =====================================================================
function Get-AvdStorageKerberosApp {
  <#
    The app Azure registers when Entra Kerberos is enabled on the storage account. It can only be
    found by its display name, and anyone who can register an app can use that name, so a
    user-registered look-alike is told apart by what Azure's app never has: owners. Returns $null
    when there is no such app, and an object with .Rejected set (and no Application) when the apps
    with this name can't be settled to the one Azure created.
  #>
  param([Parameter(Mandatory)] $Lz)
  $name = "[Storage Account] $($Lz.StorageFqdn)"
  $apps = @(Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection applications -Filter "displayName eq '$name'" -Select 'id,appId,displayName,tags,requiredResourceAccess,createdDateTime'))
  if (-not $apps.Count) { return $null }
  $owned = [System.Collections.Generic.List[string]]::new()
  $candidates = @(foreach ($a in $apps) {
      $owners = @(Invoke-AvdGraph -Uri "v1.0/applications/$($a.id)/owners?`$select=id")
      if ($owners.Count) { $owned.Add("$($a.appId) ($($owners.Count) owner(s), created $($a.createdDateTime))") } else { $a }
    })
  if ($candidates.Count -ne 1) {
    $why = if ($candidates.Count) { "$($candidates.Count) apps with this name have no owners" }
    else { "every app with this name has owners, which the app Azure creates never has: $($owned -join '; ')" }
    return [pscustomobject]@{ Name = $name; Application = $null; ServicePrincipal = $null; Rejected = $why }
  }
  $app = $candidates[0]
  $sp = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection servicePrincipals -Filter "appId eq '$($app.appId)'" -Select 'id,appId,displayName') | Select-Object -First 1
  return [pscustomobject]@{ Name = $name; Application = $app; ServicePrincipal = $sp; Rejected = $null }
}

function Get-AvdDirectoryAdminId {
  <# Members of the directory roles that are expected to create and own the landing zone's groups. #>
  [CmdletBinding()]
  param()
  # Role template IDs are the same in every tenant: Global, Privileged Role, Groups and User Administrator.
  # Active assignments only (PIM-eligible roles must be activated), as for the role checks in the preflight.
  $templates = @('62e90394-69f5-4237-9190-012177145e10', 'e8611ab8-c189-46e8-94e1-60213ab1f814', 'fdd7a751-b60b-444a-984c-02652fe8fa1c', 'fe930be7-5e62-47db-91af-98c3a49a38b1')
  $ids = [System.Collections.Generic.List[string]]::new()
  foreach ($t in $templates) {
    foreach ($role in @(Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection directoryRoles -Filter "roleTemplateId eq '$t'" -Select 'id'))) {
      foreach ($m in @(Invoke-AvdGraph -Uri "v1.0/directoryRoles/$($role.id)/members?`$select=id")) { if ($m.id) { $ids.Add($m.id) } }
    }
  }
  return @($ids)
}

function Test-AvdGroupMembership {
  param([Parameter(Mandatory)] $Lz)
  $area = 'Entra ID'
  foreach ($pair in @(@('AVD Users', $Lz.UsersGroupId), @('AVD Admins', $Lz.AdminsGroupId))) {
    if (-not $pair[1]) { continue }
    try {
      $g = Invoke-AvdGraph -Uri "v1.0/groups/$($pair[1])`?`$select=id,displayName,securityEnabled"
      $members = Invoke-AvdGraph -Uri "v1.0/groups/$($pair[1])/members?`$select=id&`$top=1"
      $detail = "$($g.displayName) ($($g.id))"
      if (@($members).Count) { Add-AvdCheckResult $area "$($pair[0]) group has members" 'Pass' -Detail $detail }
      else { Add-AvdCheckResult $area "$($pair[0]) group has members" 'Warn' -Detail $detail -Remediation 'Add at least one user so someone can sign in.' }
    }
    catch { Add-AvdCheckResult $area "$($pair[0]) group readable" 'Fail' -Detail $_.Exception.Message }
  }
}

function Test-AvdIntuneLicense {
  $area = 'Entra ID'
  try {
    $skus = Invoke-AvdGraph -Uri 'v1.0/subscribedSkus'
    $intune = @($skus | ForEach-Object { $_.servicePlans } | Where-Object { $_.servicePlanName -like 'INTUNE_A*' -and $_.provisioningStatus -eq 'Success' })
    if ($intune.Count) { Add-AvdCheckResult $area 'Tenant has Intune licensing' 'Pass' }
    else { Add-AvdCheckResult $area 'Tenant has Intune licensing' 'Warn' -Detail 'Intune enrollment (enrollInIntune = true) will fail without it.' -Remediation 'License Intune, or deploy with enrollInIntune = false.' }
  }
  catch { Add-AvdCheckResult $area 'Tenant Intune licensing' 'Warn' -Detail "Could not read subscribed SKUs: $($_.Exception.Message)" }
}

function Test-AvdStorageAdminConsent {
  <# Post-deployment step 1: admin consent for the storage account's Entra Kerberos app. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 1: admin consent'
  $graphAppId = '00000003-0000-0000-c000-000000000000'
  $graphSp = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection servicePrincipals -Filter "appId eq '$graphAppId'" -Select 'id,oauth2PermissionScopes') | Select-Object -First 1

  # Scopes the app registration asks for on Microsoft Graph (normally openid, profile, User.Read).
  $required = @('openid', 'profile', 'User.Read')
  $rra = @($StorageApp.Application.requiredResourceAccess | Where-Object resourceAppId -eq $graphAppId)
  if ($rra.Count) {
    $ids = @($rra.resourceAccess | Where-Object type -eq 'Scope' | ForEach-Object id)
    $named = @($graphSp.oauth2PermissionScopes | Where-Object { $ids -contains $_.id } | ForEach-Object value)
    if ($named.Count) { $required = $named }
  }

  $grants = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection oauth2PermissionGrants -Filter "clientId eq '$($StorageApp.ServicePrincipal.id)'")
  $grant = @($grants | Where-Object { $_.consentType -eq 'AllPrincipals' -and $_.resourceId -eq $graphSp.id }) | Select-Object -First 1
  $have = if ($grant) { @($grant.scope -split ' ' | Where-Object { $_ }) } else { @() }
  $missing = @($required | Where-Object { $have -notcontains $_ })

  if (-not $missing.Count) {
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Pass' -Detail "Scopes: $($have -join ' ')"
    return
  }
  if ($Fix -and $PSCmdlet.ShouldProcess($StorageApp.Name, "Grant tenant-wide admin consent for $($required -join ' ')")) {
    if ($grant) {
      Invoke-AvdGraph -Method PATCH -Uri "v1.0/oauth2PermissionGrants/$($grant.id)" -Body @{ scope = (@($have) + $missing) -join ' ' } | Out-Null
    }
    else {
      Invoke-AvdGraph -Method POST -Uri 'v1.0/oauth2PermissionGrants' -Body @{
        clientId    = $StorageApp.ServicePrincipal.id
        consentType = 'AllPrincipals'
        resourceId  = $graphSp.id
        scope       = $required -join ' '
      } | Out-Null
    }
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Fixed' -Detail "Granted: $($missing -join ' ')"
  }
  else {
    Add-AvdCheckResult $area 'Admin consent granted to the storage account app' 'Fail' -Detail "Missing: $($missing -join ' ')" -Remediation 'Rerun with -Fix (needs Cloud Application Administrator or higher).'
  }
}

function Test-AvdCloudGroupSidTag {
  <# Lets Kerberos tickets for the share carry cloud-only group SIDs, which the profile share ACL uses. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 1: admin consent'
  $tag = 'kdc_enable_cloud_group_sids'
  $tags = @($StorageApp.Application.tags)
  if ($tags -contains $tag) { Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Pass'; return }
  if ($Fix -and $PSCmdlet.ShouldProcess($StorageApp.Name, "Add tag $tag")) {
    Invoke-AvdGraph -Method PATCH -Uri "v1.0/applications/$($StorageApp.Application.id)" -Body @{ tags = @($tags + $tag) } | Out-Null
    Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Fixed'
  }
  else {
    Add-AvdCheckResult $area "Storage app tagged $tag (cloud group SIDs in tickets)" 'Warn' -Detail 'Without it, NTFS entries for cloud-only groups are not honored.' -Remediation 'Rerun with -Fix.'
  }
}

function Test-AvdSecurityDefault {
  <#
    Security Defaults can prompt for MFA and has no per-app exclusion, so the storage app cannot be
    kept out of MFA the way the Conditional Access step does it. Reported, never fixed: turning it
    off is a tenant-wide decision.
  #>
  param([string] $Area = 'Step 2: Conditional Access')
  $label = 'Security Defaults is off (the storage app can be excluded from MFA)'
  try { $policy = Invoke-AvdGraph -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy' }
  catch {
    Add-AvdCheckResult $Area $label 'Warn' -Detail "Could not read the Security Defaults policy: $($_.Exception.Message)" -Remediation 'Needs the Policy.Read.All scope.'
    return
  }
  if (-not $policy.isEnabled) { Add-AvdCheckResult $Area $label 'Pass'; return }
  Add-AvdCheckResult $Area $label 'Warn' -Id 'security-defaults' `
    -Detail 'Security Defaults is on. It cannot exclude the storage app, so an MFA prompt during sign-in can break the profile share (net use fails with System error 1327).' `
    -Remediation 'A tenant-wide decision: turn off Security Defaults (Entra admin center > Overview > Properties) and replace it with Conditional Access policies that exclude the storage app. Needs Entra ID P1.'
}

function Test-AvdConditionalAccessExclusion {
  <# Post-deployment step 2: the storage app must be excluded from MFA-requiring CA policies. #>
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
  param([Parameter(Mandatory)] $Lz, [Parameter(Mandatory)] $StorageApp, [switch] $Fix)
  $area = 'Step 2: Conditional Access'
  try { $policies = Invoke-AvdGraph -Uri 'v1.0/identity/conditionalAccess/policies' }
  catch {
    Add-AvdCheckResult $area 'Read Conditional Access policies' 'Fail' -Detail $_.Exception.Message -Remediation 'Needs Conditional Access Administrator / Security Reader and the Policy.Read.All scope.'
    return
  }
  $appId = $StorageApp.Application.appId
  $groupIds = @($Lz.UsersGroupId, $Lz.AdminsGroupId) | Where-Object { $_ }
  $relevant = 0
  foreach ($p in @($policies | Where-Object state -ne 'disabled')) {
    $apps = $p.conditions.applications
    $users = $p.conditions.users
    $grant = $p.grantControls
    $allApps = @($apps.includeApplications) -contains 'All'
    $needsMfa = $grant -and ((@($grant.builtInControls) -contains 'mfa') -or $grant.authenticationStrength)
    if (-not ($allApps -and $needsMfa)) { continue }
    $relevant++
    $label = "Policy '$($p.displayName)' excludes the storage app"
    if (@($apps.excludeApplications) -contains $appId) { Add-AvdCheckResult $area $label 'Pass'; continue }

    $hitsAvd = (@($users.includeUsers) -contains 'All') -or (@($users.includeGroups) | Where-Object { $groupIds -contains $_ })
    if (-not $hitsAvd) {
      Add-AvdCheckResult $area $label 'Warn' -Detail 'Requires MFA for all apps for specific users/roles; review whether AVD users are in scope.' -Remediation 'Exclude the storage app if AVD users are covered.'
      continue
    }
    if ($Fix -and $PSCmdlet.ShouldProcess("Conditional Access policy '$($p.displayName)'", "Exclude application $($StorageApp.Name)")) {
      $conditions = $p.conditions
      $conditions.applications.excludeApplications = @(@($apps.excludeApplications) + $appId)
      Invoke-AvdGraph -Method PATCH -Uri "v1.0/identity/conditionalAccess/policies/$($p.id)" -Body @{ conditions = $conditions } | Out-Null
      Add-AvdCheckResult $area $label 'Fixed'
    }
    else {
      Add-AvdCheckResult $area $label 'Fail' -Detail 'Requires MFA for all apps and covers AVD users; Kerberos ticket requests for the share will fail.' -Remediation 'Rerun with -Fix (needs Conditional Access Administrator).'
    }
  }
  if (-not $relevant) { Add-AvdCheckResult $area 'No enabled policy requires MFA for all apps' 'Pass' }
}

# =====================================================================
# Session host helpers (run on a host through Run Command)
# =====================================================================
function Invoke-AvdHostScript {
  <# Runs a script from scripts/ops/host on a session host and returns its JSON result. #>
  param(
    [Parameter(Mandatory)][string] $ResourceGroupName,
    [Parameter(Mandatory)][string] $VMName,
    [Parameter(Mandatory)][string] $ScriptName,
    [hashtable] $Parameter = @{}
  )
  $script = Get-Content -Raw -Path (Join-Path $PSScriptRoot "host/$ScriptName")
  $r = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -CommandId RunPowerShellScript `
    -ScriptString $script -Parameter $Parameter -ErrorAction Stop
  $stdout = ($r.Value | Where-Object Code -like 'ComponentStatus/StdOut/*').Message
  $stderr = ($r.Value | Where-Object Code -like 'ComponentStatus/StdErr/*').Message
  if ($stdout -match '(?s)<<<AVDJSON(.*?)AVDJSON>>>') { return $Matches[1] | ConvertFrom-Json }
  throw "No result from $ScriptName on $VMName. StdErr: $stderr"
}

function Get-AvdDesiredShareSddl {
  <#
    FSLogix-recommended root ACL, with inheritance cut from the share default:
      SYSTEM, BUILTIN\Administrators, AVD Admins  Full control (all)
      CREATOR OWNER                                Modify (subfolders and files only)
      AVD Users                                    Modify (this folder only)
  #>
  param([Parameter(Mandatory)][string] $UsersSid, [Parameter(Mandatory)][string] $AdminsSid)
  return "O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;$AdminsSid)(A;OICIIO;0x1301bf;;;CO)(A;;0x1301bf;;;$UsersSid)"
}

function Test-AvdAceGrantsWrite {
  param([Parameter(Mandatory)][string] $Rights)
  if ($Rights -match '^0x[0-9a-fA-F]+$') {
    # write data/add file, append/add subdir, write EA, delete child, write attrs, DELETE, WRITE_DAC, WRITE_OWNER
    return (([Convert]::ToUInt32($Rights.Substring(2), 16)) -band 0x000D0156) -ne 0
  }
  $tokens = for ($i = 0; $i -lt $Rights.Length; $i += 2) { $Rights.Substring($i, [Math]::Min(2, $Rights.Length - $i)) }
  return [bool](@($tokens) | Where-Object { $_ -in 'GA', 'GW', 'FA', 'FW', 'SD', 'WD', 'WO', 'CC', 'DC', 'WP', 'DT' })
}

function Test-AvdShareSddl {
  <# Returns the problems with a profile-share root SDDL (empty = compliant). #>
  param([Parameter(Mandatory)][string] $Sddl, [Parameter(Mandatory)][string] $UsersSid, [Parameter(Mandatory)][string] $AdminsSid)
  $issues = [System.Collections.Generic.List[string]]::new()
  $dacl = if ($Sddl -match 'D:([^(]*)((?:\([^)]*\))*)') { $Matches } else { $null }
  if (-not $dacl) { $issues.Add('No DACL found.'); return , $issues.ToArray() }
  if ($dacl[1] -notmatch 'P') { $issues.Add('Inheritance from the share default is not disabled (DACL not protected).') }
  $aces = [regex]::Matches($dacl[2], '\(([^)]*)\)') | ForEach-Object {
    $f = $_.Groups[1].Value -split ';'
    [pscustomobject]@{ Type = $f[0]; Flags = $f[1]; Rights = $f[2]; Sid = $f[5] }
  }
  $broad = @{ AU = 'Authenticated Users'; BU = 'BUILTIN\Users'; WD = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'BUILTIN\Users'; 'S-1-1-0' = 'Everyone' }
  foreach ($a in @($aces | Where-Object { $_.Type -eq 'A' -and $broad.ContainsKey($_.Sid) })) {
    if (Test-AvdAceGrantsWrite $a.Rights) { $issues.Add("$($broad[$a.Sid]) can write to the share root.") }
  }
  if (-not ($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq 'CO' -and $_.Flags -match 'IO' })) {
    $issues.Add('No CREATOR OWNER entry for subfolders and files.')
  }
  $users = @($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq $UsersSid })
  if (-not $users) { $issues.Add('AVD Users group has no entry (users cannot create their profile folder).') }
  elseif ($users | Where-Object { $_.Flags -match 'OI|CI' }) { $issues.Add('AVD Users entry is inherited by subfolders, so users can open each other''s profiles.') }
  if (-not ($aces | Where-Object { $_.Type -eq 'A' -and $_.Sid -eq $AdminsSid -and $_.Rights -in 'FA', 'GA', '0x1f01ff' })) {
    $issues.Add('AVD Admins group does not have full control.')
  }
  return , $issues.ToArray()
}

function Format-AvdShareAclError {
  <# One line from the host script's error result: step, HTTP status, storage error code, message, resolved IP. #>
  param([Parameter(Mandatory)] $Result)
  $parts = @($Result.status)
  if ($Result.PSObject.Properties['step'] -and $Result.step) { $parts += "during '$($Result.step)'" }
  if ($Result.PSObject.Properties['httpStatus'] -and $Result.httpStatus) { $parts += "HTTP $($Result.httpStatus)" }
  if ($Result.PSObject.Properties['errorCode'] -and $Result.errorCode) { $parts += $Result.errorCode }
  $text = ($parts -join ' ') + ": $($Result.error)"
  if ($Result.PSObject.Properties['detail'] -and $Result.detail) { $text += " | $($Result.detail)" }
  if ($Result.PSObject.Properties['resolvedIp'] -and $Result.resolvedIp) { $text += " | storage resolves to $($Result.resolvedIp)" }
  $text
}

function Get-AvdShareAclRemediation {
  <# Points at DNS/network when the storage name didn't resolve privately, else at the API error. #>
  param([Parameter(Mandatory)] $Result)
  $ip = if ($Result.PSObject.Properties['resolvedIp']) { "$($Result.resolvedIp)" } else { '' }
  if ($ip -and $ip -notmatch '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)') {
    return 'The host did not resolve the storage account to a private IP: check the storage private endpoint and its DNS zone link to the spoke.'
  }
  if ($Result.status -eq 'Forbidden') { return 'The temporary role had not reached the storage data plane yet; rerun in a few minutes.' }
  'The Azure Files API rejected the request; the error code above says why.'
}

function Test-AvdProfileShareAcl {
  <#
    Post-deployment step 3: NTFS permissions on the profile share root.
    The share is private and SMB-only, so this runs ON a session host: the
    host's managed identity gets a temporary Storage File Data Privileged
    Reader/Contributor role, reads (and with -Fix, sets) the root ACL through
    the Azure Files REST API with backup intent, and the role is removed again.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Lz,
    [Parameter(Mandatory)][string] $ResourceGroupName,
    [Parameter(Mandatory)][string] $VMName,
    [switch] $Fix
  )
  $area = 'Step 3: NTFS permissions'
  $users = Get-AvdGroupSid -GroupId $Lz.UsersGroupId
  $admins = Get-AvdGroupSid -GroupId $Lz.AdminsGroupId
  $desired = Get-AvdDesiredShareSddl -UsersSid $users.Sid -AdminsSid $admins.Sid

  $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
  $principalId = $vm.Identity.PrincipalId
  if (-not $principalId) { Add-AvdCheckResult $area 'Profile share root ACL' 'Fail' -Detail "$VMName has no managed identity."; return }

  $role = if ($Fix) { 'Storage File Data Privileged Contributor' } else { 'Storage File Data Privileged Reader' }
  $scope = $Lz.StorageAccount.Id
  $existing = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue | Where-Object Scope -eq $scope
  $created = $false
  try {
    if (-not $existing) {
      Write-Host "          granting $VMName temporary '$role' on the storage account" -ForegroundColor DarkGray
      New-AzRoleAssignment -ObjectId $principalId -ObjectType ServicePrincipal -RoleDefinitionName $role -Scope $scope -ErrorAction Stop | Out-Null
      $created = $true
    }
    $sddlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($desired))

    # Read first; role assignments can take several minutes to reach the data plane.
    $result = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
      $result = Invoke-AvdHostScript -ResourceGroupName $ResourceGroupName -VMName $VMName -ScriptName 'Invoke-ProfileShareAcl.ps1' -Parameter @{
        StorageFqdn = $Lz.StorageFqdn; ShareName = $Lz.ProfileShareName; DesiredSddlBase64 = $sddlB64; Apply = 'false'
      }
      if ($result.status -ne 'Forbidden') { break }
      Write-Host "          waiting for the role to propagate (attempt $attempt/12)" -ForegroundColor DarkGray
      Start-Sleep -Seconds 30
    }
    if ($result.status -ne 'ok') {
      Add-AvdCheckResult $area 'Profile share root ACL' 'Fail' -Detail (Format-AvdShareAclError $result) -Remediation (Get-AvdShareAclRemediation $result)
      return
    }
    # No SDDL = the share root has never had an ACL set and still uses the service default.
    $issues = if ([string]::IsNullOrEmpty($result.before)) { @('The share root still has the default ACL (no permissions set yet), which lets every authenticated user modify it.') }
    else { Test-AvdShareSddl -Sddl $result.before -UsersSid $users.Sid -AdminsSid $admins.Sid }
    if (-not $issues.Count) { Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Pass'; return }

    if ($Fix -and $PSCmdlet.ShouldProcess("\\$($Lz.StorageFqdn)\$($Lz.ProfileShareName)", 'Replace the root ACL')) {
      $applied = $null
      for ($attempt = 1; $attempt -le 12; $attempt++) {
        $applied = Invoke-AvdHostScript -ResourceGroupName $ResourceGroupName -VMName $VMName -ScriptName 'Invoke-ProfileShareAcl.ps1' -Parameter @{
          StorageFqdn = $Lz.StorageFqdn; ShareName = $Lz.ProfileShareName; DesiredSddlBase64 = $sddlB64; Apply = 'true'
        }
        if ($applied.status -ne 'Forbidden') { break }
        Start-Sleep -Seconds 30
      }
      $after = if ($applied.status -ne 'ok') { @(Format-AvdShareAclError $applied) }
      elseif ([string]::IsNullOrEmpty($applied.after)) { @('The ACL was applied but could not be read back.') }
      else { Test-AvdShareSddl -Sddl $applied.after -UsersSid $users.Sid -AdminsSid $admins.Sid }
      if ($applied.status -eq 'ok' -and -not $after.Count) {
        Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fixed' -Detail "Users: $($users.DisplayName); Admins: $($admins.DisplayName)"
      }
      else {
        Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fail' -Detail ($after -join ' ') -Remediation $(if ($applied.status -ne 'ok') { Get-AvdShareAclRemediation $applied } else { 'Rerun with -Fix.' })
      }
    }
    else {
      Add-AvdCheckResult $area 'Profile share root ACL follows FSLogix guidance' 'Fail' -Detail ($issues -join ' ') -Remediation 'Rerun with -Fix.'
    }
  }
  finally {
    if ($created) {
      Remove-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue | Out-Null
      Write-Host "          removed temporary '$role' from $VMName" -ForegroundColor DarkGray
    }
  }
}

function Get-AvdSessionHost {
  param([Parameter(Mandatory)][string] $HostPoolResourceId)
  $r = Invoke-AvdArm -Path "$HostPoolResourceId/sessionHosts?api-version=2024-04-03"
  return @($r.value)
}

function Get-AvdRunCommandState {
  param([Parameter(Mandatory)][string] $VmResourceId, [Parameter(Mandatory)][string] $Name)
  $r = Invoke-AvdArm -Path "$VmResourceId/runCommands/$Name`?api-version=2024-07-01&`$expand=instanceView" -AllowNotFound
  if (-not $r) { return $null }
  return $r.properties.instanceView
}

# =====================================================================
# Well-Architected review of the deployed landing zone (-WellArchitected)
# =====================================================================
# Findings are warnings, never failures: they are design trade-offs to review, and a dev
# landing zone makes several on purpose (build/decisions/0009-well-architected-review.md).
$script:WafPillars = @('Reliability', 'Security', 'Cost Optimization', 'Operational Excellence', 'Performance Efficiency')
$script:AdvisorPillar = @{ HighAvailability = 'Reliability'; Security = 'Security'; Cost = 'Cost Optimization'; OperationalExcellence = 'Operational Excellence'; Performance = 'Performance Efficiency' }

function Get-AvdArmList {
  <# Every item of an ARM list, following nextLink. Stops on an error (Invoke-AvdArm throws), an empty page or MaxPages (lesson 0008). #>
  param([Parameter(Mandatory)][string] $Path, [int] $MaxPages = 50)
  $next = $Path; $page = 0
  while ($next -and $page -lt $MaxPages) {
    $page++
    $r = Invoke-AvdArm -Path $next
    if (-not $r -or -not $r.value) { break }
    $r.value
    $next = if ($r.nextLink) { ([uri]$r.nextLink).PathAndQuery } else { $null }
  }
}

function Get-AvdLaunchTarget {
  <#
    What the web client's direct launch link needs (decision 0014): the object IDs of the desktop in a
    resource group's desktop application group and of the workspace that publishes it, read from
    properties.objectId through REST (the Get-AzWvd* cmdlet help doesn't document an ObjectId property).
    Returns $null when either ID is missing or not a GUID: the portal then links to the plain web client.
  #>
  param([Parameter(Mandatory)][string] $ResourceGroupId, [string] $TenantId)
  $api = '2024-04-03'
  $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
  try {
    $ag = @(Get-AvdArmList -Path "$ResourceGroupId/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=$api" |
        Where-Object { $_.properties.applicationGroupType -eq 'Desktop' }) | Select-Object -First 1
    if (-not $ag) { return $null }
    $desktop = @(Get-AvdArmList -Path "$($ag.id)/desktops?api-version=$api") | Select-Object -First 1
    # The workspace that references the app group (ARM leaves out an empty reference list, lesson 0021).
    $ws = @(Get-AvdArmList -Path "$ResourceGroupId/providers/Microsoft.DesktopVirtualization/workspaces?api-version=$api" |
        Where-Object { @($_.properties.applicationGroupReferences | Where-Object { $_ -and $_ -eq $ag.id }).Count }) | Select-Object -First 1
  }
  catch {
    Write-Host "  Launch link: couldn't read the workspace and desktop: $($_.Exception.Message)" -ForegroundColor DarkGray
    return $null
  }
  if (-not $ws -or -not $desktop -or "$($ws.properties.objectId)" -notmatch $guid -or "$($desktop.properties.objectId)" -notmatch $guid) { return $null }
  $t = [ordered]@{ workspaceObjectId = $ws.properties.objectId; desktopObjectId = $desktop.properties.objectId; workspace = $ws.name; appGroup = $ag.name }
  if ($TenantId -match $guid) { $t.tenantId = $TenantId }
  $t
}

function Invoke-AvdLogQuery {
  <#
    Runs KQL against a Log Analytics workspace through the Log Analytics query API, with the signed-in
    user's Entra token: POST https://api.loganalytics.io/v1/workspaces/{customerId}/query, scope
    https://api.loganalytics.io/.default (route, auth and response shape from the API spec:
    Azure/azure-rest-api-specs specification/monitor/data-plane/OperationalInsights/stable/v1).
    Emits the first table's rows as objects. On an error it throws with the HTTP status and the body
    (lesson 0012).
  #>
  param([Parameter(Mandatory)][string] $WorkspaceCustomerId, [Parameter(Mandatory)][string] $Query)
  $token = (Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io' -ErrorAction Stop).Token
  if ($token -is [securestring]) { $token = ConvertFrom-SecureString $token -AsPlainText }
  $uri = "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query"
  try {
    $r = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $token" } -Body (@{ query = $Query } | ConvertTo-Json -Compress) -ContentType 'application/json' -ErrorAction Stop
  }
  catch {
    $code = if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { [int]$_.Exception.Response.StatusCode } elseif ($_.Exception.Message -match '\b([45]\d\d)\b') { [int]$Matches[1] } else { 0 }
    $body = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }
    throw "Log Analytics query failed ($code): $($_.Exception.Message) $body".Trim()
  }
  $table = @($r.tables | Where-Object { $_ }) | Select-Object -First 1
  if (-not $table) { return }
  $names = @($table.columns | ForEach-Object name)
  foreach ($row in @($table.rows | Where-Object { $null -ne $_ })) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $names.Count; $i++) { $o[$names[$i]] = $row[$i] }
    [pscustomobject]$o
  }
}

function Get-AvdUserConnectionOutcome {
  <#
    Classifies the rows of scripts/ops/kql/user-connection.kql (decision 0014). Fails closed: only a
    connection with a Connected time is verified, and no rows at all is "none", never a pass.
      verified    at least one connection reached Connected
      failed      none reached Connected, and there are errors
      inprogress  rows without Connected and without errors (still connecting, or rows still arriving)
      none        no rows for the user in the window
    Dynamic columns (Errors, Checkpoints) arrive from the query API as JSON strings.
  #>
  param([object[]] $Row)
  $fromJson = { param($v) if ($v -is [string] -and $v) { @($v | ConvertFrom-Json -NoEnumerate) | ForEach-Object { $_ } } elseif ($v) { @($v) | ForEach-Object { $_ } } }
  $connections = @(@($Row | Where-Object { $_ }) | ForEach-Object {
      $errors = @(& $fromJson $_.Errors | Where-Object { $_ })
      [pscustomobject][ordered]@{
        correlationId          = $_.CorrelationId
        startedAt              = $_.StartedAt
        connectedAt            = $_.ConnectedAt
        completedAt            = $_.CompletedAt
        connectionSetupSeconds = if ("$($_.ConnectionSetupSeconds)" -match '^\d+(\.\d+)?$') { [math]::Round([double]$_.ConnectionSetupSeconds, 1) } else { $null }
        sessionHost            = $_.SessionHost
        clientType             = $_.ClientType
        clientOS               = $_.ClientOS
        gatewayRegion          = $_.GatewayRegion
        transportType          = $_.TransportType
        errors                 = @($errors | ForEach-Object { [ordered]@{ code = $_.code; message = $_.message; source = $_.source; serviceError = $_.serviceError } })
        checkpoints            = @(& $fromJson $_.Checkpoints | Where-Object { $_ })
      }
    })
  $connected = @($connections | Where-Object { $_.connectedAt })
  $errored = @($connections | Where-Object { @($_.errors).Count })
  $status = if ($connected.Count) { 'verified' } elseif ($errored.Count) { 'failed' } elseif ($connections.Count) { 'inprogress' } else { 'none' }
  [pscustomobject]@{ Status = $status; Connections = $connections; Connected = $connected; Errored = $errored }
}

function Get-AvdHostBaselineResult {
  <#
    Compares what Get-SessionHostSecurity.ps1 read on a host with the reviewed host security
    baseline profile (scripts/security/host-baseline.json; avd-assess gap host-baseline-profile).
    One result per control, Outcome:
      pass       the host matches the profile
      departure  it doesn't, and the profile records why the landing zone leaves it to someone else
      gap        it doesn't, and nothing records why (drift)
      unknown    the host didn't report the value
  #>
  param([Parameter(Mandatory)] $Baseline, [Parameter(Mandatory)] $Observed)
  foreach ($c in $Baseline.controls) {
    $value = $Observed.($c.observed)
    $t = $c.test
    $outcome = if ($null -eq $value) { 'unknown' }
    else {
      # eq, in, min and max compare one value; on an array PowerShell would filter instead of compare.
      $ok = -not ($value -is [array]) -or ($null -eq $t.eq -and $null -eq $t.in -and $null -eq $t.min -and $null -eq $t.max)
      if ($null -ne $t.eq) { $ok = $ok -and ($value -eq $t.eq) }
      if ($null -ne $t.in) { $ok = $ok -and (@($t.in) -contains $value) }
      if ($null -ne $t.contains) { $ok = $ok -and (@($value) -contains $t.contains) }
      if ($null -ne $t.min) { $ok = $ok -and ($value -ge $t.min) }
      if ($null -ne $t.max) { $ok = $ok -and ($value -le $t.max) }
      if ($ok) { 'pass' } elseif ($c.departure) { 'departure' } else { 'gap' }
    }
    $shown = if ($null -eq $value) { 'not reported' } else { @($value) -join ',' }
    [pscustomobject]@{
      Id          = $c.id
      Title       = $c.title
      Outcome     = $outcome
      Value       = $shown
      Detail      = switch ($outcome) {
        'pass' { '' }
        'departure' { "$($c.observed)=$shown. Departure: $($c.departure)" }
        'gap' { "$($c.observed)=$shown, which the profile doesn't expect and no departure explains." }
        'unknown' { "The host didn't report $($c.observed)." }
      }
      Remediation = $c.remediation
    }
  }
}

function Get-AvdRdpRedirectionOff {
  <#
    The redirections a host pool's custom RDP properties turn off. A device kind is off only when
    its property is set to nothing (drivestoredirect:s:;) or 0 (redirectcomports:i:0); a property
    that isn't set leaves the client default.
  #>
  param([string] $CustomRdpProperty)
  $set = @{}
  foreach ($pair in ($CustomRdpProperty -split ';')) {
    $parts = $pair -split ':', 3
    if ($parts.Count -eq 3) { $set[$parts[0].Trim().ToLowerInvariant()] = $parts[2].Trim() }
  }
  $kinds = [ordered]@{ drives = 'drivestoredirect'; usb = 'usbdevicestoredirect'; comPorts = 'redirectcomports' }
  @($kinds.Keys | Where-Object { $set.ContainsKey($kinds[$_]) -and $set[$kinds[$_]] -in '', '0' })
}

function Add-AvdWafResult {
  <#
    One Well-Architected finding: Pass, or Warn with id waf-<Key> and data { pillar, accepted }.
    -TradeOff marks a choice the dev and test parameter files make on purpose; outside prod the
    finding says so, in prod it is a plain warning.
  #>
  param(
    [Parameter(Mandatory)][string] $Pillar,
    [Parameter(Mandatory)][string] $Key,
    [Parameter(Mandatory)][string] $Check,
    [Parameter(Mandatory)][bool] $Ok,
    [string] $Detail = '',
    [string] $Remediation = '',
    [string] $Environment = 'prod',
    [switch] $TradeOff
  )
  $area = "WAF: $Pillar"
  if ($Ok) { Add-AvdCheckResult $area $Check 'Pass' -Detail $Detail; return }
  $accepted = $TradeOff -and $Environment -ne 'prod'
  if ($accepted) {
    if ($Detail -and $Detail -notmatch '[.!?]$') { $Detail += '.' }
    $Detail = (@($Detail, "Expected in $Environment (parameters/$Environment.bicepparam); change it before production.") | Where-Object { $_ }) -join ' '
  }
  Add-AvdCheckResult $area $Check 'Warn' -Detail $Detail -Remediation $Remediation -Id "waf-$Key" -Data @{ pillar = $Pillar; accepted = [bool]$accepted }
}

# The PSRule engine and PSRule for Azure versions CI checks the templates with (validate.yml
# PSRULE_VERSION, PSRULE_AZURE_VERSION; Template.Tests.ps1 keeps them equal), so a finding here
# means the same as one in CI.
$script:PSRuleVersion = '2.9.0'
$script:PSRuleAzureVersion = '1.47.0'

function Get-AvdPSRuleFinding {
  <#
    PSRule for Azure (the rules CI applies to the templates) against the deployed resources,
    with the repo's suppressions. Returns the failed rule records.
  #>
  param([Parameter(Mandatory)][string[]] $ResourceGroupName)
  # Load the pinned versions when the commands are missing or another version is loaded. Commands
  # with no module behind them are the offline scenarios' stand-ins (AzMock.psm1).
  $pins = [ordered]@{ 'PSRule' = $script:PSRuleVersion; 'PSRule.Rules.Azure' = $script:PSRuleAzureVersion }
  $commands = (Get-Command Export-AzRuleData -ErrorAction SilentlyContinue) -and (Get-Command Invoke-PSRule -ErrorAction SilentlyContinue)
  # After Get-Command, which can auto-import whatever version is installed.
  $loaded = @(Get-Module PSRule, PSRule.Rules.Azure)
  $mismatch = @($loaded | Where-Object { $_.Version -ne [version]$pins[$_.Name] })
  if (-not $commands -or $mismatch) {
    foreach ($name in $pins.Keys) {
      $version = $pins[$name]
      if (-not (Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version]$version })) {
        Write-Host "          Installing $name $version from the PowerShell Gallery, the version CI uses (first run only) ..." -ForegroundColor DarkGray
        Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
      }
    }
    if ($mismatch) { $mismatch | Remove-Module -Force -ErrorAction SilentlyContinue }
    Import-Module PSRule -RequiredVersion $script:PSRuleVersion -Force -ErrorAction Stop
    Import-Module PSRule.Rules.Azure -RequiredVersion $script:PSRuleAzureVersion -Force -ErrorAction Stop
  }
  $out = Join-Path ([IO.Path]::GetTempPath()) "avdlz-psrule-$([guid]::NewGuid().ToString('n'))"
  $suppressions = Join-Path $PSScriptRoot '../../.ps-rule'
  try {
    Write-Host "          Exporting $($ResourceGroupName.Count) resource groups for PSRule ..." -ForegroundColor DarkGray
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    # Some optional lookups fail in most subscriptions (classic administrators, preview APIs);
    # PSRule carries on without them. Count them instead of printing each one.
    $exportWarnings = @()
    Export-AzRuleData -ResourceGroupName $ResourceGroupName -OutputPath $out -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable exportWarnings | Out-Null
    if ($exportWarnings.Count) {
      Write-Host "          PSRule could not read $($exportWarnings.Count) optional setting(s); rules that need them may report a finding. Details with -Verbose." -ForegroundColor DarkGray
      $exportWarnings | ForEach-Object { Write-Verbose "Export-AzRuleData: $_" }
    }
    # Run from the export folder: the repo's ps-rule.yaml limits input to the parameter files.
    Push-Location $out
    try {
      $src = @('PSRule.Rules.Azure')
      $invoke = @{ InputPath = (Join-Path $out '*.json'); Module = $src; Outcome = 'Fail'; WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
      if (Test-Path $suppressions) { $invoke.Path = (Resolve-Path $suppressions).Path }
      @(Invoke-PSRule @invoke)
    }
    finally { Pop-Location }
  }
  finally { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-AvdPSRulePillar {
  <# The Well-Architected pillar a PSRule for Azure rule belongs to (its Azure.WAF/pillar tag). #>
  param([Parameter(Mandatory)] $Record)
  $tag = $Record.Tag
  if ($tag -and $tag['Azure.WAF/pillar']) { [string]$tag['Azure.WAF/pillar'] } else { '' }
}

function Format-AvdPSRuleFinding {
  <# "<rule> on <target> (<first reason>)": the reason says what the rule looked for (lesson 0012). #>
  param([Parameter(Mandatory)] $Record)
  $reason = @($Record.Reason | Where-Object { $_ })[0]
  if ($reason -and $reason.Length -gt 120) { $reason = $reason.Substring(0, 117) + '...' }
  "$($Record.RuleName) on $($Record.TargetName)$(if ($reason) { " ($reason)" })"
}

function Test-AvdWellArchitected {
  <#
    Reviews the deployed landing zone against the Azure Well-Architected Framework:
    design checks read from the resources, Azure Advisor and Defender for Cloud
    recommendations, Azure Policy compliance, and PSRule for Azure on the live resources.
  #>
  param([Parameter(Mandatory)] $Lz, [switch] $SkipPSRule)
  Write-AvdSection "Well-Architected review ($($Lz.BaseName))"
  $envName = $Lz.Environment
  $sub = "/subscriptions/$($Lz.SubscriptionId)"
  $rgKeys = @($Lz.ResourceGroups.Keys | Where-Object { $_ -ne 'Demo' -and $Lz.RgExists[$_] })
  $rgIds = @($rgKeys | ForEach-Object { $Lz.ResourceGroupIds[$_] })
  $inLz = { param($id) [bool]($id -and ($rgIds | Where-Object { ([string]$id).StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) })) }
  $waf = { param($pillar, $key, $check, $ok, $detail, $remediation, [switch] $tradeOff)
    Add-AvdWafResult -Pillar $pillar -Key $key -Check $check -Ok $ok -Detail $detail -Remediation $remediation -Environment $envName -TradeOff:$tradeOff }
  # Every source is read separately: one that fails is reported and the rest still run.
  $read = { param($pillar, $what, [scriptblock] $block)
    try { & $block }
    catch { Add-AvdCheckResult "WAF: $pillar" "Read $what" 'Warn' -Detail $_.Exception.Message -Id 'waf-read-error' -Data @{ pillar = $pillar; accepted = $false } }
  }
  $top = { param($items) (@($items | Select-Object -Unique -First 5) -join '; ') + $(if (@($items | Select-Object -Unique).Count -gt 5) { '; ...' }) }

  # ---------------------------------------------------------------- design checks
  $vms = @(& $read 'Reliability' 'session hosts' { Get-AvdArmList -Path "$($Lz.ResourceGroupIds.Hosts)/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" })
  $regionZones = [bool](& $read 'Reliability' 'region availability zones' {
      $loc = (Invoke-AvdArm -Path "$sub/locations?api-version=2022-12-01").value | Where-Object name -eq $Lz.Location
      # ARM leaves out empty properties, and @($null).Count is 1: count real entries (lesson 0021).
      [bool]($loc -and @($loc.availabilityZoneMappings | Where-Object { $_ }).Count)
    })

  & $waf 'Reliability' 'host-count' 'At least two session hosts' ($vms.Count -ge 2) "$($vms.Count) session host(s)" 'Set sessionHostCount to 2 or more in the parameter file and deploy again: one host is a single point of failure.' -tradeOff
  $zoned = $vms.Count -and -not ($vms | Where-Object { -not @($_.zones | Where-Object { $_ }).Count })
  if (-not $regionZones) {
    & $waf 'Reliability' 'zones' 'Session hosts spread across availability zones' $false "$($Lz.Location) has no availability zones, so hosts and profile storage are regional." 'For production, choose a region with availability zones (the deployment portal lists them by latency) and set availabilityZones = [1, 2, 3].' -tradeOff
  }
  else {
    & $waf 'Reliability' 'zones' 'Session hosts spread across availability zones' $zoned $(if ($zoned) { 'Zones: ' + ((@($vms | ForEach-Object { $_.zones } | Where-Object { $_ }) | Sort-Object -Unique) -join ', ') } else { "$($Lz.Location) offers zones; the hosts are regional." }) 'Set availabilityZones = [1, 2, 3] in the parameter file.' -tradeOff
  }

  if ($Lz.StorageAccount) {
    & $read 'Reliability' 'profile storage' {
      $sa = Invoke-AvdArm -Path "$($Lz.StorageAccount.Id)?api-version=2023-05-01"
      $sku = $sa.sku.name
      & $waf 'Reliability' 'storage-redundancy' 'Profile storage is zone-redundant' ($sku -match 'ZRS') "SKU $sku$(if (-not $regionZones) { '; ZRS needs a region with availability zones' })" 'Set profileStorageSku = Premium_ZRS where the region offers it.' -tradeOff
      $p = $sa.properties
      $hard = @()
      if ($p.minimumTlsVersion -ne 'TLS1_2') { $hard += "minimum TLS $($p.minimumTlsVersion)" }
      if ($p.supportsHttpsTrafficOnly -eq $false) { $hard += 'HTTP allowed' }
      $why = ''
      if ($p.allowSharedKeyAccess -ne $false) {
        # The vaulted backup tier needs key access (profileBackupTier = Vaulted turns it on); a vaulted policy has vaultRetentionPolicy.
        $vaulted = $false
        if ($Lz.RecoveryVault) {
          $filter = [uri]::EscapeDataString("backupManagementType eq 'AzureStorage'")
          $policies = @(Get-AvdArmList -Path "$($Lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($Lz.RecoveryVault.Name)/backupPolicies?api-version=2024-04-01&`$filter=$filter")
          $vaulted = [bool]@($policies | Where-Object { $_.properties.vaultRetentionPolicy }).Count
        }
        if ($vaulted) { $why = 'shared key access on for the vaulted backup tier (SMB stays Kerberos-only)' }
        else { $hard += 'shared key access allowed' }
      }
      & $waf 'Security' 'storage-hardening' 'Profile storage: TLS 1.2, HTTPS only, no shared keys' (-not $hard.Count) ((@($hard) + @($why) | Where-Object { $_ }) -join '; ') 'Redeploy the storage module (bicep/modules/storage.bicep sets all three; key access only with profileBackupTier = Vaulted).'
      $fs = Invoke-AvdArm -Path "$($Lz.StorageAccount.Id)/fileServices/default?api-version=2023-05-01"
      $sd = $fs.properties.shareDeleteRetentionPolicy
      & $waf 'Reliability' 'share-soft-delete' 'Profile share soft delete' ([bool]$sd.enabled) $(if ($sd.enabled) { "$($sd.days) days" } else { 'Disabled' }) 'Enable soft delete for file shares on the storage account.'
    }
  }

  & $read 'Reliability' 'profile backup' {
    $protected = @()
    if ($Lz.RecoveryVault) {
      $vid = "$($Lz.ResourceGroupIds.Storage)/providers/Microsoft.RecoveryServices/vaults/$($Lz.RecoveryVault.Name)"
      $filter = [uri]::EscapeDataString("backupManagementType eq 'AzureStorage'")
      $protected = @(Get-AvdArmList -Path "$vid/backupProtectedItems?api-version=2024-04-01&`$filter=$filter")
    }
    # Protected is not the same as working: an item whose last backup failed is reported too.
    $unhealthy = @($protected | Where-Object { $_.properties.lastBackupStatus -and $_.properties.lastBackupStatus -ne 'Healthy' })
    $detail = if (-not $protected.Count) { 'No backup of the profile share.' } elseif ($unhealthy.Count) { "Last backup $($unhealthy[0].properties.lastBackupStatus) in $($Lz.RecoveryVault.Name); the post-deployment preflight's Recovery section says more." } else { "$($protected.Count) protected item(s) in $($Lz.RecoveryVault.Name)" }
    & $waf 'Reliability' 'profile-backup' 'Profile share backed up' ([bool]$protected.Count -and -not $unhealthy.Count) $detail $(if ($protected.Count) { 'Open the vault''s Backup jobs for the error code.' } else { 'Set enableProfileBackup = true in the parameter file and deploy again.' }) -tradeOff
  }

  & $read 'Security' 'Defender for Cloud plans' {
    $pricing = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Security/pricings?api-version=2024-01-01")
    $free = @('VirtualMachines', 'StorageAccounts', 'KeyVaults' | Where-Object { $n = $_; -not ($pricing | Where-Object { $_.name -eq $n -and $_.properties.pricingTier -eq 'Standard' }) })
    & $waf 'Security' 'defender-plans' 'Defender for Cloud plans for servers, storage and Key Vault' (-not $free.Count) $(if ($free.Count) { "Not enabled: $($free -join ', ')" } else { 'Standard' }) 'Set enableDefenderForCloud = true in the parameter file and deploy again.' -tradeOff
  }

  if ($vms.Count) {
    $slowDisk = @($vms | Where-Object { $_.properties.storageProfile.osDisk.managedDisk.storageAccountType -notmatch '^Premium' } | ForEach-Object name)
    & $waf 'Performance Efficiency' 'os-disk' 'Session host OS disks on Premium SSD' (-not $slowDisk.Count) $(if ($slowDisk.Count) { "Not Premium: $($slowDisk -join ', ')" } else { "$($vms.Count) host(s)" }) 'Redeploy the hosts (bicep/modules/sessionHosts.bicep uses Premium SSD): multi-session hosts page, sign in and update many users at once.'
    # Trusted Launch without Secure Boot or vTPM gives up measured boot and VBS (avd-assess ref:avd-security-guide#trusted-launch).
    $weak = @($vms | Where-Object {
        $sp = $_.properties.securityProfile
        $sp.securityType -ne 'TrustedLaunch' -or -not $sp.encryptionAtHost -or -not $sp.uefiSettings.secureBootEnabled -or -not $sp.uefiSettings.vTpmEnabled
      } | ForEach-Object name)
    & $waf 'Security' 'host-security' 'Session hosts: Trusted Launch with Secure Boot and vTPM, encryption at host' (-not $weak.Count) $(if ($weak.Count) { "Not on: $($weak -join ', ')" } else { "$($vms.Count) host(s)" }) 'Redeploy the hosts with encryptionAtHost = true (bicep/modules/sessionHosts.bicep always turns on Trusted Launch, Secure Boot and vTPM).'
  }

  if ($Lz.KeyVault) {
    & $read 'Security' 'Key Vault' {
      $kv = (Invoke-AvdArm -Path "$($Lz.KeyVault.ResourceId)?api-version=2023-07-01").properties
      $gaps = @()
      if (-not $kv.enablePurgeProtection) { $gaps += 'purge protection off' }
      if (-not $kv.enableRbacAuthorization) { $gaps += 'access policies instead of RBAC' }
      if ($kv.publicNetworkAccess -ne 'Disabled') { $gaps += "public network access $($kv.publicNetworkAccess)" }
      & $waf 'Security' 'keyvault-hardening' 'Key Vault: purge protection, RBAC, private only' (-not $gaps.Count) ($gaps -join '; ') 'Redeploy the Key Vault module.'
    }
  }

  & $read 'Cost Optimization' 'budgets' {
    $budgets = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Consumption/budgets?api-version=2023-11-01")
    & $waf 'Cost Optimization' 'budget' 'A cost budget with alerts' ([bool]$budgets.Count) $(if ($budgets.Count) { ($budgets | ForEach-Object name) -join ', ' } else { 'No budget on the subscription.' }) 'Set AVD_MONTHLY_BUDGET (and alert emails) before deploy.sh, or create a budget in Cost Management.' -tradeOff
  }
  if ($Lz.HostPool) {
    & $read 'Security' 'host pool RDP properties' {
      $rdp = (Invoke-AvdArm -Path "$($Lz.HostPool.ResourceId)?api-version=2024-04-03").properties.customRdpProperty
      $off = @(Get-AvdRdpRedirectionOff -CustomRdpProperty $rdp)
      $on = @('drives', 'usb' | Where-Object { $_ -notin $off })
      & $waf 'Security' 'redirection' 'Drive and USB redirection off on the host pool' (-not $on.Count) $(if ($on.Count) { "Not turned off: $($on -join ', ')" } else { 'drivestoredirect and usbdevicestoredirect set to nothing' }) 'Keep the rdpProperties default in bicep/main.bicep, or record why the estate needs drives or USB devices (avd-assess check asm-drive-usb-redirection-off).'
    }
    & $read 'Cost Optimization' 'scaling plans' {
      $plans = @(Get-AvdArmList -Path "$($Lz.ResourceGroupIds.ControlPlane)/providers/Microsoft.DesktopVirtualization/scalingPlans?api-version=2024-04-03")
      $on = $plans | Where-Object { $_.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $Lz.HostPool.ResourceId -and $_.scalingPlanEnabled } }
      & $waf 'Cost Optimization' 'scaling-plan' 'Scaling plan enabled on the host pool' ([bool]$on) $(if ($on) { @($on)[0].name } else { 'Hosts run until stopped by hand.' }) 'Redeploy the control plane module (it assigns a scaling plan).'
    }
    & $read 'Operational Excellence' 'host pool diagnostics' {
      $ds = @(Get-AvdArmList -Path "$($Lz.HostPool.ResourceId)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview")
      $toLaw = @($ds | Where-Object { $_.properties.workspaceId })
      & $waf 'Operational Excellence' 'diagnostics' 'Host pool diagnostics sent to Log Analytics' ([bool]$toLaw.Count) $(if ($toLaw.Count) { ($toLaw | ForEach-Object name) -join ', ' } else { 'No diagnostic setting.' }) 'Redeploy the control plane module.'
    }
  }
  if ($Lz.LogAnalyticsId) {
    & $read 'Operational Excellence' 'Log Analytics' {
      $days = (Invoke-AvdArm -Path "$($Lz.LogAnalyticsId)?api-version=2023-09-01").properties.retentionInDays
      & $waf 'Operational Excellence' 'log-retention' 'Log retention of 90 days or more' ($days -ge 90) "$days days" 'Set logRetentionDays = 90 or more in the parameter file.' -tradeOff
    }
  }
  & $read 'Operational Excellence' 'Azure Policy compliance' {
    $nonCompliant = 0; $assignments = @()
    foreach ($id in $rgIds) {
      $s = Invoke-AvdArm -Method POST -Path "$id/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01"
      $v = @($s.value)[0]
      if (-not $v) { continue }
      $nonCompliant += [int]$v.results.nonCompliantResources
      $assignments += @($v.policyAssignments | Where-Object { $_.results.nonCompliantResources } | ForEach-Object { ($_.policyAssignmentId -split '/')[-1] })
    }
    & $waf 'Operational Excellence' 'policy-compliance' 'Resources compliant with the assigned policies' ($nonCompliant -eq 0) $(if ($nonCompliant) { "$nonCompliant non-compliant resource(s); assignments: $(& $top $assignments)" } else { 'Evaluation can take up to a day after a deployment.' }) 'Azure portal: Policy > Compliance, filtered to the landing zone resource groups.'
  }
  if ($vms.Count) {
    & $read 'Performance Efficiency' 'network interfaces' {
      $nics = @(Get-AvdArmList -Path "$($Lz.ResourceGroupIds.Hosts)/providers/Microsoft.Network/networkInterfaces?api-version=2024-05-01")
      $slow = @($nics | Where-Object { -not $_.properties.enableAcceleratedNetworking } | ForEach-Object name)
      & $waf 'Performance Efficiency' 'accelerated-networking' 'Accelerated networking on session hosts' ($nics.Count -and -not $slow.Count) $(if ($slow.Count) { "Off: $($slow -join ', ')" } else { "$($nics.Count) NIC(s)" }) 'Use a VM size that supports accelerated networking and enable it on the NICs.'
    }
  }

  # Azure Monitor Agent, read from the VM's extensions. PSRule's export doesn't attach them to
  # the VM, so its Azure.VM.AMA rule can't see the agent (live run: installed and Succeeded).
  $script:AvdAmaHosts = @()
  if ($vms.Count) {
    & $read 'Operational Excellence' 'VM extensions' {
      $missing = @()
      foreach ($vm in $vms) {
        $ext = @(Get-AvdArmList -Path "$($vm.id)/extensions?api-version=2024-07-01")
        $ama = $ext | Where-Object { $_.properties.publisher -eq 'Microsoft.Azure.Monitor' -and $_.properties.type -eq 'AzureMonitorWindowsAgent' -and $_.properties.provisioningState -eq 'Succeeded' }
        if ($ama) { $script:AvdAmaHosts += $vm.name } else { $missing += $vm.name }
      }
      & $waf 'Operational Excellence' 'monitor-agent' 'Azure Monitor Agent on session hosts' (-not $missing.Count) $(if ($missing.Count) { "Missing or not Succeeded: $($missing -join ', ')" } else { "$($vms.Count) host(s)" }) 'Redeploy the session hosts (bicep/modules/sessionHosts.bicep installs the agent and links the AVD Insights data collection rule).'
    }
  }

  # ---------------------------------------------------------------- Defender for Cloud and Advisor
  & $read 'Security' 'Defender for Cloud recommendations' {
    Write-Host '          Reading Defender for Cloud recommendations ...' -ForegroundColor DarkGray
    $bad = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Security/assessments?api-version=2021-06-01" |
        Where-Object { $_.properties.status.code -eq 'Unhealthy' -and (& $inLz $_.id) })
    $bySeverity = ($bad | Group-Object { $_.properties.metadata.severity } | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    & $waf 'Security' 'defender-recommendations' 'Defender for Cloud: no open recommendations on landing zone resources' (-not $bad.Count) $(if ($bad.Count) { "$($bad.Count) open ($bySeverity): $(& $top @($bad | ForEach-Object { $_.properties.displayName }))" } else { '' }) 'Azure portal: Defender for Cloud > Recommendations, filtered to the landing zone resource groups.'
  }
  & $read 'Reliability' 'Azure Advisor recommendations' {
    Write-Host '          Reading Azure Advisor recommendations (Advisor refreshes about once a day; a landing zone deployed today may have none yet) ...' -ForegroundColor DarkGray
    $recs = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01" |
        Where-Object { & $inLz $(if ($_.properties.resourceMetadata.resourceId) { $_.properties.resourceMetadata.resourceId } else { $_.id }) })
    foreach ($cat in 'HighAvailability', 'Security', 'Cost', 'OperationalExcellence', 'Performance') {
      $pillar = $script:AdvisorPillar[$cat]
      $mine = @($recs | Where-Object { $_.properties.category -eq $cat })
      $detail = if ($mine.Count) { "$($mine.Count): $(& $top @($mine | ForEach-Object { '{0} ({1} impact)' -f $_.properties.shortDescription.problem, $_.properties.impact }))" } else { '' }
      & $waf $pillar "advisor-$($cat.ToLower())" "Azure Advisor: no $($pillar.ToLower()) recommendations" (-not $mine.Count) $detail 'Azure portal: Advisor > Recommendations, filtered to the landing zone resource groups.'
    }
  }

  # ---------------------------------------------------------------- PSRule for Azure on the live resources
  if ($SkipPSRule) {
    Add-AvdCheckResult 'WAF: PSRule' 'PSRule for Azure on the deployed resources' 'Skip' -Detail '-SkipPSRule'
  }
  else {
    Write-Host '          Running PSRule for Azure on the deployed resources (a minute or two) ...' -ForegroundColor DarkGray
    try {
      $failed = @(Get-AvdPSRuleFinding -ResourceGroupName @($rgKeys | ForEach-Object { $Lz.ResourceGroups[$_] }) |
          Where-Object { -not ($_.RuleName -eq 'Azure.VM.AMA' -and $script:AvdAmaHosts -contains $_.TargetName) })
      foreach ($pillar in $script:WafPillars) {
        $mine = @($failed | Where-Object { (Get-AvdPSRulePillar $_) -eq $pillar })
        $slug = ($pillar -replace ' ', '-').ToLower()
        & $waf $pillar "psrule-$slug" "PSRule for Azure: $($pillar.ToLower()) rules pass" (-not $mine.Count) $(if ($mine.Count) { "$($mine.Count): $(& $top @($mine | ForEach-Object { Format-AvdPSRuleFinding $_ }))" } else { '' }) 'Each rule is explained at https://azure.github.io/PSRule.Rules.Azure/en/rules/<rule name>/. Fix it in the Bicep or the subscription settings, or suppress it with a reason in .ps-rule/Suppressions.Rule.yaml.'
      }
      $other = @($failed | Where-Object { (Get-AvdPSRulePillar $_) -notin $script:WafPillars })
      if ($other.Count) {
        Add-AvdCheckResult 'WAF: PSRule' 'PSRule for Azure: rules without a pillar' 'Warn' -Detail "$($other.Count): $(& $top @($other | ForEach-Object { Format-AvdPSRuleFinding $_ }))" -Id 'waf-psrule-other' -Data @{ pillar = ''; accepted = $false }
      }
    }
    catch {
      Add-AvdCheckResult 'WAF: PSRule' 'PSRule for Azure on the deployed resources' 'Warn' -Detail $_.Exception.Message -Remediation 'Rerun with -SkipPSRule to skip it; CI runs the same rules on the templates.' -Id 'waf-read-error' -Data @{ pillar = 'Security'; accepted = $false }
    }
  }

  # ---------------------------------------------------------------- scorecard
  $all = @(Get-AvdCheckResult | ForEach-Object { $_ } | Where-Object { $_.Area -like 'WAF: *' })
  Write-Host ''
  Write-Host '  Well-Architected scorecard' -ForegroundColor White
  foreach ($pillar in $script:WafPillars) {
    $mine = @($all | Where-Object Area -eq "WAF: $pillar")
    $pass = @($mine | Where-Object Status -eq 'Pass').Count
    $warn = @($mine | Where-Object Status -eq 'Warn')
    $accepted = @($warn | Where-Object { $_.Data -and $_.Data.accepted }).Count
    $line = '  {0,-24} {1} of {2} pass' -f $pillar, $pass, $mine.Count
    if ($warn.Count) { $line += "; $($warn.Count) to review$(if ($accepted) { " ($accepted expected in $envName)" })" }
    Write-Host $line -ForegroundColor $(if ($warn.Count - $accepted) { 'Yellow' } elseif ($warn.Count) { 'DarkYellow' } else { 'Green' })
  }
}

# =====================================================================
# Orchestrated readiness (used by the preflight and the demo script)
# =====================================================================
function Invoke-AvdReadinessCheck {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)] $Lz,
    [switch] $Fix,
    # Empty: the deployed hosts' size, else the default.
    [string] $VmSize = '',
    [int] $VmCount = 1,
    [switch] $SkipTenant,
    [switch] $SkipNtfs,
    [string] $NtfsHostResourceGroup,
    [string] $NtfsHostName,
    [switch] $AllowHostStart,
    # Recovery region (build/specs/recovery-spec.md); empty: AVD_RECOVERY_LOCATION.
    [string] $RecoveryLocation = $env:AVD_RECOVERY_LOCATION
  )
  Write-AvdSection 'Tooling'
  Test-AvdTooling

  Write-AvdSection 'Subscription'
  Test-AvdCallerPermission -SubscriptionId $Lz.SubscriptionId
  Test-AvdResourceProvider -Fix:$Fix
  if (-not $VmSize) { $VmSize = Get-AvdHostVmSize -Lz $Lz; if (-not $VmSize) { $VmSize = $script:DefaultVmSize } }
  if ($Lz.Location) { $null = Test-AvdVmCapacity -Location $Lz.Location -VmSize $VmSize -Count $VmCount -DeployedSizes @(Get-AvdDeployedHostSize -Lz $Lz) }

  Write-AvdSection 'Landing zone'
  $present = @($Lz.RgExists.Keys | Where-Object { $_ -ne 'Demo' -and $Lz.RgExists[$_] })
  if (-not $present.Count) {
    # Nothing deployed under this name: one clear finding instead of a failure per resource.
    $sub = (Get-AzContext).Subscription.Name
    $found = @(Find-AvdLandingZone)
    $detail = if ($found.Count) {
      'Landing zones in this subscription: ' + (($found | ForEach-Object { "-NamePrefix $($_.NamePrefix) -Environment $($_.Environment)" }) -join '; ')
    }
    else { 'No landing zone resource groups (rg-<prefix>-<env>-network) in this subscription.' }
    Add-AvdCheckResult 'Landing zone' "Landing zone '$($Lz.BaseName)' deployed in subscription '$sub'" 'Fail' -Detail $detail -Id 'lz-missing' `
      -Data @{ subscription = $sub; found = @($found | ForEach-Object { @{ namePrefix = $_.NamePrefix; environment = $_.Environment } }) } `
      -Remediation "Check the subscription (Get-AzContext / Set-AzContext) and -NamePrefix/-Environment. Not deployed yet? Run the pre-deployment preflight: ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/$($Lz.Environment).bicepparam -UsersGroup '<AVD Users>' -AdminsGroup '<AVD Admins>'"
    Add-AvdCheckResult 'Landing zone' 'Landing zone resource, RBAC, tenant and NTFS checks' 'Skip' -Detail 'Nothing to check until the landing zone exists.'
    return
  }
  Test-AvdLandingZoneResource -Lz $Lz
  Write-AvdSection 'RBAC'
  Test-AvdLandingZoneRbac -Lz $Lz
  Write-AvdSection 'Recovery'
  Test-AvdProfileBackup -Lz $Lz
  if ($Lz.Location) { Test-AvdRecoveryRegion -Location $Lz.Location -RecoveryLocation $RecoveryLocation -VmSize $VmSize -SubscriptionId $Lz.SubscriptionId }

  $storageApp = $null
  if ($SkipTenant) {
    Add-AvdCheckResult 'Entra ID' 'Tenant checks' 'Skip' -Detail '-SkipTenant'
  }
  elseif (-not $Lz.StorageAccount) {
    Add-AvdCheckResult 'Entra ID' 'Tenant checks' 'Skip' -Detail 'No profile storage account found.'
  }
  else {
    Write-AvdSection 'Entra ID tenant'
    Connect-AvdGraph -Purpose ($(if ($Fix) { 'Fix' } else { 'Read' }))
    Test-AvdGroupMembership -Lz $Lz
    Test-AvdIntuneLicense
    $storageApp = Get-AvdStorageKerberosApp -Lz $Lz
    if (-not $storageApp) {
      Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Fail' -Detail "Not found: [Storage Account] $($Lz.StorageFqdn)" -Remediation 'It is created when Entra Kerberos (AADKERB) is enabled on the account; redeploy the storage module.'
    }
    elseif ($storageApp.Rejected) {
      # Consent and the Conditional Access MFA exclusion go to whichever app is picked, so none is picked.
      Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Fail' -Id 'storage-app-ambiguous' -Detail "$($storageApp.Name): $($storageApp.Rejected). Steps 1 and 2 wait until this is settled." `
        -Remediation 'In Entra ID > App registrations, find the apps with this name: the one Azure created has no owner. Remove the ones you did not expect, then run this again.'
    }
    else {
      Add-AvdCheckResult 'Step 1: admin consent' 'Storage account Entra app exists' 'Pass' -Detail $storageApp.Application.appId
      Test-AvdStorageAdminConsent -StorageApp $storageApp -Fix:$Fix
      Test-AvdCloudGroupSidTag -StorageApp $storageApp -Fix:$Fix
      Write-AvdSection 'Conditional Access'
      Test-AvdSecurityDefault
      Test-AvdConditionalAccessExclusion -Lz $Lz -StorageApp $storageApp -Fix:$Fix
    }
  }

  if ($SkipNtfs) { return }
  Write-AvdSection 'Profile share NTFS permissions'
  if ($SkipTenant -or -not $Lz.StorageAccount -or -not $Lz.UsersGroupId -or -not $Lz.AdminsGroupId) {
    Add-AvdCheckResult 'Step 3: NTFS permissions' 'Profile share root ACL' 'Skip' -Detail 'Needs the storage account, both groups and Graph access.'
    return
  }
  $hostRg = if ($NtfsHostResourceGroup) { $NtfsHostResourceGroup } else { $Lz.ResourceGroups.Hosts }
  $vms = @(Get-AzVM -ResourceGroupName $hostRg -Status -ErrorAction SilentlyContinue)
  $target = if ($NtfsHostName) { $vms | Where-Object Name -eq $NtfsHostName } else { $vms | Where-Object PowerState -eq 'VM running' | Select-Object -First 1 }
  $started = $false
  if (-not $target -and $AllowHostStart -and $vms.Count) {
    $target = $vms[0]
    if ($PSCmdlet.ShouldProcess($target.Name, 'Start session host for the NTFS check')) {
      Start-AzVM -ResourceGroupName $hostRg -Name $target.Name | Out-Null
      $started = $true
    }
  }
  if (-not $target) {
    Add-AvdCheckResult 'Step 3: NTFS permissions' 'Profile share root ACL' 'Skip' -Detail "No running session host in $hostRg." -Remediation 'Use -AllowHostStart, -NtfsHostName, or Deploy-AvdDemo.ps1 (it checks from the demo host).'
    return
  }
  try { Test-AvdProfileShareAcl -Lz $Lz -ResourceGroupName $hostRg -VMName $target.Name -Fix:$Fix }
  finally {
    if ($started) { Stop-AzVM -ResourceGroupName $hostRg -Name $target.Name -Force | Out-Null }
  }
}

# =====================================================================
# Pre-deployment preflight (before the landing zone exists)
# =====================================================================
function Get-AvdDeploymentPlan {
  <#
    Compiles the .bicepparam file with the real (or placeholder) identity values
    and returns the effective parameters: values from the file, else the
    template's literal defaults.
  #>
  param(
    [Parameter(Mandatory)][string] $ParameterFile,
    [string] $UsersGroupId,
    [string] $AdminsGroupId,
    [string] $AvdServicePrincipalId,
    # Region override: the parameter files read it from AVD_LOCATION.
    [string] $Location,
    # Sizing overrides (hosts, vmSize, maxSessions, profileQuotaGiB, and the power settings autoShutdownTime
    # and startVmOnConnect): the parameter files read AVD_SESSION_HOST_COUNT etc.
    [hashtable] $Sizing = @{},
    # Recovery region override: the parameter files read it from AVD_RECOVERY_LOCATION.
    [string] $RecoveryLocation
  )
  $bicep = Get-Command bicep -ErrorAction SilentlyContinue
  if (-not $bicep) { throw 'The Bicep CLI is required to read the parameter file.' }
  $placeholder = '00000000-0000-0000-0000-000000000000'
  $vars = [ordered]@{
    AVD_USERS_GROUP_ID       = $(if ($UsersGroupId) { $UsersGroupId } else { $placeholder })
    AVD_ADMINS_GROUP_ID      = $(if ($AdminsGroupId) { $AdminsGroupId } else { $placeholder })
    AVD_SERVICE_PRINCIPAL_ID = $(if ($AvdServicePrincipalId) { $AvdServicePrincipalId } else { $placeholder })
    # Only used to compile the file; the preflight never deploys.
    AVD_LOCAL_ADMIN_PASSWORD = 'Preflight-placeholder-only-1!'
  }
  if ($Location) { $vars.AVD_LOCATION = $Location }
  if ($RecoveryLocation) { $vars.AVD_RECOVERY_LOCATION = $RecoveryLocation }
  $sizingVars = @{ hosts = 'AVD_SESSION_HOST_COUNT'; vmSize = 'AVD_SESSION_HOST_VM_SIZE'; maxSessions = 'AVD_MAX_SESSION_LIMIT'; profileQuotaGiB = 'AVD_PROFILE_QUOTA_GIB'
    autoShutdownTime = 'AVD_AUTO_SHUTDOWN_TIME'; startVmOnConnect = 'AVD_START_VM_ON_CONNECT' }
  foreach ($k in $sizingVars.Keys) { $vars[$sizingVars[$k]] = $(if ($Sizing[$k]) { [string]$Sizing[$k] } else { '' }) }
  $saved = @{}
  foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  try {
    $raw = & $bicep.Source build-params $ParameterFile --stdout 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build-params failed: $($raw -join ' ')" }
  }
  finally {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
  $built = ($raw -join "`n") | ConvertFrom-Json -Depth 50
  $values = ($built.parametersJson | ConvertFrom-Json -Depth 50 -AsHashtable).parameters
  $template = $built.templateJson | ConvertFrom-Json -Depth 50 -AsHashtable
  $plan = @{}
  foreach ($name in $template.parameters.Keys) {
    $def = $template.parameters[$name]
    if ($values.ContainsKey($name)) { $plan[$name] = $values[$name].value }
    elseif ($def.ContainsKey('defaultValue') -and -not ($def.defaultValue -is [string] -and $def.defaultValue.StartsWith('['))) { $plan[$name] = $def.defaultValue }
  }
  return $plan
}

function Resolve-AvdGroup {
  <# Finds an Entra security group by object ID or display name; with -Fix creates a missing one. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string] $Label, [Parameter(Mandatory)][string] $NameOrId, [switch] $Fix)
  $area = 'Entra ID'
  $g = $null
  $guid = [guid]::Empty
  if ([guid]::TryParse($NameOrId, [ref]$guid)) {
    try { $g = Invoke-AvdGraph -Uri "v1.0/groups/$NameOrId`?`$select=id,displayName,securityEnabled" } catch { $g = $null }
  }
  else {
    $found = @(Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection groups -Filter "displayName eq '$($NameOrId.Replace("'", "''"))'" -Select 'id,displayName,securityEnabled'))
    if ($found.Count -gt 1) {
      Add-AvdCheckResult $area "$Label group '$NameOrId'" 'Fail' -Detail "$($found.Count) groups have this name." -Remediation 'Pass the group object ID instead.'
      return $null
    }
    $g = $found | Select-Object -First 1
  }
  if ($g) {
    if (-not $g.securityEnabled) {
      Add-AvdCheckResult $area "$Label group '$($g.displayName)'" 'Fail' -Detail 'Not a security group; Azure RBAC needs a security group.' -Remediation 'Use a security-enabled group.'
      return $null
    }
    if (-not [guid]::TryParse($NameOrId, [ref]$guid)) {
      # Found by name: anyone who can create groups could have made one with this name, and it would get
      # VM Admin Login, the break-glass secret and elevated share access. Its owners must be administrators
      # (or you). A group given by object ID was picked deliberately and is used as it is.
      $owners = @(Invoke-AvdGraph -Uri "v1.0/groups/$($g.id)/owners?`$select=id,userPrincipalName,displayName")
      if ($owners.Count) {
        $me = (Invoke-AvdGraph -Uri 'v1.0/me?$select=id').id
        $admins = @(Get-AvdDirectoryAdminId)
        $outside = @($owners | Where-Object { $_.id -ne $me -and $admins -notcontains $_.id })
        if ($outside.Count) {
          $who = @($outside | ForEach-Object { if ($_.userPrincipalName) { $_.userPrincipalName } else { $_.displayName } }) -join ', '
          Add-AvdCheckResult $area "$Label group '$($g.displayName)' is owned by administrators" 'Fail' -Id 'group-owner' -Data @{ group = $g.id; owners = @($outside.id) } `
            -Detail "$($g.id) is owned by $who, who holds none of the Global, Privileged Role, Groups or User Administrator roles. A group anyone created must not get the landing zone's rights." `
            -Remediation 'Pass the object ID of a group an administrator created, or remove those owners and run this again.'
          return $null
        }
      }
    }
    Add-AvdCheckResult $area "$Label group '$($g.displayName)' exists" 'Pass' -Detail $g.id
    return $g
  }
  if ($Fix -and -not [guid]::TryParse($NameOrId, [ref]$guid) -and $PSCmdlet.ShouldProcess($NameOrId, 'Create Entra security group')) {
    $nick = (($NameOrId.ToLower() -replace '[^a-z0-9]', '-') -replace '-+', '-').Trim('-')
    $g = Invoke-AvdGraph -Method POST -Uri 'v1.0/groups' -Body @{
      displayName = $NameOrId; mailNickname = $nick; mailEnabled = $false; securityEnabled = $true
      description = "Azure Virtual Desktop landing zone: $Label"
    }
    Add-AvdCheckResult $area "$Label group '$NameOrId' exists" 'Fixed' -Detail "Created $($g.id). Add members before users sign in."
    return $g
  }
  Add-AvdCheckResult $area "$Label group '$NameOrId' exists" 'Fail' -Remediation 'Create it (or rerun with -Fix to create it), or pass an existing group.'
  return $null
}

function Test-AvdSignInMatch {
  <# The Graph device code is completed in a browser, which may be signed in as someone else. #>
  # In Cloud Shell the Az context account reads 'MSI@<port>', so ask Entra who is signed in.
  $az = try { (Get-AzADUser -SignedIn -ErrorAction Stop).UserPrincipalName } catch { $null }
  if (-not $az -and (Get-AzContext).Account.Id -notlike 'MSI@*') { $az = (Get-AzContext).Account.Id }
  $mg = (Get-MgContext).Account
  if (-not $az -or -not $mg) { return }
  if ($az -eq $mg) { Add-AvdCheckResult 'Entra ID' "Microsoft Graph and Azure signed in as $az" 'Pass'; return }
  Add-AvdCheckResult 'Entra ID' 'Microsoft Graph and Azure signed in as the same account' 'Warn' -Detail "Azure: $az; Microsoft Graph: $mg. Tenant changes (and -AddMeToGroups) use the Graph account." -Remediation "If that is not intended: Disconnect-MgGraph, then complete the device code as $az (a private browser window avoids the signed-in account)."
}

function Add-AvdCallerToGroup {
  <# Adds the signed-in user to each group they are not already a direct member of. #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][object[]] $Group)
  try {
    $me = Invoke-AvdGraph -Uri 'v1.0/me?$select=id,userPrincipalName'
    $mine = @(Invoke-AvdGraph -Uri 'v1.0/me/memberOf/microsoft.graph.group?$select=id' | ForEach-Object id)
  }
  catch {
    Add-AvdCheckResult 'Entra ID' 'Add you to the AVD groups' 'Fail' -Detail $_.Exception.Message -Remediation 'Sign in as a user (not a service principal), or add members in the Entra admin center.'
    return
  }
  foreach ($pair in $Group) {
    $label = $pair[0]; $g = $pair[1]
    if (-not $g) { continue }
    $name = "$($me.userPrincipalName) is a member of $label"
    if ($mine -contains $g.id) { Add-AvdCheckResult 'Entra ID' $name 'Pass'; continue }
    if ($PSCmdlet.ShouldProcess($g.displayName, "Add $($me.userPrincipalName) as a member")) {
      Invoke-AvdGraph -Method POST -Uri "v1.0/groups/$($g.id)/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($me.id)" } | Out-Null
      Add-AvdCheckResult 'Entra ID' $name 'Fixed' -Detail 'Added. Group changes reach your sign-in token within about an hour.'
    }
  }
}

# =====================================================================
# Sizing and cost (pre-deployment; decision 0010)
# =====================================================================
$script:RetailPriceApi = 'https://prices.azure.com/api/retail/prices'
$script:HoursPerMonth = 730

function Get-AvdRetailPrice {
  <#
    Azure retail (pay-as-you-go list) prices matching an OData filter, from the public Retail
    Prices API (no sign-in). Paged; stops on an error, an empty page or MaxPages (lesson 0008).
  #>
  param([Parameter(Mandatory)][string] $Filter, [string] $Currency = 'USD', [int] $MaxPages = 5)
  $uri = "$($script:RetailPriceApi)?currencyCode='$Currency'&`$filter=$([uri]::EscapeDataString($Filter))"
  $page = 0
  while ($uri -and $page -lt $MaxPages) {
    $page++
    $r = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
    if (-not $r -or -not $r.Items) { break }
    $r.Items
    $uri = $r.NextPageLink
  }
}

function Get-AvdCostEstimate {
  <#
    Monthly cost of the fixed and per-host parts of the plan at list prices. Each line names the
    meter it used; a line whose meter is not found says which meters the API returned instead
    (lesson 0012). Usage-based charges are listed as excluded, not guessed.
  #>
  param(
    [Parameter(Mandatory)][hashtable] $Plan,
    [int] $ActiveHoursPerWeek = 50,
    [string] $Currency = 'USD'
  )
  $loc = $Plan.location
  $hosts = [int]$Plan.sessionHostCount
  $size = $Plan.sessionHostVmSize
  $quota = [int]$Plan.profileShareQuotaGiB
  $fileSku = ([string]$Plan.profileStorageSku) -replace '_', ' '
  $activeHours = [math]::Round($hosts * $ActiveHoursPerWeek * 52 / 12, 1)
  $pe = 2 + $(if ($Plan.enableAvdPrivateLink -ne $false) { 1 } else { 0 })   # storage, Key Vault, host pool
  # What stops and starts the hosts, so the hours can be read against the plan.
  $power = @(
    $(if ($Plan.startVmOnConnect -ne $false) { 'Start VM on Connect starts hosts on demand' } else { 'no Start VM on Connect: hosts stay up through the working day' })
    $(if ($Plan.enableAutoShutdown -ne $false -and $Plan.autoShutdownTime) { "stopped daily at $($Plan.autoShutdownTime)" } else { 'no scheduled stop' })
  ) -join '; '
  $specs = @(
    @{ key = 'compute'; item = "Session hosts ($hosts x $size)"; quantity = $activeHours; unit = 'host-hours'
      note = "$ActiveHoursPerWeek h/week each ($power)"
      filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$loc' and armSkuName eq '$size' and priceType eq 'Consumption'"
      # Windows client multi-session is licensed per user (Microsoft 365 / Windows E3+), so hosts pay the base compute rate.
      # Only 'Virtual Machines ...' products: '<series> CloudServices' shares the SKU name at the Windows rate (lesson 0025).
      pick = { $_.productName -match '^Virtual Machines ' -and $_.productName -notmatch 'Windows' -and $_.skuName -notmatch 'Spot|Low Priority' -and $_.unitOfMeasure -eq '1 Hour' } }
    @{ key = 'osdisk'; item = "OS disks ($hosts x Premium SSD P10)"; quantity = $hosts; unit = 'disks'
      filter = "serviceName eq 'Storage' and armRegionName eq '$loc' and skuName eq 'P10 LRS' and priceType eq 'Consumption'"
      # 'Premium Page Blob' has a 'P10 LRS Disk' meter too (lesson 0025).
      pick = { $_.productName -eq 'Premium SSD Managed Disks' -and $_.meterName -eq 'P10 LRS Disk' -and $_.unitOfMeasure -match 'Month' } }
    @{ key = 'profiles'; item = "Profile share ($($Plan.profileStorageSku), $quota GiB provisioned)"; quantity = $quota; unit = 'GiB'
      filter = "serviceName eq 'Storage' and armRegionName eq '$loc' and productName eq 'Premium Files' and priceType eq 'Consumption'"
      pick = { $_.skuName -eq $fileSku -and $_.meterName -match 'Provisioned' -and $_.unitOfMeasure -match 'GB/Month|GiB/Month' } }
    @{ key = 'privateendpoints'; item = "Private endpoints ($pe)"; quantity = $pe * $script:HoursPerMonth; unit = 'endpoint-hours'
      # Listed once, under armRegionName 'Global', not per region (lesson 0025). 'Fixed Private Endpoint T1' is another hourly meter.
      filter = "productName eq 'Virtual Network Private Link' and armRegionName eq 'Global' and priceType eq 'Consumption'"
      pick = { $_.skuName -eq 'Standard' -and $_.meterName -eq 'Standard Private Endpoint' -and $_.unitOfMeasure -eq '1 Hour' } }
  )
  if ($Plan.connectivityMode -ne 'HubPeered') {
    $specs += @{ key = 'natgateway'; item = 'NAT Gateway'; quantity = $script:HoursPerMonth; unit = 'hours'
      # Global, like Private Link (lesson 0025). StandardV2 has its own meters.
      filter = "productName eq 'NAT Gateway' and armRegionName eq 'Global' and priceType eq 'Consumption'"
      pick = { $_.skuName -eq 'Standard' -and $_.meterName -eq 'Standard Gateway' -and $_.unitOfMeasure -eq '1 Hour' } }
    $specs += @{ key = 'publicip'; item = 'NAT Gateway public IP'; quantity = $script:HoursPerMonth; unit = 'hours'
      filter = "productName eq 'IP Addresses' and armRegionName eq '$loc' and priceType eq 'Consumption'"
      pick = { $_.skuName -eq 'Standard' -and $_.meterName -match 'Static Public IP' -and $_.meterName -notmatch 'IPv6' -and $_.unitOfMeasure -eq '1 Hour' } }
  }

  $lines = @(); $unpriced = @(); $alwaysOnCompute = $null
  foreach ($s in $specs) {
    $items = @(Get-AvdRetailPrice -Filter $s.filter -Currency $Currency)
    # Exactly one meter must match (first price tier); several different ones means the pattern is too loose.
    $matched = @($items | Where-Object $s.pick | Where-Object { -not $_.tierMinimumUnits })
    $distinct = @($matched | ForEach-Object { "$($_.productName)|$($_.skuName)|$($_.meterName)|$($_.unitOfMeasure)" } | Select-Object -Unique)
    $hit = if ($distinct.Count -eq 1) { $matched[0] } else { $null }
    if (-not $hit) {
      if ($distinct.Count -gt 1) { $items = $matched }
      # Name the product too: lookalike meters differ only by product (lesson 0025).
      $seen = @($items | ForEach-Object { "$($_.productName): $($_.skuName) / $($_.meterName) ($($_.unitOfMeasure))" } | Select-Object -Unique -First 6)
      $unpriced += [ordered]@{ key = $s.key; item = $s.item; filter = $s.filter; seen = $seen }
      continue
    }
    $price = [double]$hit.retailPrice
    $line = [ordered]@{ key = $s.key; item = $s.item; quantity = $s.quantity; unit = $s.unit; unitPrice = $price; unitOfMeasure = $hit.unitOfMeasure
      monthly = [math]::Round($price * $s.quantity, 2); meter = "$($hit.productName) / $($hit.meterName)" }
    if ($s.note) { $line.note = $s.note }
    if ($s.key -eq 'compute') { $alwaysOnCompute = [math]::Round($price * $hosts * $script:HoursPerMonth, 2) }
    $lines += $line
  }
  $total = [math]::Round((($lines | ForEach-Object { $_.monthly }) | Measure-Object -Sum).Sum, 2)
  $computeLine = $lines | Where-Object { $_.key -eq 'compute' }
  [ordered]@{
    currency           = $Currency
    location           = $loc
    activeHoursPerWeek = $ActiveHoursPerWeek
    total              = $total
    alwaysOnTotal      = $(if ($null -ne $alwaysOnCompute) { [math]::Round($total - $computeLine.monthly + $alwaysOnCompute, 2) } else { $null })
    lines              = @($lines)
    unpriced           = @($unpriced)
    excluded           = @('Log Analytics ingestion and retention (per GB)', 'NAT Gateway and private endpoint data processed (per GB)',
      'Azure Backup of the profile share (when enabled)', 'Defender for Cloud plans (when enabled)', 'Windows / Microsoft 365 licenses (per user)')
  }
}

function Test-AvdSizing {
  <#
    The capacity the plan deploys and what it costs at list prices. The vCPU quota and VM size
    checks (Test-AvdVmCapacity) already run against the same plan.
  #>
  param([Parameter(Mandatory)][hashtable] $Plan, [int] $VcpuPerHost, [double] $MemoryGiBPerHost, [int] $ActiveHoursPerWeek = 50)
  Write-AvdSection 'Sizing and cost'
  $hosts = [int]$Plan.sessionHostCount; $max = [int]$Plan.maxSessionLimit
  $detail = "Up to $($hosts * $max) concurrent sessions$(if ($VcpuPerHost) { "; $($hosts * $VcpuPerHost) vCPUs" })$(if ($MemoryGiBPerHost -and $max) { "; $([math]::Round($MemoryGiBPerHost / $max, 1)) GiB memory per session" }); Premium SSD OS disks; profile share $($Plan.profileShareQuotaGiB) GiB ($($Plan.profileStorageSku))"
  Add-AvdCheckResult 'Sizing' "$hosts session host(s) x $($Plan.sessionHostVmSize), $max sessions each" 'Pass' -Detail $detail
  if ($VcpuPerHost -and $max -gt 6 * $VcpuPerHost) {
    Add-AvdCheckResult 'Sizing' 'Sessions per vCPU within Microsoft''s multi-session guidance' 'Warn' -Detail "$max sessions on $VcpuPerHost vCPUs is $([math]::Round($max / $VcpuPerHost, 1)) per vCPU; light workloads are sized at 6 per vCPU, medium 4, heavy 2." -Remediation 'Lower maxSessionLimit (--max-sessions) or use a larger size.'
  }

  # Multi-session hosts run out of memory before CPU. Below 1 GiB per session is too little on any
  # size; below 1.5 GiB on a D-series (4 GiB per vCPU), the E-series (8 GiB per vCPU) is the better fit.
  if ($MemoryGiBPerHost -and $max) {
    $perSession = $MemoryGiBPerHost / $max
    $isE = $Plan.sessionHostVmSize -match '^Standard_E'
    if ($perSession -lt 1 -or ($perSession -lt 1.5 -and -not $isE)) {
      Add-AvdCheckResult 'Sizing' 'Memory per session' 'Warn' -Id 'sizing-memory' -Detail ("{0:N1} GiB per session ({1} GiB for {2} sessions on {3})." -f $perSession, $MemoryGiBPerHost, $max, $Plan.sessionHostVmSize) -Remediation $(if ($isE) { 'Lower maxSessionLimit (--max-sessions) or use a larger E-series size.' } else { "Use the memory-optimized E-series (e.g. $($Plan.sessionHostVmSize -replace '^Standard_D(\d+)(\w*)_v(\d)$', 'Standard_E$1$2_v$3')) with --vm-size, or lower maxSessionLimit." })
    }
  }

  Write-Host "  Pricing the plan in $($Plan.location) from the Azure retail price API (list prices, pay-as-you-go) ..." -ForegroundColor DarkGray
  try { $estimate = Get-AvdCostEstimate -Plan $Plan -ActiveHoursPerWeek $ActiveHoursPerWeek }
  catch {
    Add-AvdCheckResult 'Cost' 'Cost estimate' 'Warn' -Detail "Could not read the Azure retail price API: $($_.Exception.Message)" -Remediation 'Rerun later; sizing and quota checks do not depend on it.' -Id 'cost-unavailable'
    return $null
  }
  foreach ($l in $estimate.lines) {
    Add-AvdCheckResult 'Cost' $l.item 'Pass' -Detail ('{0:N2} {1}/month ({2:N1} {3} x {4:N4} per {5}){6}' -f $l.monthly, $estimate.currency, $l.quantity, $l.unit, $l.unitPrice, $l.unitOfMeasure, $(if ($l.note) { "; $($l.note)" }))
  }
  foreach ($u in $estimate.unpriced) {
    Add-AvdCheckResult 'Cost' $u.item 'Warn' -Id 'cost-unpriced' -Detail "No matching price. Meters returned: $(if ($u.seen.Count) { $u.seen -join '; ' } else { 'none' })" -Remediation 'Not included in the total. Paste this output into the portal''s Report a problem so the meter can be added.'
  }
  $summary = '{0:N2} {1}/month at {2} h/week per host' -f $estimate.total, $estimate.currency, $ActiveHoursPerWeek
  if ($null -ne $estimate.alwaysOnTotal) { $summary += ('; {0:N2} if hosts run around the clock' -f $estimate.alwaysOnTotal) }
  Add-AvdCheckResult 'Cost' 'Estimated monthly cost (list prices)' 'Pass' -Id 'cost-estimate' -Detail "$summary. Not included (usage-based): $($estimate.excluded -join '; ')."
  return $estimate
}

function Test-AvdDeletedKeyVault {
  <#
    A soft-deleted, purge-protected Key Vault keeps the landing zone's vault name (prefix,
    environment and a hash of subscription and region) for 90 days after a cleanup. -Fix
    recovers it into its original resource group, creating the group again if the cleanup
    removed it; the deployment then adopts the vault and the name prefix can stay.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)] $Lz, [Parameter(Mandatory)][string] $Location, [switch] $Fix)
  $area = 'Subscription'; $check = 'No soft-deleted Key Vault blocking the vault name'
  $sub = "/subscriptions/$($Lz.SubscriptionId)"
  $kvPrefix = "kv$($Lz.NamePrefix)$($Lz.Environment)"
  $deleted = @(Get-AvdArmList -Path "$sub/providers/Microsoft.KeyVault/deletedVaults?api-version=2023-07-01" |
      Where-Object { $_ -and $_.name -like "$kvPrefix*" -and $_.properties.location -eq $Location })
  if (-not $deleted.Count) { Add-AvdCheckResult $area $check 'Pass'; return }

  $names = @($deleted.name)
  $fail = @{ Id = 'kv-softdeleted'; Data = @{ vaults = $names } }
  $detail = "Deleted, purge-protected: $($names -join ', ')"
  if ($deleted.Count -gt 1) {
    Add-AvdCheckResult $area $check 'Fail' @fail -Detail $detail -Remediation 'Recover the one to keep with Undo-AzKeyVaultRemoval, or change namePrefix.'
    return
  }
  $v = $deleted[0]; $vaultId = $v.properties.vaultId; $rg = ($vaultId -split '/')[4]
  if (-not $Fix -or -not $PSCmdlet.ShouldProcess($v.name, "Recover the soft-deleted Key Vault into $rg")) {
    Add-AvdCheckResult $area $check 'Fail' @fail -Detail $detail -Remediation "Rerun with -Fix to recover it into $rg (the deployment reuses it), or change namePrefix."
    return
  }

  Write-Host "  Recovering Key Vault $($v.name) into $rg (up to 2 minutes)..." -ForegroundColor DarkGray
  try {
    # Recovery needs the original resource group; the cleanup deleted it with the vault.
    if (-not (Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue)) {
      Invoke-AvdArm -Method PUT -Path "$sub/resourcegroups/$($rg)?api-version=2021-04-01" -Body @{ location = $Location } | Out-Null
    }
    Invoke-AvdArm -Method PUT -Path "$($vaultId)?api-version=2023-07-01" -Body @{
      location   = $v.properties.location
      properties = @{ tenantId = $Lz.TenantId; sku = @{ family = 'A'; name = 'standard' }; createMode = 'recover' }
    } | Out-Null
    # "Fixed" means the vault is back, not that the request was accepted.
    $state = $null
    for ($i = 0; $i -lt 24; $i++) {
      $kv = Invoke-AvdArm -Path "$($vaultId)?api-version=2023-07-01" -AllowNotFound
      $state = if ($kv) { $kv.properties.provisioningState } else { 'not found' }
      if ($state -eq 'Succeeded') { break }
      Start-Sleep -Seconds 5
    }
    if ($state -eq 'Succeeded') { Add-AvdCheckResult $area $check 'Fixed' -Detail "Recovered $($v.name) into $rg; the deployment reuses it." }
    else { Add-AvdCheckResult $area $check 'Fail' @fail -Detail "Recovery of $($v.name) requested; the vault is still $state after 2 minutes." -Remediation 'Rerun the preflight in a few minutes.' }
  }
  catch {
    Add-AvdCheckResult $area $check 'Fail' @fail -Detail "Recovering $($v.name) into $rg failed: $($_.Exception.Message)" -Remediation 'Recover it with Undo-AzKeyVaultRemoval, or change namePrefix.'
  }
}

function Test-AvdPreDeployment {
  <# Everything the landing zone deployment needs, checked against the effective parameters. #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string] $ParameterFile,
    [Parameter(Mandatory)][string] $UsersGroup,
    [Parameter(Mandatory)][string] $AdminsGroup,
    [string] $Location,
    [switch] $Fix,
    # Add the signed-in user to both groups (gives you the desktop and admin rights on the hosts).
    [switch] $AddMeToGroups,
    [switch] $SkipTenant,
    # Desired sizing from the deployment portal (hosts, vmSize, maxSessions, profileQuotaGiB); validated and priced.
    [hashtable] $Sizing = @{},
    # Hours per week each host runs, for the cost estimate.
    [int] $ActiveHoursPerWeek = 50,
    # Recovery region (build/specs/recovery-spec.md); empty: what the parameter file reads from AVD_RECOVERY_LOCATION.
    [string] $RecoveryLocation
  )
  $avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'

  Write-AvdSection 'Tooling'
  Test-AvdTooling
  foreach ($tool in 'az', 'bash') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Add-AvdCheckResult 'Tooling' "$tool available (used by deploy.sh)" 'Pass' }
    else { Add-AvdCheckResult 'Tooling' "$tool available (used by deploy.sh)" 'Fail' -Remediation 'Use Azure Cloud Shell, or install it.' }
  }

  # ---- Entra ID first: the parameter file needs the group and service principal IDs ----
  $users = $null; $admins = $null; $avdSp = $null
  if ($SkipTenant) {
    Add-AvdCheckResult 'Entra ID' 'Tenant checks' 'Skip' -Detail '-SkipTenant: group and service principal checks not run; the parameter file is compiled with placeholders.'
  }
  else {
    Write-AvdSection 'Entra ID tenant'
    Connect-AvdGraph -Purpose ($(if ($Fix -or $AddMeToGroups) { 'PreDeployFix' } else { 'Read' }))
    Test-AvdSignInMatch
    $users = Resolve-AvdGroup -Label 'AVD Users' -NameOrId $UsersGroup -Fix:$Fix
    $admins = Resolve-AvdGroup -Label 'AVD Admins' -NameOrId $AdminsGroup -Fix:$Fix
    if ($AddMeToGroups) { Add-AvdCallerToGroup -Group @(@('AVD Users', $users), @('AVD Admins', $admins)) }
    foreach ($pair in @(@('AVD Users', $users), @('AVD Admins', $admins))) {
      if (-not $pair[1]) { continue }
      $m = @(Invoke-AvdGraph -Uri "v1.0/groups/$($pair[1].id)/members?`$select=id&`$top=1")
      if ($m.Count) { Add-AvdCheckResult 'Entra ID' "$($pair[0]) group has members" 'Pass' }
      else { Add-AvdCheckResult 'Entra ID' "$($pair[0]) group has members" 'Warn' -Remediation 'Add members before anyone signs in (not needed to deploy). -AddMeToGroups adds you.' }
    }
    $avdSp = Invoke-AvdGraph -Uri (Get-AvdGraphFilterUri -Collection servicePrincipals -Filter "appId eq '$avdAppId'" -Select 'id,appId,displayName') | Select-Object -First 1
    if ($avdSp) { Add-AvdCheckResult 'Entra ID' 'Azure Virtual Desktop service principal exists' 'Pass' -Detail $avdSp.id }
    elseif ($Fix -and $PSCmdlet.ShouldProcess('Azure Virtual Desktop', 'Create service principal for the first-party app')) {
      $avdSp = Invoke-AvdGraph -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = $avdAppId }
      Add-AvdCheckResult 'Entra ID' 'Azure Virtual Desktop service principal exists' 'Fixed' -Detail $avdSp.id
    }
    else { Add-AvdCheckResult 'Entra ID' 'Azure Virtual Desktop service principal exists' 'Fail' -Detail "App $avdAppId has no service principal in this tenant." -Remediation 'Rerun with -Fix, or register Microsoft.DesktopVirtualization.' }
  }

  # ---- Parameter file ----
  Write-AvdSection 'Parameter file'
  try {
    $plan = Get-AvdDeploymentPlan -ParameterFile $ParameterFile -UsersGroupId $users.id -AdminsGroupId $admins.id -AvdServicePrincipalId $avdSp.id -Location $Location -Sizing $Sizing -RecoveryLocation $RecoveryLocation
  }
  catch {
    Add-AvdCheckResult 'Parameters' "Compile $ParameterFile" 'Fail' -Detail $_.Exception.Message -Remediation 'Fix the parameter file (az bicep build-params).'
    return
  }
  $zones = @($plan.availabilityZones | ForEach-Object { [int]$_ })
  Add-AvdCheckResult 'Parameters' "Compile $ParameterFile" 'Pass' -Detail ("prefix {0}, env {1}, {2}, {3} x {4}, zones [{5}], {6}, Intune {7}" -f $plan.namePrefix, $plan.environmentName, $plan.location, $plan.sessionHostCount, $plan.sessionHostVmSize, ($zones -join ','), $plan.connectivityMode, $plan.enrollInIntune)
  if (-not $plan.location) { Add-AvdCheckResult 'Parameters' 'location set' 'Fail' -Remediation 'Set param location in the parameter file, or pass -Location.'; return }
  if ($Location -and $plan.location -ne $Location) {
    Add-AvdCheckResult 'Parameters' "Region override -Location $Location" 'Fail' -Detail "The file sets location = '$($plan.location)' instead of reading AVD_LOCATION." -Remediation "Use param location = readEnvironmentVariable('AVD_LOCATION', '<default>') in $ParameterFile."
    return
  }
  $lz = Get-AvdLandingZone -NamePrefix $plan.namePrefix -Environment $plan.environmentName

  # ---- Subscription ----
  Write-AvdSection 'Subscription'
  Test-AvdCallerPermission -SubscriptionId $lz.SubscriptionId -NeedsPolicy:$plan.enablePolicyGuardrails
  Test-AvdResourceProvider -Fix:$Fix -SkipEncryptionAtHost:(-not $plan.encryptionAtHost) -Namespace @('Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Storage', 'Microsoft.Network',
    'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.KeyVault', 'Microsoft.RecoveryServices', 'Microsoft.Security',
    'Microsoft.PolicyInsights', 'Microsoft.GuestConfiguration', 'Microsoft.Consumption')
  Test-AvdHostPoolRegion -Location $plan.location -SubscriptionId $lz.SubscriptionId
  $capacity = $null
  if ($plan.sessionHostCount -gt 0) {
    $capacity = Test-AvdVmCapacity -Location $plan.location -VmSize $plan.sessionHostVmSize -Count $plan.sessionHostCount -Zones $zones -DeployedSizes @(Get-AvdDeployedHostSize -Lz $lz) | Select-Object -Last 1
  }
  if (-not $plan.encryptionAtHost) { Add-AvdCheckResult 'Subscription' 'EncryptionAtHost not required (encryptionAtHost = false)' 'Pass' }

  # Premium file share SKU in the region
  $skus = Invoke-AvdArm -Path "/subscriptions/$($lz.SubscriptionId)/providers/Microsoft.Storage/skus?api-version=2023-05-01"
  $fileSku = @($skus.value | Where-Object { $_.name -eq $plan.profileStorageSku -and $_.kind -eq 'FileStorage' -and ($_.locations -contains $plan.location) }) | Select-Object -First 1
  $skuBlocked = $fileSku -and @($fileSku.restrictions | Where-Object { $_.type -eq 'Location' }).Count
  if ($fileSku -and -not $skuBlocked) { Add-AvdCheckResult 'Subscription' "$($plan.profileStorageSku) file shares available in $($plan.location)" 'Pass' }
  else { Add-AvdCheckResult 'Subscription' "$($plan.profileStorageSku) file shares available in $($plan.location)" 'Fail' -Remediation "Set profileStorageSku = 'Premium_LRS', or choose a region with Premium ZRS file shares." }

  Test-AvdDeletedKeyVault -Lz $lz -Location $plan.location -Fix:$Fix

  # Never leave the meter running (avd-second-brain decision 0017): a sandbox needs a budget backstop.
  if ($plan.monthlyBudgetAmount -le 0 -and $plan.environmentName -ne 'prod') {
    Add-AvdCheckResult 'Parameters' 'Budget backstop' 'Warn' -Detail "No budget is planned for this $($plan.environmentName) landing zone, so nothing alerts or locks the hosts if a run is left up. A standing budget on the subscription covers this too." -Remediation 'Set AVD_MONTHLY_BUDGET and AVD_ALERT_EMAIL before deploy.sh.'
  }

  # ---- Recovery region (warnings only) ----
  Write-AvdSection 'Recovery'
  $recovery = if ($RecoveryLocation) { $RecoveryLocation } else { $plan.recoveryLocation }
  # allowedLocations' default is an expression, so the plan has it only when the file sets it.
  $planned = if ($plan.ContainsKey('allowedLocations')) { @($plan.allowedLocations) } else { @($plan.location, $recovery) | Where-Object { $_ } }
  if ($plan.enablePolicyGuardrails -eq $false -or $plan.deploySubscriptionSettings -eq $false) { $planned = @() }
  Test-AvdRecoveryRegion -Location $plan.location -RecoveryLocation $recovery -PlannedAllowedLocations $planned -VmSize $plan.sessionHostVmSize -SubscriptionId $lz.SubscriptionId

  # Budget parameters are skipped silently by the template if incomplete; say so here.
  if ($plan.monthlyBudgetAmount -gt 0 -and (-not $plan.budgetStartDate -or -not @($plan.alertEmailAddresses).Count)) {
    Add-AvdCheckResult 'Parameters' 'Budget will be created' 'Warn' -Detail 'monthlyBudgetAmount is set but budgetStartDate or alertEmailAddresses (AVD_ALERT_EMAIL) is empty, so no budget is created.'
  }

  # ---- Sizing and cost ----
  $estimate = Test-AvdSizing -Plan $plan -VcpuPerHost $(if ($capacity) { $capacity.Vcpu } else { 0 }) -MemoryGiBPerHost $(if ($capacity) { $capacity.MemoryGiB } else { 0 }) -ActiveHoursPerWeek $ActiveHoursPerWeek

  # ---- Connectivity ----
  if ($plan.connectivityMode -eq 'HubPeered') {
    Write-AvdSection 'Hub connectivity'
    $hub = if ($plan.hubVnetResourceId) { Get-AzResource -ResourceId $plan.hubVnetResourceId -ErrorAction SilentlyContinue }
    if ($hub) { Add-AvdCheckResult 'Network' 'Hub VNet reachable' 'Pass' -Detail $hub.Name }
    else { Add-AvdCheckResult 'Network' 'Hub VNet reachable' 'Fail' -Detail "hubVnetResourceId: '$($plan.hubVnetResourceId)'" -Remediation 'Set a valid hub VNet ID you can read (and write, for hub-side peering).' }
    if ($plan.hubFirewallPrivateIp) { Add-AvdCheckResult 'Network' 'Hub firewall IP set for egress' 'Pass' -Detail $plan.hubFirewallPrivateIp }
    else { Add-AvdCheckResult 'Network' 'Hub firewall IP set for egress' 'Warn' -Detail 'Subnets have no default outbound access; without a route hosts cannot reach Entra ID or the AVD service.' -Remediation 'Set hubFirewallPrivateIp unless hub routing already supplies 0.0.0.0/0.' }
    foreach ($k in 'file', 'keyVault') {
      if ($plan.centralPrivateDnsZoneResourceIds.Count -and -not $plan.centralPrivateDnsZoneResourceIds[$k]) {
        Add-AvdCheckResult 'Network' "Central private DNS zone '$k'" 'Fail' -Remediation "centralPrivateDnsZoneResourceIds needs a '$k' zone ID."
      }
    }
  }

  # ---- Existing deployment ----
  Write-AvdSection 'Landing zone'
  $present = @($lz.RgExists.Keys | Where-Object { $_ -ne 'Demo' -and $lz.RgExists[$_] })
  $elsewhere = @($present | ForEach-Object { Get-AzResourceGroup -Name $lz.ResourceGroups[$_] -ErrorAction SilentlyContinue } | Where-Object { $_.Location -ne $plan.location })
  if ($elsewhere.Count) {
    Add-AvdCheckResult 'Landing zone' "Landing zone '$($lz.BaseName)' region" 'Fail' -Id 'lz-region' -Data @{ deployedIn = @($elsewhere.Location | Select-Object -Unique) } -Detail "Already deployed in $(($elsewhere.Location | Select-Object -Unique) -join ', '): $($elsewhere.ResourceGroupName -join ', ')" -Remediation 'Resource groups cannot change region. Deploy to that region, use another namePrefix or environment, or remove the existing landing zone first.'
  }
  elseif ($present.Count) {
    Add-AvdCheckResult 'Landing zone' "Landing zone '$($lz.BaseName)' already exists" 'Warn' -Detail "Found: $(($present | ForEach-Object { $lz.ResourceGroups[$_] }) -join ', ')" -Remediation 'Deploying updates it in place. Existing session hosts keep their break-glass password.'
    # Redeploying with a different size resizes (and restarts) every host.
    $deployedSize = Get-AvdHostVmSize -Lz $lz
    if ($deployedSize -and $deployedSize -ne $plan.sessionHostVmSize) {
      Add-AvdCheckResult 'Landing zone' 'Session host size unchanged' 'Warn' -Id 'resize' -Data @{ from = $deployedSize; to = $plan.sessionHostVmSize } `
        -Detail "The hosts are $deployedSize; deploying resizes them to $($plan.sessionHostVmSize), and each restarts." `
        -Remediation "To keep $deployedSize, deploy with --vm-size $deployedSize (the portal's sizing step sets it). Otherwise resize outside working hours, with quota for the new size."
    }
  }
  else { Add-AvdCheckResult 'Landing zone' "Name '$($lz.BaseName)' is free in this subscription" 'Pass' }

  # ---- Tenant readiness for after the deployment ----
  if (-not $SkipTenant) {
    Write-AvdSection 'Tenant (after deployment)'
    if ($plan.enrollInIntune) {
      $skusT = @(Invoke-AvdGraph -Uri 'v1.0/subscribedSkus')
      $intune = @($skusT | ForEach-Object { $_.servicePlans } | Where-Object { $_.servicePlanName -like 'INTUNE_A*' -and $_.provisioningStatus -eq 'Success' })
      if ($intune.Count) { Add-AvdCheckResult 'Entra ID' 'Intune licensing for host enrollment' 'Pass' }
      else { Add-AvdCheckResult 'Entra ID' 'Intune licensing for host enrollment' 'Fail' -Detail 'enrollInIntune = true, but the tenant has no Intune plan; the session host join would fail.' -Remediation "Add 'param enrollInIntune = false' to $ParameterFile, or license Intune." }
    }
    $roles = @(Invoke-AvdGraph -Uri 'v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName' | ForEach-Object displayName)
    $consent = @('Global Administrator', 'Cloud Application Administrator', 'Application Administrator') | Where-Object { $roles -contains $_ }
    $ca = @('Global Administrator', 'Conditional Access Administrator', 'Security Administrator') | Where-Object { $roles -contains $_ }
    if ($consent) { Add-AvdCheckResult 'Entra ID' 'You can grant the storage app admin consent (step 1)' 'Pass' -Detail ($consent -join ', ') }
    else { Add-AvdCheckResult 'Entra ID' 'You can grant the storage app admin consent (step 1)' 'Warn' -Detail 'No active Global / Cloud Application / Application Administrator role (PIM-eligible roles must be activated).' -Remediation 'Activate a role, or have an administrator run the post-deployment -Fix.' }
    if ($ca) { Add-AvdCheckResult 'Entra ID' 'You can update Conditional Access (step 2)' 'Pass' -Detail ($ca -join ', ') }
    else { Add-AvdCheckResult 'Entra ID' 'You can update Conditional Access (step 2)' 'Warn' -Detail 'No active Global / Conditional Access / Security Administrator role.' -Remediation 'Activate a role, or have an administrator run the post-deployment -Fix.' }
    try {
      $policies = @(Invoke-AvdGraph -Uri 'v1.0/identity/conditionalAccess/policies')
      $groupIds = @($users.id, $admins.id) | Where-Object { $_ }
      $needs = @($policies | Where-Object {
          $_.state -ne 'disabled' -and (@($_.conditions.applications.includeApplications) -contains 'All') -and $_.grantControls -and
          ((@($_.grantControls.builtInControls) -contains 'mfa') -or $_.grantControls.authenticationStrength) -and
          ((@($_.conditions.users.includeUsers) -contains 'All') -or (@($_.conditions.users.includeGroups) | Where-Object { $groupIds -contains $_ }))
        })
      $detail = if ($needs.Count) { "After deployment the storage app must be excluded from: $(($needs.displayName) -join '; '). The post-deployment -Fix does this." } else { 'No MFA-for-all-apps policy covers AVD users.' }
      Add-AvdCheckResult 'Entra ID' 'Conditional Access reviewed' 'Pass' -Detail $detail
    }
    catch { Add-AvdCheckResult 'Entra ID' 'Conditional Access reviewed' 'Warn' -Detail "Could not read policies: $($_.Exception.Message)" }
    Test-AvdSecurityDefault -Area 'Entra ID'
  }

  return [pscustomobject]@{ Plan = $plan; UsersGroup = $users; AdminsGroup = $admins; Estimate = $estimate }
}

# =====================================================================
# Golden image pipeline (build/specs/image-pipeline-spec.md)
# =====================================================================
function Get-AvdLatestVersion {
  <# The highest of a list of dotted versions, compared as numbers (never as strings: red-team M1). #>
  param([AllowEmptyCollection()][string[]] $Version = @())
  $parsed = @($Version | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Text = $_; Value = [version]$_ } })
  if (-not $parsed.Count) { return $null }
  ($parsed | Sort-Object Value -Descending | Select-Object -First 1).Text
}

function Get-AvdImageVersionName {
  <#
    The next gallery version for a build on $Date (UTC): YYYY.MDD.N with no zero padding, so
    January 4 is 2027.104.1 and October 4 is 2026.1004.1 (spec section 4.2, red-team M1).
    N is one more than the highest build already published that day.
  #>
  param([Parameter(Mandatory)][datetime] $Date, [AllowEmptyCollection()][string[]] $Existing = @())
  $prefix = '{0}.{1}' -f $Date.Year, ($Date.Month * 100 + $Date.Day)
  $taken = @($Existing | Where-Object { $_ -like "$prefix.*" } | ForEach-Object { [int]($_.Split('.')[2]) })
  $next = if ($taken.Count) { ($taken | Measure-Object -Maximum).Maximum + 1 } else { 1 }
  "$prefix.$next"
}

function Get-AvdRunPosition {
  <#
    Where a run stands, for Get-AvdRunStatus.ps1 (build/specs/run-recorder-spec.md section 4).
    Azure is the source of truth: the newest deploy.sh deployment record (avdlz-<parameter file>-<yyyyMMdd-HHmmss>),
    the landing zone's resource groups and the demo's deployment record. Anything it can't classify is
    'unknown' with what it saw, never a guess. A running deployment wins over everything.
    Returns @{ Status = ready|unknown; LastStage; LastStatus; NextStage; DeploymentName; Basis }.
  #>
  param(
    [Parameter(Mandatory)][string] $Environment,
    # ARM subscription deployment records (name, properties.provisioningState, properties.timestamp).
    [AllowEmptyCollection()][object[]] $Deployment = @(),
    # Get-AvdLandingZone's RgExists: Network, Management, Storage, ControlPlane, Hosts, Demo.
    [Parameter(Mandatory)][hashtable] $RgExists,
    # The demo's record (avdlz-demo-<prefix>-<env>), if there is one.
    [object] $DemoDeployment,
    [datetime] $Now = (Get-Date).ToUniversalTime()
  )
  $o = [ordered]@{ Status = 'ready'; LastStage = $null; LastStatus = $null; NextStage = $null; DeploymentName = $null; Basis = '' }
  $runs = @($Deployment | Where-Object { $_ -and $_.name -match '^avdlz-(?!demo-).+-\d{8}-\d{6}$' })
  $mine = @($runs | Where-Object { $_.name -match "^avdlz-$([regex]::Escape($Environment))-\d{8}-\d{6}$" })
  if ($mine.Count) { $runs = $mine }
  $latest = $runs | Sort-Object { [datetime]$_.properties.timestamp } -Descending | Select-Object -First 1
  $core = @('Network', 'Management', 'Storage', 'ControlPlane', 'Hosts' | Where-Object { $RgExists[$_] })
  $ago = { param($t, $n) $m = [math]::Max(0, [math]::Round(($n - ([datetime]$t).ToUniversalTime()).TotalMinutes)); if ($m -lt 120) { "$m minutes ago" } else { "$([math]::Round($m / 60)) hours ago" } }

  if ($latest) {
    $o.DeploymentName = $latest.name
    $state = "$($latest.properties.provisioningState)"
    $when = & $ago $latest.properties.timestamp $Now
    if ($state -in 'Running', 'Accepted', 'Deploying', 'Created') {
      $o.LastStage = 'deploy'; $o.LastStatus = 'running'; $o.NextStage = 'deploy'
      $o.Basis = "Azure shows deployment $($latest.name) running (last update $when)."
      return $o
    }
    if ($state -in 'Failed', 'Canceled') {
      $o.LastStage = 'deploy'; $o.LastStatus = 'failed'; $o.NextStage = 'deploy'
      $o.Basis = "Azure shows deployment $($latest.name) $($state.ToLower()) ($when)."
      return $o
    }
  }
  if (-not $core.Count) {
    $o.LastStage = if ($latest) { 'cleanup' } else { $null }
    $o.NextStage = 'predeploy'
    $o.Basis = if ($latest) { "No landing zone resource groups found; the last deployment ($($latest.name)) was removed since." } else { 'No landing zone and no deployment record found: start from the beginning.' }
    return $o
  }
  if (-not $latest -or "$($latest.properties.provisioningState)" -ne 'Succeeded' -or $core.Count -lt 5) {
    $o.Status = 'unknown'
    $o.Basis = "Found resource groups ($($core -join ', ')) but $(if ($latest) { "deployment $($latest.name) is $($latest.properties.provisioningState) and not every group exists" } else { 'no deployment record' })."
    return $o
  }
  $o.LastStage = 'deploy'; $o.LastStatus = 'succeeded'
  if ($RgExists['Demo'] -and $DemoDeployment -and "$($DemoDeployment.properties.provisioningState)" -eq 'Succeeded') {
    $o.LastStage = 'demo'; $o.NextStage = 'verify'
    $o.Basis = "The landing zone and the demo are deployed ($(& $ago $DemoDeployment.properties.timestamp $Now)): check that you can connect."
    return $o
  }
  $o.NextStage = 'postdeploy'
  $o.Basis = "Azure shows the deployment succeeded ($(& $ago $latest.properties.timestamp $Now)). The post-deployment setup is safe to run again if it already ran."
  $o
}

# =====================================================================
# Deployment portal published into the subscription (Publish-AvdPortal.ps1, decision 0017)
# =====================================================================
# Static Web Apps creates resources only in these regions (the content is served globally).
$script:StaticWebAppRegions = @('centralus', 'eastus2', 'westus2', 'westeurope', 'eastasia')
# Built-in policy definitions that can block the portal: allowed locations (resources), and for resource groups.
$script:AllowedLocationsPolicyIds = @{ Resources = 'e56962a6-4747-49cd-b67b-bf8b01975c4c'; ResourceGroups = 'e765b5de-1225-4ba3-bd56-1ac6695af988' }

function Get-AvdPortalHostRegion {
  <#
    Where the portal's resources go, and whether an allowed-locations policy lets them (red team PH-6).
    Assignments: the subscription's policy assignments, as ARM returns them. Returns Location (the
    resource group's), ResourceLocation (the host's), Allowed, and Detail/Remediation when blocked.
  #>
  param(
    [Parameter(Mandatory)][ValidateSet('StaticWebApp', 'Storage')][string] $Hosting,
    [Parameter(Mandatory)][string] $Location,
    [string] $StaticWebAppLocation,
    [AllowEmptyCollection()][object[]] $Assignments = @()
  )
  $allowed = { param($kind, $all)
    $id = $script:AllowedLocationsPolicyIds[$kind]
    $lists = @($all | Where-Object { $_ -and "$($_.properties.policyDefinitionId)" -like "*/$id" -and "$($_.properties.enforcementMode)" -ne 'DoNotEnforce' } |
        ForEach-Object { , @($_.properties.parameters.listOfAllowedLocations.value | Where-Object { $_ }) })
    if (-not $lists.Count) { return $null }
    # Every assignment must allow it: intersect the lists.
    $set = $lists[0]; foreach ($l in $lists) { $set = @($set | Where-Object { $l -contains $_ }) }
    , @($set | ForEach-Object { "$_".ToLower() })
  }
  $res = & $allowed 'Resources' $Assignments; $rgs = & $allowed 'ResourceGroups' $Assignments
  $where = $Location.ToLower()
  if ($Hosting -eq 'StaticWebApp') {
    $where = if ($StaticWebAppLocation) { $StaticWebAppLocation.ToLower() }
    elseif ($script:StaticWebAppRegions -contains $Location.ToLower()) { $Location.ToLower() }
    elseif ($res) { @($script:StaticWebAppRegions | Where-Object { $res -contains $_ }) + @('centralus') | Select-Object -First 1 }
    else { 'centralus' }
  }
  $out = [ordered]@{ Hosting = $Hosting; Location = $Location.ToLower(); ResourceLocation = $where; Allowed = $true; Detail = ''; Remediation = '' }
  if ($Hosting -eq 'StaticWebApp' -and $script:StaticWebAppRegions -notcontains $where) {
    $out.Allowed = $false
    $out.Detail = "Static Web Apps isn't offered in $where; it is in $($script:StaticWebAppRegions -join ', ')."
    $out.Remediation = "Pass -StaticWebAppLocation with one of those, or publish to a storage static website in $($Location.ToLower()) with -Hosting Storage."
  }
  elseif ($rgs -and $rgs -notcontains $out.Location) {
    $out.Allowed = $false
    $out.Detail = "An allowed-locations policy blocks resource groups in $($out.Location) (allowed: $($rgs -join ', '))."
    $out.Remediation = "Pass -Location with one of: $($rgs -join ', ')."
  }
  elseif ($res -and $res -notcontains $where) {
    $out.Allowed = $false
    $out.Detail = "An allowed-locations policy blocks resources in $where (allowed: $($res -join ', '))."
    $out.Remediation = if ($Hosting -eq 'StaticWebApp') { "Static Web Apps needs one of $($script:StaticWebAppRegions -join ', ') on the allowed list (the landing zone's allowedLocations parameter, or a policy exemption), or publish with -Hosting Storage, which uses $($out.Location)." } else { "Pass -Location with one of: $($res -join ', ')." }
  }
  [pscustomobject]$out
}

function Get-AvdPortalConfigScript {
  <#
    The portal-config.js a published copy serves: one JSON object on one known global (red team PH-4).
    The portal validates repoUrl and ref again before putting them in a command.
  #>
  param(
    [Parameter(Mandatory)][string] $RepoUrl,
    [Parameter(Mandatory)][string] $Ref,
    [Parameter(Mandatory)][string] $PortalUrl,
    [Parameter(Mandatory)][ValidateSet('StaticWebApp', 'Storage')][string] $Hosting,
    # The commit the ref resolves to, when the checkout knows it: the portal compares it with the
    # commit in each pasted state line (red team PH-8).
    [string] $Commit
  )
  if ($RepoUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$' -or $RepoUrl -match '\.\.') { throw "-RepoUrl must be a GitHub repository URL (https://github.com/<owner>/<repo>), not '$RepoUrl'." }
  if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$' -or $Ref -match '\.\.|//|/$|\.lock$') { throw "-Ref must be a tag or commit, not '$Ref'." }
  if ($Commit -and $Commit -notmatch '^[0-9a-f]{7,40}$') { throw "-Commit must be a commit hash, not '$Commit'." }
  $cfg = [ordered]@{ repoUrl = $RepoUrl.TrimEnd('/'); ref = $Ref; portalUrl = $PortalUrl; hosting = $Hosting }
  if ($Commit) { $cfg['commit'] = $Commit }
  $json = $cfg | ConvertTo-Json -Compress
  "/* Written by scripts/ops/Publish-AvdPortal.ps1 (decision 0017). */`nwindow.AVDLZ_PORTAL_CONFIG = $json;`n"
}

function Get-AvdStaticWebAppConfig {
  <#
    staticwebapp.config.json for a published copy: response headers the page can't set on GitHub
    Pages (red team PH-9), and with -RequireSignIn every route locked to the invited 'operator' role.
    The Free plan's built-in sign-in lets any Microsoft account in, so 'authenticated' alone is never
    used (red team PH-1); GitHub sign-in is turned off.
  #>
  param([switch] $RequireSignIn)
  $csp = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src https:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
  $config = [ordered]@{
    globalHeaders = [ordered]@{
      'Content-Security-Policy' = $csp
      'X-Frame-Options'         = 'DENY'
      'X-Content-Type-Options'  = 'nosniff'
      'Referrer-Policy'         = 'no-referrer'
    }
  }
  if ($RequireSignIn) {
    $config.routes = @(
      [ordered]@{ route = '/.auth/login/github'; statusCode = 404 },
      [ordered]@{ route = '/.auth/*'; allowedRoles = @('anonymous') },
      [ordered]@{ route = '/denied.html'; allowedRoles = @('anonymous') },
      [ordered]@{ route = '/*'; allowedRoles = @('operator') }
    )
    $config.responseOverrides = [ordered]@{
      '401' = [ordered]@{ redirect = '/.auth/login/aad'; statusCode = 302 }
      '403' = [ordered]@{ rewrite = '/denied.html'; statusCode = 403 }
    }
  }
  $config | ConvertTo-Json -Depth 6
}

function Get-AvdPortalContentType {
  <# The Content-Type a storage static website serves a file with (blobs keep the type they were uploaded with). #>
  param([Parameter(Mandatory)][string] $Path)
  $types = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8'
    '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.md' = 'text/markdown; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
    '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.ico' = 'image/x-icon'; '.webp' = 'image/webp'
    '.woff2' = 'font/woff2'; '.woff' = 'font/woff'
  }
  $ext = [IO.Path]::GetExtension($Path).ToLower()
  if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
}

Export-ModuleMember -Function *-Avd*
