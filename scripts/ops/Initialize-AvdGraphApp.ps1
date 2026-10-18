# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  One-time setup of the "avd-opsbot" app registration, so operators sign in
  to Microsoft Graph once per Cloud Shell session with no consent prompts (decision 0016).

.DESCRIPTION
  Runs in Azure Cloud Shell (PowerShell) and in Windows PowerShell 5.1 with the
  Microsoft.Graph.Authentication module. Safe to run again: it changes only what is missing.

  - Creates (or reuses) a public client app registration with no secret and no certificate,
    and the delegated Microsoft Graph permissions the landing zone scripts use.
  - Creates (or reuses) its service principal with "Assignment required" on.
  - Grants admin consent for those permissions (one tenant-wide delegated grant). Because
    assignment is required, only assigned users and groups can sign in through the app.
  - Assigns you, and the operators group (default: AVD Admins) when it exists.
  - Prints the client ID and the line that keeps it. -SaveToProfile adds that line to your
    PowerShell profile (Cloud Shell keeps the profile only with a storage account).

  Needs a Global Administrator, or a Privileged Role Administrator with an Application
  Administrator. It signs in through Microsoft's default Graph app for this run only.

.EXAMPLE
  ./scripts/ops/Initialize-AvdGraphApp.ps1 -SaveToProfile

.EXAMPLE
  ./scripts/ops/Initialize-AvdGraphApp.ps1 -OperatorsGroup 'AVD Operators' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  # Group (display name or object ID) whose members may sign in through the app. Skipped with a warning if it doesn't exist.
  [string] $OperatorsGroup = 'AVD Admins',
  # Tenant to set up; defaults to the Azure context's tenant, else your home tenant.
  [string] $TenantId,
  [string] $AppName = 'avd-opsbot',
  [switch] $SaveToProfile
)

$ErrorActionPreference = 'Stop'

# Must match Get-AvdGraphScope in AvdLandingZone.psm1 (tests/AvdLandingZone.Tests.ps1 compares them).
$operatorScopes = @(
  'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess',
  'Group.ReadWrite.All', 'Directory.Read.All', 'Device.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All'
)
# Sign-in scopes, so the consent covers the whole sign-in and nobody sees a prompt.
$grantScopes = @('openid', 'profile', 'offline_access') + $operatorScopes
$setupScopes = @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Group.Read.All', 'Directory.Read.All')
$graphAppId = '00000003-0000-0000-c000-000000000000'
# The default access role, for an app that defines no app roles of its own.
$defaultAccess = '00000000-0000-0000-0000-000000000000'
$script:failed = 0

function Write-Step {
  param([string] $Status, [string] $Check, [string] $Detail = '', [string] $Remediation = '')
  $color = @{ Pass = 'Green'; Fixed = 'Cyan'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Status]
  Write-Host ('  [{0,-5}] {1}' -f $Status.ToUpper(), $Check) -ForegroundColor $color
  if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
  if ($Remediation) { Write-Host "          -> $Remediation" -ForegroundColor DarkYellow }
  if ($Status -eq 'Fail') { $script:failed++ }
}

function Invoke-SetupGraph {
  <# REST through Invoke-MgGraphRequest, as Invoke-AvdGraph does: GETs follow nextLink and stop on any error. #>
  param([Parameter(Mandatory)][string] $Uri, [string] $Method = 'GET', [object] $Body)
  $p = @{ Method = $Method; OutputType = 'PSObject'; ErrorAction = 'Stop' }
  if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
  if ($Method -ne 'GET') { return Invoke-MgGraphRequest @p -Uri $Uri }
  $items = New-Object System.Collections.Generic.List[object]
  $next = $Uri
  while ($next) {
    $graphErr = $null
    $r = Invoke-MgGraphRequest @p -Uri $next -ErrorVariable graphErr
    if ($graphErr) { throw "Graph GET $next failed: $($graphErr[0])" }
    if ($null -eq $r) { throw "Graph GET $next returned no response." }
    if ($r.PSObject.Properties['value']) {
      foreach ($v in $r.value) { $items.Add($v) }
      $link = $r.PSObject.Properties['@odata.nextLink']
      $next = if ($link) { $link.Value } else { $null }
    }
    else { return $r }
  }
  return $items.ToArray()
}

function Get-FilterUri {
  param([string] $Collection, [string] $Filter, [string] $Select)
  $uri = "v1.0/$Collection`?`$filter=$([uri]::EscapeDataString($Filter))"
  if ($Select) { $uri += "&`$select=$Select" }
  $uri
}

function Invoke-AfterReplication {
  <# A new app takes a few seconds to reach every Entra ID replica; retry "not found" for up to a minute. #>
  param([Parameter(Mandatory)][scriptblock] $Action, [Parameter(Mandatory)][string] $What)
  for ($i = 1; $i -le 6; $i++) {
    try { return & $Action }
    catch {
      if ($i -eq 6 -or "$_" -notmatch 'does not exist|ResourceNotFound|NoBackingApplicationObject|Request_BadRequest.*not found') { throw }
      Write-Host "  Entra ID is still replicating the new app ($What); trying again in 10 seconds ($i of 5)." -ForegroundColor DarkGray
      Start-Sleep -Seconds 10
    }
  }
}

# ---- Sign in (Microsoft's default app, for this setup only) ----
Write-Host ''
Write-Host "== $AppName app registration" -ForegroundColor White
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
  throw 'Module Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
if (-not $TenantId -and (Get-Command Get-AzContext -ErrorAction SilentlyContinue)) {
  $azCtx = Get-AzContext
  if ($azCtx) { $TenantId = $azCtx.Tenant.Id }
}
$connect = @{ Scopes = $setupScopes; NoWelcome = $true; ErrorAction = 'Stop' }
if ($TenantId) { $connect.TenantId = $TenantId }
$cloudShell = [bool]$env:ACC_CLOUD -or ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*')
Write-Host "  Signing in to Microsoft Graph for the setup ($($setupScopes -join ', '))" -ForegroundColor DarkGray
if ($cloudShell) {
  $connect.UseDeviceCode = $true
  Write-Host '  ACTION NEEDED: open https://microsoft.com/devicelogin and enter the code below, as an administrator. The script waits until you sign in.' -ForegroundColor Yellow
}
# Never | Out-Null: that hides the device code (lesson 0007).
Connect-MgGraph @connect | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
$me = Invoke-SetupGraph -Uri 'v1.0/me?$select=id,userPrincipalName'
Write-Step Pass "Signed in as $($me.userPrincipalName)"

# ---- Microsoft Graph's permission IDs, read from the tenant (no hard-coded IDs) ----
$graphSp = Invoke-SetupGraph -Uri (Get-FilterUri -Collection servicePrincipals -Filter "appId eq '$graphAppId'" -Select 'id,oauth2PermissionScopes') | Select-Object -First 1
if (-not $graphSp) {
  Write-Step Fail 'Microsoft Graph service principal' -Detail "No service principal for appId $graphAppId in this tenant."
  exit 1
}
$scopeIds = [ordered]@{}
foreach ($s in $grantScopes) {
  $def = @($graphSp.oauth2PermissionScopes | Where-Object value -eq $s) | Select-Object -First 1
  if ($def) { $scopeIds[$s] = $def.id }
}
# Graph's service principal doesn't list every delegated permission it issues: in a real tenant
# Device.ReadWrite.All was missing from oauth2PermissionScopes, yet tokens carried it (lesson 0030).
# The consent grant names scopes by value, so those are still granted; the app registration's
# permission list only shows the ones with an ID.
$unlisted = @($grantScopes | Where-Object { -not $scopeIds.Contains($_) })
if ($unlisted.Count) {
  Write-Step Pass 'Microsoft Graph permissions resolved' -Detail "Not listed on Graph's service principal, so granted by name only and not shown under the app's API permissions: $($unlisted -join ', ')"
}

# ---- App registration ----
$apps = @(Invoke-SetupGraph -Uri (Get-FilterUri -Collection applications -Filter "displayName eq '$($AppName.Replace("'", "''"))'" -Select 'id,appId,displayName,isFallbackPublicClient,publicClient,requiredResourceAccess'))
if ($apps.Count -gt 1) {
  Write-Step Fail "App registration '$AppName'" -Detail "$($apps.Count) app registrations have this name: $(($apps | ForEach-Object appId) -join ', ')" -Remediation 'Delete the extra ones, or pass -AppName.'
  exit 1
}
$app = $apps | Select-Object -First 1
if (-not $app) {
  # Earlier name of the same app: rename it rather than create a second one, so its client ID stays.
  $legacy = @(Invoke-SetupGraph -Uri (Get-FilterUri -Collection applications -Filter "displayName eq 'AVD Landing Zone Operator'" -Select 'id,appId,displayName,isFallbackPublicClient,publicClient,requiredResourceAccess'))
  if ($legacy.Count -eq 1 -and $PSCmdlet.ShouldProcess($legacy[0].displayName, "Rename to $AppName")) {
    Invoke-SetupGraph -Method PATCH -Uri "v1.0/applications/$($legacy[0].id)" -Body @{ displayName = $AppName } | Out-Null
    $app = $legacy[0]
    Write-Step Fixed "App registration '$AppName'" -Detail "Renamed from '$($legacy[0].displayName)'. Client ID unchanged: $($app.appId)"
  }
}
$wantAccess = @($scopeIds.Values | ForEach-Object { @{ id = $_; type = 'Scope' } })
if (-not $app) {
  if ($PSCmdlet.ShouldProcess($AppName, 'Create a public client app registration with delegated Microsoft Graph permissions')) {
    $app = Invoke-SetupGraph -Method POST -Uri 'v1.0/applications' -Body @{
      displayName            = $AppName
      description            = 'Delegated Microsoft Graph sign-in for the AVD landing zone scripts. Public client: no secret, no certificate.'
      signInAudience         = 'AzureADMyOrg'
      isFallbackPublicClient = $true
      publicClient           = @{ redirectUris = @('http://localhost') }
      requiredResourceAccess = @(@{ resourceAppId = $graphAppId; resourceAccess = $wantAccess })
    }
    Write-Step Fixed "App registration '$AppName'" -Detail "Created. Client ID $($app.appId)"
  }
  else { Write-Step Skip "App registration '$AppName'" -Detail 'Would be created.'; exit 0 }
}
else {
  $graphRra = @($app.requiredResourceAccess | Where-Object resourceAppId -eq $graphAppId) | Select-Object -First 1
  $haveIds = @($graphRra.resourceAccess | Where-Object type -eq 'Scope' | ForEach-Object id)
  $missingIds = @($scopeIds.Keys | Where-Object { $haveIds -notcontains $scopeIds[$_] })
  $redirects = @($app.publicClient.redirectUris)
  $changes = @()
  $patch = @{}
  if ($app.isFallbackPublicClient -ne $true) { $patch.isFallbackPublicClient = $true; $changes += 'public client' }
  if ($redirects -notcontains 'http://localhost') { $patch.publicClient = @{ redirectUris = @($redirects | Where-Object { $_ }) + 'http://localhost' }; $changes += 'redirect URI http://localhost' }
  if ($missingIds.Count) {
    $other = @($app.requiredResourceAccess | Where-Object resourceAppId -ne $graphAppId)
    $keep = @($graphRra.resourceAccess | Where-Object { $_ })
    $add = @($missingIds | ForEach-Object { @{ id = $scopeIds[$_]; type = 'Scope' } })
    $patch.requiredResourceAccess = @($other) + @(@{ resourceAppId = $graphAppId; resourceAccess = @($keep) + $add })
    $changes += "permissions $($missingIds -join ', ')"
  }
  if (-not $changes.Count) { Write-Step Pass "App registration '$AppName'" -Detail "Client ID $($app.appId)" }
  elseif ($PSCmdlet.ShouldProcess($AppName, "Update: $($changes -join '; ')")) {
    Invoke-SetupGraph -Method PATCH -Uri "v1.0/applications/$($app.id)" -Body $patch | Out-Null
    Write-Step Fixed "App registration '$AppName'" -Detail "Client ID $($app.appId). Added: $($changes -join '; ')"
  }
}

# ---- Service principal, assignment required ----
$sp = Invoke-SetupGraph -Uri (Get-FilterUri -Collection servicePrincipals -Filter "appId eq '$($app.appId)'" -Select 'id,appId,displayName,appRoleAssignmentRequired') | Select-Object -First 1
# The enterprise application keeps its own display name; follow the app registration's.
if ($sp -and $sp.displayName -ne $AppName -and $PSCmdlet.ShouldProcess($sp.displayName, "Rename the enterprise application to $AppName")) {
  Invoke-SetupGraph -Method PATCH -Uri "v1.0/servicePrincipals/$($sp.id)" -Body @{ displayName = $AppName } | Out-Null
  Write-Step Fixed "Enterprise application '$AppName'" -Detail "Renamed from '$($sp.displayName)'."
}
if (-not $sp) {
  if ($PSCmdlet.ShouldProcess($AppName, 'Create the service principal with assignment required')) {
    $sp = Invoke-AfterReplication -What 'service principal' -Action {
      Invoke-SetupGraph -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = $app.appId; appRoleAssignmentRequired = $true; tags = @('WindowsAzureActiveDirectoryIntegratedApp') }
    }
    Write-Step Fixed 'Service principal, assignment required' -Detail "Created $($sp.id)"
  }
}
elseif ($sp.appRoleAssignmentRequired -ne $true) {
  if ($PSCmdlet.ShouldProcess($AppName, 'Turn on assignment required')) {
    Invoke-SetupGraph -Method PATCH -Uri "v1.0/servicePrincipals/$($sp.id)" -Body @{ appRoleAssignmentRequired = $true } | Out-Null
    Write-Step Fixed 'Service principal, assignment required' -Detail 'Assignment required turned on: only assigned users and groups can sign in.'
  }
}
else { Write-Step Pass 'Service principal, assignment required' }
if (-not $sp) { exit 0 }

# ---- Admin consent: one delegated grant; assignment required limits who can use it ----
$grant = @(Invoke-SetupGraph -Uri (Get-FilterUri -Collection oauth2PermissionGrants -Filter "clientId eq '$($sp.id)'") |
    Where-Object { $_.clientId -eq $sp.id -and $_.consentType -eq 'AllPrincipals' -and $_.resourceId -eq $graphSp.id }) | Select-Object -First 1
$have = if ($grant) { @($grant.scope -split ' ' | Where-Object { $_ }) } else { @() }
$missing = @($grantScopes | Where-Object { $have -notcontains $_ })
if (-not $missing.Count) { Write-Step Pass 'Admin consent for the Microsoft Graph permissions' }
elseif ($PSCmdlet.ShouldProcess($AppName, "Grant admin consent: $($missing -join ' ')")) {
  if ($grant) {
    Invoke-SetupGraph -Method PATCH -Uri "v1.0/oauth2PermissionGrants/$($grant.id)" -Body @{ scope = (@($have) + $missing) -join ' ' } | Out-Null
  }
  else {
    Invoke-AfterReplication -What 'consent' -Action {
      Invoke-SetupGraph -Method POST -Uri 'v1.0/oauth2PermissionGrants' -Body @{ clientId = $sp.id; consentType = 'AllPrincipals'; resourceId = $graphSp.id; scope = $grantScopes -join ' ' }
    } | Out-Null
  }
  Write-Step Fixed 'Admin consent for the Microsoft Graph permissions' -Detail "Granted: $($missing -join ' ')"
}

# ---- Who may sign in: you, and the operators group ----
$assigned = @(Invoke-SetupGraph -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$select=principalId,principalDisplayName" | ForEach-Object principalId)
$principals = @(@{ id = $me.id; name = $me.userPrincipalName; kind = 'you' })
if ($OperatorsGroup) {
  $guid = [guid]::Empty
  $groups = if ([guid]::TryParse($OperatorsGroup, [ref]$guid)) {
    @(try { Invoke-SetupGraph -Uri "v1.0/groups/$OperatorsGroup`?`$select=id,displayName" } catch { $null }) | Where-Object { $_ }
  }
  else { @(Invoke-SetupGraph -Uri (Get-FilterUri -Collection groups -Filter "displayName eq '$($OperatorsGroup.Replace("'", "''"))'" -Select 'id,displayName')) }
  if ($groups.Count -eq 1) { $principals += @{ id = $groups[0].id; name = $groups[0].displayName; kind = 'group' } }
  elseif ($groups.Count -gt 1) { Write-Step Warn "Operators group '$OperatorsGroup'" -Detail "$($groups.Count) groups have this name; none assigned." -Remediation 'Pass -OperatorsGroup with the group object ID.' }
  else { Write-Step Warn "Operators group '$OperatorsGroup'" -Detail 'Not found; only you are assigned.' -Remediation 'Create it with the pre-deployment preflight -Fix, or pass -OperatorsGroup, and run this again.' }
}
foreach ($principal in $principals) {
  $label = if ($principal.kind -eq 'you') { "You ($($principal.name)) can sign in through the app" } else { "Group '$($principal.name)' can sign in through the app" }
  if ($assigned -contains $principal.id) { Write-Step Pass $label; continue }
  if (-not $PSCmdlet.ShouldProcess($principal.name, "Assign to $AppName")) { continue }
  try {
    Invoke-AfterReplication -What 'assignment' -Action {
      Invoke-SetupGraph -Method POST -Uri "v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" -Body @{ principalId = $principal.id; resourceId = $sp.id; appRoleId = $defaultAccess }
    } | Out-Null
    Write-Step Fixed $label -Detail 'Assigned.'
  }
  catch {
    # Assigning a group to an app needs Microsoft Entra ID P1; report what Graph said (lesson 0012).
    $why = "$_"
    $fix = if ($principal.kind -eq 'group') { 'Assigning groups needs Microsoft Entra ID P1. Without it, assign each operator in Entra ID > Enterprise applications > Users and groups.' } else { 'Assign yourself in Entra ID > Enterprise applications > Users and groups.' }
    Write-Step Fail $label -Detail $why -Remediation $fix
  }
}

# ---- Keep the client ID ----
$line = "`$env:AVD_GRAPH_CLIENT_ID = '$($app.appId)'"
$env:AVD_GRAPH_CLIENT_ID = $app.appId
if ($SaveToProfile) {
  $profileText = if (Test-Path $PROFILE) { Get-Content -Raw $PROFILE } else { '' }
  if ($profileText -match [regex]::Escape($line)) { Write-Step Pass 'Client ID in your PowerShell profile' -Detail $PROFILE }
  elseif ($PSCmdlet.ShouldProcess($PROFILE, "Add $line")) {
    $profileDir = Split-Path $PROFILE
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    # Replace an older client ID rather than adding a second line.
    $kept = @(($profileText -split "`r?`n") | Where-Object { $_ -notmatch '^\$env:AVD_GRAPH_CLIENT_ID\s*=' -and $_ -ne '' })
    Set-Content -Path $PROFILE -Value (@($kept) + $line)
    Write-Step Fixed 'Client ID in your PowerShell profile' -Detail "$PROFILE. Cloud Shell keeps it only with a storage account; otherwise set it in each session."
  }
}

Write-Host ''
if ($script:failed) {
  Write-Host "== $($script:failed) step(s) failed. Fix them and run this again; it changes only what is missing." -ForegroundColor Red
  exit 1
}
Write-Host "== Done. Client ID: $($app.appId)" -ForegroundColor Green
Write-Host '   Keep it for each Cloud Shell session (it is not a secret):' -ForegroundColor White
Write-Host "   $line" -ForegroundColor White
Write-Host '   Then sign in once per session, before the other scripts:' -ForegroundColor White
Write-Host '   ./scripts/ops/Connect-AvdLandingZone.ps1' -ForegroundColor White
exit 0
