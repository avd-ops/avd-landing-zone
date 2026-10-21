#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Publishes the deployment portal into your own subscription (optional; decision 0017).

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) at the repo root. You don't need this to deploy: the
  portal on GitHub Pages works for everyone. Publish a copy when you want the portal in your own
  subscription, for a fork, or pinned to a release.

  1. Checks the subscription's allowed-locations policies against the host's region before
     creating anything.
  2. Deploys bicep/portal/main.bicep: rg-<prefix>-<env>-portal with
       -Hosting StaticWebApp (default)  Azure Static Web Apps, Free plan ($0). Created in one of
                                         centralus, eastus2, westus2, westeurope, eastasia. Uploaded
                                         with the Static Web Apps CLI (npm, pinned version).
       -Hosting Storage                  A storage account's static website, in -Location (cents a
                                         month). Pure Az PowerShell: no npm, no deployment token, no
                                         app consent. Anyone with the URL can open it.
  3. Uploads site/portal and site/assets with a portal-config.js naming the repo and the ref every
     command clones and checks out (-RepoUrl, -Ref; default: this checkout's origin and commit).
  4. Prints the portal's URL and the AVD_PORTAL_URL line that makes the scripts point to it.

  -RequireSignIn (StaticWebApp only) locks every page to users you invite to the 'operator' role
  (up to 25 on the Free plan) and invites you. The Free plan's sign-in accepts any Microsoft
  account, so signing in alone is never enough. Single-tenant sign-in, IP restrictions and private
  endpoints need the Standard plan (about $9 a month): your choice in the Azure portal, never this
  script's.

  The Static Web Apps deployment token never leaves this process: it is passed to the CLI in an
  environment variable, cleared, and reset after the upload so the token the shell saw is dead.

  -Remove deletes rg-<prefix>-<env>-portal. Remove-AvdDemo.ps1 -IncludeLandingZone does too.

.EXAMPLE
  ./scripts/ops/Publish-AvdPortal.ps1 -NamePrefix avdlz -Environment dev -Location eastus2

.EXAMPLE
  ./scripts/ops/Publish-AvdPortal.ps1 -NamePrefix avdlz -Environment dev -Location northcentralus -Hosting Storage

.EXAMPLE
  ./scripts/ops/Publish-AvdPortal.ps1 -NamePrefix avdlz -Environment dev -Location eastus2 -RequireSignIn -RepoUrl https://github.com/contoso/avd-landing-zone -Ref v1.2.0
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateLength(2, 8)][string] $NamePrefix,
  [Parameter(Mandatory)][ValidateSet('dev', 'test', 'prod')][string] $Environment,
  # The resource group's region and, for Storage, the account's: normally the landing zone's.
  [Parameter(Mandatory)][string] $Location,
  [ValidateSet('StaticWebApp', 'Storage')][string] $Hosting = 'StaticWebApp',
  # Empty: -Location when Static Web Apps is offered there, else the first one the policies allow.
  [ValidateSet('', 'centralus', 'eastus2', 'westus2', 'westeurope', 'eastasia')][string] $StaticWebAppLocation = '',
  [switch] $RequireSignIn,
  # The repo the portal's commands clone, and the tag or commit they check out. Empty: this checkout's.
  [string] $RepoUrl,
  [string] $Ref,
  [string] $SubscriptionId,
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
$repoRoot = Join-Path $PSScriptRoot '../..' | Resolve-Path
$template = Join-Path $repoRoot 'bicep/portal/main.bicep'
# Pinned on purpose (red team PH-2): bump it in a PR, never float it.
$swaCli = '@azure/static-web-apps-cli@2.1.0'
$webApi = '2023-12-01'

if ($RequireSignIn -and $Hosting -ne 'StaticWebApp') { throw '-RequireSignIn needs -Hosting StaticWebApp: a storage static website has no sign-in.' }

$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
Write-Host "AVD deployment portal - $NamePrefix/$Environment in '$($ctx.Subscription.Name)'" -ForegroundColor White
Clear-AvdCheckResult
$clean = $NamePrefix.ToLower().Replace('-', '')
$rgName = "rg-$clean-$Environment-portal"
$sub = "/subscriptions/$($ctx.Subscription.Id)"

if ($Remove) {
  Write-AvdSection 'Remove the published portal'
  if (-not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) { Add-AvdCheckResult 'Portal' $rgName 'Pass' -Detail 'Not present.' }
  else {
    Write-Host "  Deleting $rgName (a minute or two)..." -ForegroundColor DarkGray
    Remove-AzResourceGroup -Name $rgName -Force | Out-Null
    Add-AvdCheckResult 'Portal' $rgName 'Fixed' -Detail 'Deleted.' -Remediation 'In each Cloud Shell that set it: Remove-Item Env:AVD_PORTAL_URL (and the line in $PROFILE, if you added one).'
  }
  Write-AvdSummary
  if (@(Get-AvdCheckResult | Where-Object Status -eq 'Fail').Count) { exit 1 }
  return
}

# ---------------------------------------------------------------------
# 1. What the commands will run, and where the portal can go
# ---------------------------------------------------------------------
Write-AvdSection 'Source'
if (-not $RepoUrl) {
  $origin = "$(git -C $repoRoot remote get-url origin 2>$null)".Trim()
  $RepoUrl = $origin -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
}
if (-not $Ref) { $Ref = "$(git -C $repoRoot rev-parse HEAD 2>$null)".Trim() }
if (-not $RepoUrl -or -not $Ref) { throw 'Could not read the repo URL or commit from this checkout. Pass -RepoUrl and -Ref.' }
# The commit the ref resolves to in this checkout, for the portal's version check (red team PH-8); a
# ref this checkout doesn't have leaves it out.
$Commit = "$(git -C $repoRoot rev-parse --verify --quiet "$Ref^{commit}" 2>$null)".Trim()
if ($Commit -notmatch '^[0-9a-f]{40}$') { $Commit = '' }
# Validates both (throws with the reason); the portal checks them again before using them.
$null = Get-AvdPortalConfigScript -RepoUrl $RepoUrl -Ref $Ref -PortalUrl 'https://example.com/' -Hosting $Hosting
Add-AvdCheckResult 'Portal' 'Commands clone and check out' 'Pass' -Detail "$RepoUrl at $Ref"

Write-AvdSection 'Region and policy'
Write-Host '  Reading the subscription''s policy assignments...' -ForegroundColor DarkGray
$assignments = @(Get-AvdArmList -Path "$sub/providers/Microsoft.Authorization/policyAssignments?api-version=2024-04-01")
$region = Get-AvdPortalHostRegion -Hosting $Hosting -Location $Location -StaticWebAppLocation $StaticWebAppLocation -Assignments $assignments
if (-not $region.Allowed) {
  Add-AvdCheckResult 'Portal' "Region $($region.ResourceLocation)" 'Fail' -Detail $region.Detail -Remediation $region.Remediation
  Write-AvdSummary
  exit 1
}
Add-AvdCheckResult 'Portal' "Region $($region.ResourceLocation)" 'Pass' -Detail $(if ($Hosting -eq 'StaticWebApp') { "Resource group in $($region.Location); Static Web Apps serves the content from everywhere." } else { '' })

if ($Hosting -eq 'StaticWebApp' -and -not (Get-Command npx -ErrorAction SilentlyContinue)) {
  Add-AvdCheckResult 'Portal' 'npx (Node.js) for the Static Web Apps CLI' 'Fail' -Remediation 'Run this in Azure Cloud Shell, which has Node.js, or publish with -Hosting Storage.'
  Write-AvdSummary
  exit 1
}

# ---------------------------------------------------------------------
# 2. The host
# ---------------------------------------------------------------------
Write-AvdSection 'Host'
$me = Get-AzADUser -SignedIn -ErrorAction SilentlyContinue
$params = @{
  namePrefix = $NamePrefix; environmentName = $Environment; location = $region.Location; hosting = $Hosting
  staticWebAppLocation = $(if ($Hosting -eq 'StaticWebApp') { $region.ResourceLocation } else { 'centralus' })
  uploaderObjectId = $(if ($Hosting -eq 'Storage' -and $me) { "$($me.Id)" } else { '' })
}
$deploymentName = "avdlz-portal-$clean-$Environment"
Write-Host "  Deploying $rgName ($Hosting; a minute or two)..." -ForegroundColor DarkGray
$dep = New-AzSubscriptionDeployment -Name $deploymentName -Location $region.Location -TemplateFile $template -TemplateParameterObject $params -ErrorAction Stop
if ($dep.ProvisioningState -ne 'Succeeded') { throw "Deployment $deploymentName ended $($dep.ProvisioningState)." }
$resourceName = $dep.Outputs.resourceName.Value
$portalRoot = "$($dep.Outputs.portalUrl.Value)".TrimEnd('/') + '/'
Add-AvdCheckResult 'Portal' "$Hosting $resourceName" 'Pass' -Detail $portalRoot

# ---------------------------------------------------------------------
# 3. The files: the portal and the design system it loads, plus this copy's config
# ---------------------------------------------------------------------
Write-AvdSection 'Files'
$stage = Join-Path ([IO.Path]::GetTempPath()) "avdlz-portal-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
try {
  New-Item -ItemType Directory -Path $stage | Out-Null
  foreach ($d in 'portal', 'assets') { Copy-Item -Recurse -Path (Join-Path $repoRoot "site/$d") -Destination (Join-Path $stage $d) }
  Set-Content -Path (Join-Path $stage 'portal/portal-config.js') -Value (Get-AvdPortalConfigScript -RepoUrl $RepoUrl -Ref $Ref -PortalUrl "$($portalRoot)portal/" -Hosting $Hosting -Commit $Commit) -NoNewline
  # The site root opens the portal (on GitHub Pages it is the avd-ops redirect).
  Set-Content -Path (Join-Path $stage 'index.html') -Value '<!doctype html><meta charset="utf-8"><title>AVD deployment portal</title><meta http-equiv="refresh" content="0; url=portal/"><p><a href="portal/">AVD deployment portal</a></p>'
  if ($Hosting -eq 'StaticWebApp') {
    Set-Content -Path (Join-Path $stage 'staticwebapp.config.json') -Value (Get-AvdStaticWebAppConfig -RequireSignIn:$RequireSignIn)
    if ($RequireSignIn) {
      Set-Content -Path (Join-Path $stage 'denied.html') -Value '<!doctype html><meta charset="utf-8"><title>Not invited</title><p>You are signed in, but not invited to this deployment portal. Ask its owner for an invitation to the operator role, then <a href="/.auth/logout">sign out</a> and back in.</p>'
    }
  }
  $files = @(Get-ChildItem -Path $stage -Recurse -File)
  Add-AvdCheckResult 'Portal' 'Files staged' 'Pass' -Detail "$($files.Count) files, config for $RepoUrl at $Ref."

  # -------------------------------------------------------------------
  # 4. Upload
  # -------------------------------------------------------------------
  Write-AvdSection 'Upload'
  if ($Hosting -eq 'StaticWebApp') {
    $siteId = "$sub/resourceGroups/$rgName/providers/Microsoft.Web/staticSites/$resourceName"
    $site = Invoke-AvdArm -Path "$($siteId)?api-version=$webApi"
    if ("$($site.sku.name)" -ne 'Free') {
      Add-AvdCheckResult 'Portal' 'Static Web Apps plan' 'Warn' -Detail "The site is on the $($site.sku.name) plan, which is billed (about `$9 a month for Standard)." -Remediation 'Leave it if you chose it; this script never changes the plan.'
    }
    $token = (Invoke-AvdArm -Method POST -Path "$siteId/listSecrets?api-version=$webApi").properties.apiKey
    if (-not $token) { throw "Static Web Apps returned no deployment token for $resourceName." }
    Write-Host "  Uploading with $swaCli (npx downloads it the first time)..." -ForegroundColor DarkGray
    try {
      $env:SWA_CLI_DEPLOYMENT_TOKEN = $token
      $out = & npx --yes $swaCli deploy $stage --env production --no-use-keychain 2>&1 | Out-String
      $code = $LASTEXITCODE
    }
    finally {
      Remove-Item Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue
      $token = $null
    }
    # Kill the token this shell held, whether or not the upload worked (red team PH-2).
    Invoke-AvdArm -Method POST -Path "$siteId/resetapikey?api-version=$webApi" -Body @{ properties = @{ shouldUpdateRepository = $false } } | Out-Null
    if ($code -ne 0) {
      $tail = (($out -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 15) -join "`n"
      Add-AvdCheckResult 'Portal' 'Upload (Static Web Apps CLI)' 'Fail' -Detail "Exit code $code. Last lines:`n$tail" -Remediation 'Rerun; if npm is blocked here, publish with -Hosting Storage.'
    }
    else { Add-AvdCheckResult 'Portal' 'Upload (Static Web Apps CLI)' 'Pass' -Detail 'Deployment token reset after the upload.' }

    if ($RequireSignIn -and $me) {
      $inv = Invoke-AvdArm -Method POST -Path "$siteId/createUserInvitation?api-version=$webApi" -Body @{ properties = @{
          domain = $site.properties.defaultHostname; provider = 'aad'; userDetails = "$($me.UserPrincipalName)"; roles = 'operator'; numHoursToExpiration = 168 } }
      Add-AvdCheckResult 'Portal' "Invitation for $($me.UserPrincipalName)" 'Pass' -Detail "Open within 7 days, signed in as that account: $($inv.properties.invitationUrl)" -Remediation 'Invite other operators in the Azure portal (Static Web App > Role management, role operator), up to 25.'
    }
  }
  else {
    $account = $resourceName
    $sctx = New-AzStorageContext -StorageAccountName $account -UseConnectedAccount
    Write-Host '  Turning on the static website...' -ForegroundColor DarkGray
    Enable-AzStorageStaticWebsite -Context $sctx -IndexDocument 'index.html' -ErrorDocument404Path 'index.html' | Out-Null
    # The Blob Data Contributor role the template granted can take a few minutes to apply: retry, then stop.
    $uploaded = 0; $attempt = 0; $wait = 20; $max = 9
    foreach ($f in $files) {
      $blob = [IO.Path]::GetRelativePath($stage, $f.FullName).Replace('\', '/')
      while ($true) {
        try {
          Set-AzStorageBlobContent -Context $sctx -Container '$web' -File $f.FullName -Blob $blob -Force -Properties @{ ContentType = (Get-AvdPortalContentType -Path $blob); CacheControl = 'no-cache' } -ErrorAction Stop | Out-Null
          $uploaded++; break
        }
        catch {
          if ("$_" -notmatch '403|AuthorizationPermissionMismatch|not authorized') { throw }
          $attempt++
          if ($attempt -ge $max) { throw "Upload still forbidden after $attempt tries ($("$_")). The Storage Blob Data Contributor role on $account may not have applied yet: rerun in a few minutes." }
          Write-Host "  The upload role isn't active yet; waiting $wait seconds ($attempt of $max)..." -ForegroundColor DarkGray
          Start-Sleep -Seconds $wait
        }
      }
    }
    # Files removed from site/ since the last publish.
    $keep = @($files | ForEach-Object { [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/') })
    $stale = @(Get-AzStorageBlob -Context $sctx -Container '$web' -ErrorAction SilentlyContinue | Where-Object { $_ -and $keep -notcontains $_.Name })
    foreach ($b in $stale) { Remove-AzStorageBlob -Context $sctx -Container '$web' -Blob $b.Name -Force }
    Add-AvdCheckResult 'Portal' 'Upload ($web)' 'Pass' -Detail "$uploaded files$(if ($stale.Count) { ", $($stale.Count) old ones removed" })."
  }
}
finally {
  Remove-Item -Recurse -Force -Path $stage -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# 5. Where it is
# ---------------------------------------------------------------------
Write-AvdSummary
if (@(Get-AvdCheckResult | Where-Object Status -eq 'Fail').Count) { exit 1 }
$portal = "$($portalRoot)portal/"
Write-Host ''
Write-Host "Portal: $portal" -ForegroundColor Green
Write-Host 'To make the scripts in this Cloud Shell point to it (PowerShell, then bash):' -ForegroundColor White
Write-Host "  `$env:AVD_PORTAL_URL = '$portal'"
Write-Host "  export AVD_PORTAL_URL='$portal'"
Write-Host 'Cloud Shell sessions are ephemeral: set it again in a new one. The scripts print "Portal host: <host>, set by AVD_PORTAL_URL" so you can see it is in effect.' -ForegroundColor DarkGray
if ($Hosting -eq 'Storage') { Write-Host 'Anyone with this URL can open the portal. It holds no secrets and pasted output never leaves the browser, but treat the URL as internal.' -ForegroundColor DarkGray }
