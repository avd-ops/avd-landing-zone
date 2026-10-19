#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Builds one golden image version with Azure Image Builder (build/specs/image-pipeline-spec.md section 5.2).

.DESCRIPTION
  Run by .github/workflows/image-build.yml (or from Azure Cloud Shell at the repo root):
    0. Removes image templates older than 24 hours left by a run that died, saving their logs.
    1. Checks the resource providers, the gallery definition and the build VM's quota.
    2. Resolves the marketplace image version that 'latest' means today. When it and the commit
       match the newest published version, stops: nothing changed (-Force builds anyway).
    3. Names the version YYYY.MDD.N, compiles parameters/images-build.bicepparam and deploys
       the per-build image template (bicep/images/build.bicep).
    4. Runs it and polls until it ends (capped), then saves AIB's customization log and reads
       the build-time validation's RESULT lines from it.
    5. Checks the gallery version exists, and deletes the template.
  Writes a JSON summary to -SummaryPath for the workflow's issue. Exit code 0: built or
  unchanged; 1: failed. Nothing here changes a landing zone: a new version is excluded from
  'latest', and no host uses it until a person promotes it (spec section 6.4).

.EXAMPLE
  ./scripts/ops/Start-AvdImageBuild.ps1 -NamePrefix avdlz -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateLength(2, 8)][string] $NamePrefix = 'avdlz',
  [ValidateSet('dev', 'test', 'prod')][string] $BuildEnvironment = 'dev',
  [string] $SubscriptionId,
  # The commit the template and scripts come from (default: the checkout's HEAD).
  [string] $Commit,
  [string] $RunUrl = '',
  # Build even when the source image and the commit haven't changed (spec section 5.7).
  [switch] $Force,
  # A security build: recorded on the version (spec section 5.7).
  [switch] $Emergency,
  [string] $ParameterFile = 'parameters/images-build.bicepparam',
  [string] $SummaryPath,
  [string] $LogDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'avdlz-image-build'),
  [ValidateRange(0, 600)][int] $PollSeconds = 60
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
$ctx = Initialize-AvdAzContext -SubscriptionId $SubscriptionId
$sub = "/subscriptions/$($ctx.Subscription.Id)"
$prefix = $NamePrefix.ToLower().Replace('-', '')
$rgImages = "rg-$prefix-images"
$rgStaging = "$rgImages-staging"
$gallery = "gal$prefix"
$definition = 'win11-avd-m365'
$definitionPath = "$sub/resourceGroups/$rgImages/providers/Microsoft.Compute/galleries/$gallery/images/$definition"
$templatesPath = "$sub/resourceGroups/$rgImages/providers/Microsoft.VirtualMachineImages/imageTemplates"
$aib = 'api-version=2024-02-01'
$cg = 'api-version=2024-03-03'
if (-not $Commit) { $Commit = (& git rev-parse HEAD 2>$null) ; if (-not $Commit) { $Commit = 'unknown' } }
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
# Relative to the repo root, wherever the script is started from.
$buildParams = if ([IO.Path]::IsPathRooted($ParameterFile)) { $ParameterFile } else { Join-Path $PSScriptRoot "../../$ParameterFile" }
$summaryFile = $SummaryPath

Write-Host "Golden image build - $prefix (build network: $BuildEnvironment) in '$($ctx.Subscription.Name)'" -ForegroundColor White
Clear-AvdCheckResult
$summary = [ordered]@{ status = 'failed'; version = ''; sourceImageVersion = ''; commit = $Commit; emergency = [bool]$Emergency; runState = ''; message = ''; validation = @(); logPath = ''; removedOrphans = @() }

function Save-AvdImageBuildLog {
  <# Copies AIB's customization log from the staging storage account. Returns the path, or $null with the reason printed. #>
  param([Parameter(Mandatory)][string] $Name)
  try {
    $accounts = @((Invoke-AvdArm -Path "$sub/resourceGroups/$rgStaging/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01").value)
    foreach ($a in $accounts) {
      $storage = New-AzStorageContext -StorageAccountName $a.name -UseConnectedAccount
      $blob = @(Get-AzStorageBlob -Container 'packerlogs' -Context $storage -ErrorAction Stop | Where-Object { $_.Name -like '*customization.log' } |
          Sort-Object { $_.LastModified } -Descending) | Select-Object -First 1
      if ($blob) {
        $path = Join-Path $LogDirectory "$Name-customization.log"
        Get-AzStorageBlobContent -Container 'packerlogs' -Blob $blob.Name -Destination $path -Context $storage -Force | Out-Null
        return $path
      }
    }
    Write-Host "  No customization log found in $rgStaging." -ForegroundColor Yellow
  }
  catch { Write-Host "  Couldn't read the customization log: $($_.Exception.Message)" -ForegroundColor Yellow }
  return $null
}

function Complete-AvdImageBuild {
  param([int] $Code, [string] $Path = $summaryFile)
  $result = Write-AvdSummary
  if ($Path) { $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding utf8 }
  Write-Host "Image build: $($summary.status) $($summary.version)" -ForegroundColor $(if ($Code) { 'Red' } else { 'Green' })
  if ($result.Failed -and -not $Code) { $Code = 1 }
  exit $Code
}

# ---------------------------------------------------------------------
# 0. Templates left behind by a run that died (red-team M7)
# ---------------------------------------------------------------------
Write-AvdSection 'Leftover templates'
$cutoff = (Get-Date).ToUniversalTime().AddHours(-24)
$existingTemplates = @((Invoke-AvdArm -Path "$templatesPath`?$aib").value)
foreach ($t in $existingTemplates | Where-Object { $_.name -like "it-$prefix-*" }) {
  $created = [datetime]::MinValue
  if ($t.tags -and $t.tags.'avdlz-created') { $created = ([datetime]$t.tags.'avdlz-created').ToUniversalTime() }
  if ($created -gt $cutoff) { continue }
  if ($PSCmdlet.ShouldProcess($t.name, 'Delete leftover image template')) {
    $log = Save-AvdImageBuildLog -Name $t.name
    Invoke-AvdArm -Method DELETE -Path "$templatesPath/$($t.name)?$aib" | Out-Null
    $summary.removedOrphans += $t.name
    Add-AvdCheckResult 'Image build' "Removed leftover template $($t.name)" 'Fixed' -Detail "created $($t.tags.'avdlz-created'); log: $(if ($log) { $log } else { 'not available' })"
  }
}
if (-not $summary.removedOrphans.Count) { Add-AvdCheckResult 'Image build' 'No leftover templates' 'Pass' }

# ---------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------
Write-AvdSection 'Prerequisites'
$providers = 'Microsoft.VirtualMachineImages', 'Microsoft.Compute', 'Microsoft.KeyVault', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.ContainerInstance'
$states = Get-AvdProviderState -Namespace $providers
$unregistered = @($providers | Where-Object { $states[$_] -ne 'Registered' })
if ($unregistered.Count) {
  Add-AvdCheckResult 'Image build' 'Resource providers registered' 'Fail' -Detail "Not registered: $($unregistered -join ', ')" -Remediation "As an owner: $(($unregistered | ForEach-Object { "Register-AzResourceProvider -ProviderNamespace $_" }) -join '; ')"
  Complete-AvdImageBuild 1
}
Add-AvdCheckResult 'Image build' 'Resource providers registered' 'Pass' -Detail ($providers -join ', ')

$def = Invoke-AvdArm -Path "$definitionPath`?$cg" -AllowNotFound
if (-not $def) {
  Add-AvdCheckResult 'Image build' "Image definition $gallery/$definition" 'Fail' -Remediation 'Deploy bicep/images/main.bicep first (docs/images.md).'
  Complete-AvdImageBuild 1
}
$location = $def.location
Add-AvdCheckResult 'Image build' "Image definition $gallery/$definition" 'Pass' -Detail "in $location"

# Compile once to read the build settings (VM size, source image) from the parameter file.
$bicep = Get-Command bicep -ErrorAction SilentlyContinue
if (-not $bicep) { Add-AvdCheckResult 'Image build' 'Bicep CLI available' 'Fail' -Remediation 'Install the Bicep CLI (az bicep install, or the standalone binary).'; Complete-AvdImageBuild 1 }
function Get-AvdBuildDeployment {
  param([string] $Path = $buildParams)
  $raw = & $bicep.Source build-params $Path --stdout 2>&1
  if ($LASTEXITCODE -ne 0) { throw "bicep build-params $Path failed: $raw" }
  $compiled = ($raw -join "`n") | ConvertFrom-Json -Depth 100
  [pscustomobject]@{ Template = ($compiled.templateJson | ConvertFrom-Json -Depth 100); Parameters = ($compiled.parametersJson | ConvertFrom-Json -Depth 100).parameters }
}
$probe = Get-AvdBuildDeployment
$vmSize = $probe.Parameters.buildVmSize.value
if (-not $vmSize) { $vmSize = $probe.Template.parameters.buildVmSize.defaultValue }
$source = $probe.Template.parameters.sourceImage.defaultValue
if ($probe.Parameters.sourceImage) { $source = $probe.Parameters.sourceImage.value }

# The build VM's family needs room for one VM (red-team M3; lessons 0013, 0024).
Test-AvdVmCapacity -Location $location -VmSize $vmSize -Count 1 | Out-Null
# Assign before filtering: Get-AvdCheckResult emits one array (lesson 0009).
$checks = Get-AvdCheckResult
if (@($checks | Where-Object Status -eq 'Fail').Count) { Complete-AvdImageBuild 1 }

# ---------------------------------------------------------------------
# 2. What would this build change?
# ---------------------------------------------------------------------
Write-AvdSection 'Source image and version'
$sourceVersions = @(Invoke-AvdArm -Path "$sub/providers/Microsoft.Compute/locations/$location/publishers/$($source.publisher)/artifacttypes/vmimage/offers/$($source.offer)/skus/$($source.sku)/versions?api-version=2024-07-01")
$sourceVersion = Get-AvdLatestVersion -Version @($sourceVersions | ForEach-Object { $_.name })
if (-not $sourceVersion) {
  Add-AvdCheckResult 'Image build' 'Source image version' 'Fail' -Detail "$($source.publisher)/$($source.offer)/$($source.sku) returned no versions in $location."
  Complete-AvdImageBuild 1
}
$summary.sourceImageVersion = $sourceVersion
$versions = @((Invoke-AvdArm -Path "$definitionPath/versions?$cg").value)
# A version marked failed doesn't count as built: the same inputs may be retried.
$usable = @($versions | Where-Object { -not ($_.tags -and "$($_.tags.'avdlz-validation')" -like 'failed*') })
$newest = $usable | Where-Object { $_.name -eq (Get-AvdLatestVersion -Version @($usable | ForEach-Object { $_.name })) } | Select-Object -First 1
$newestSource = if ($newest -and $newest.tags) { "$($newest.tags.'avdlz-source-image')" } else { '' }
$newestCommit = if ($newest -and $newest.tags) { "$($newest.tags.'avdlz-commit')" } else { '' }
if ($newest -and $newestSource.EndsWith("/$sourceVersion") -and $newestCommit -eq $Commit -and -not $Force) {
  $summary.status = 'unchanged'; $summary.version = $newest.name
  Add-AvdCheckResult 'Image build' 'Something to build' 'Skip' -Detail "Version $($newest.name) already has source $sourceVersion and commit $Commit. Use -Force (the workflow's force input) to build anyway, for example after an out-of-band update."
  Complete-AvdImageBuild 0
}
$version = Get-AvdImageVersionName -Date (Get-Date).ToUniversalTime() -Existing @($versions | ForEach-Object { $_.name })
$summary.version = $version
Add-AvdCheckResult 'Image build' "New version $version" 'Pass' -Detail "source $($source.sku) $sourceVersion, commit $Commit$(if ($newest) { "; newest published: $($newest.name)" })"

# ---------------------------------------------------------------------
# 3. Deploy the per-build template
# ---------------------------------------------------------------------
Write-AvdSection 'Build'
$env:AVD_IMAGE_VERSION = $version
$env:AVD_IMAGE_SOURCE_VERSION = $sourceVersion
$env:AVD_IMAGE_COMMIT = $Commit
$env:AVD_IMAGE_RUN_URL = $RunUrl
$env:AVD_IMAGE_EMERGENCY = if ($Emergency) { 'true' } else { 'false' }
$deployment = Get-AvdBuildDeployment
$templateName = "it-$prefix-$($version.Replace('.', '-'))"
if (-not $PSCmdlet.ShouldProcess($templateName, 'Deploy and run the image template')) { $summary.status = 'whatif'; Complete-AvdImageBuild 0 }

$deployPath = "$sub/resourceGroups/$rgImages/providers/Microsoft.Resources/deployments/$templateName`?api-version=2024-03-01"
Write-Host "  Deploying $templateName ..." -ForegroundColor DarkGray
Invoke-AvdArm -Method PUT -Path $deployPath -Body @{ properties = @{ mode = 'Incremental'; template = $deployment.Template; parameters = $deployment.Parameters } } | Out-Null
$state = ''
for ($i = 0; $i -lt 60; $i++) {
  $d = Invoke-AvdArm -Path $deployPath
  $state = $d.properties.provisioningState
  if ($state -in 'Succeeded', 'Failed', 'Canceled') { break }
  Start-Sleep -Seconds ([math]::Min($PollSeconds, 15))
}
if ($state -ne 'Succeeded') {
  $err = if ($d.properties.error) { $d.properties.error | ConvertTo-Json -Depth 10 -Compress } else { '' }
  $summary.message = "Template deployment ended $state $err"
  Add-AvdCheckResult 'Image build' "Deploy $templateName" 'Fail' -Detail $summary.message
  # A failed deployment can still leave the template behind.
  Invoke-AvdArm -Method DELETE -Path "$templatesPath/$templateName`?$aib" -AllowNotFound | Out-Null
  Complete-AvdImageBuild 1
}
Add-AvdCheckResult 'Image build' "Deploy $templateName" 'Pass'

# ---------------------------------------------------------------------
# 4. Run and wait (capped: the template's timeout plus an hour)
# ---------------------------------------------------------------------
$timeout = [int]$deployment.Parameters.buildTimeoutInMinutes.value
if (-not $timeout) { $timeout = 360 }
$maxPolls = [math]::Ceiling(($timeout + 60) * 60 / [math]::Max($PollSeconds, 1))
Write-Host "  Running ${templateName}: Windows Update, WDOT and validation take 1-4 hours. Polling every $PollSeconds s (up to $($timeout + 60) min)." -ForegroundColor DarkGray
Invoke-AvdArm -Method POST -Path "$templatesPath/$templateName/run?$aib" | Out-Null
$run = $null
for ($i = 0; $i -lt $maxPolls; $i++) {
  $tpl = Invoke-AvdArm -Path "$templatesPath/$templateName`?$aib"
  # ARM leaves lastRunStatus out until the run has a state (lesson 0021).
  $run = $tpl.properties.lastRunStatus
  if ($run -and $run.runState -in 'Succeeded', 'PartiallySucceeded', 'Failed', 'Canceled') { break }
  if ($i % 10 -eq 0 -and $run) { Write-Host "  $(Get-Date -Format HH:mm) $($run.runState) $($run.runSubState)" -ForegroundColor DarkGray }
  Start-Sleep -Seconds $PollSeconds
}
$summary.runState = if ($run) { $run.runState } else { 'Unknown' }
$summary.message = if ($run -and $run.message) { $run.message } else { '' }

$log = Save-AvdImageBuildLog -Name $templateName
if ($log) {
  $summary.logPath = $log
  $summary.validation = @(Select-String -Path $log -Pattern 'RESULT (\S+) (Pass|Fail) ?(.*)$' | ForEach-Object {
      [ordered]@{ check = $_.Matches[0].Groups[1].Value; status = $_.Matches[0].Groups[2].Value; detail = $_.Matches[0].Groups[3].Value.Trim() } })
  $tail = (Get-Content -Path $log -Tail 40) -join "`n"
}
foreach ($v in $summary.validation) {
  Add-AvdCheckResult 'Validation' $v.check $(if ($v.status -eq 'Pass') { 'Pass' } else { 'Fail' }) -Detail $v.detail
}

$failedChecks = @($summary.validation | Where-Object { $_.status -eq 'Fail' })
if ($summary.runState -eq 'Succeeded' -and $failedChecks.Count) {
  # AIB should have stopped distribution; inconsistent evidence fails safe.
  $summary.runState = 'Inconsistent'
  $summary.message = "AIB reported success, but $($failedChecks.Count) validation check(s) failed in the log."
  # The version was published anyway: mark it so validation and promotion never use it.
  $published = Invoke-AvdArm -Path "$definitionPath/versions/$version`?$cg" -AllowNotFound
  if ($published) {
    $tags = @{}; if ($published.tags) { foreach ($t in $published.tags.PSObject.Properties) { $tags[$t.Name] = $t.Value } }
    $tags['avdlz-validation'] = 'failed:build'
    Invoke-AvdArm -Method PATCH -Path "$definitionPath/versions/$version`?$cg" -Body @{ tags = $tags } | Out-Null
    Add-AvdCheckResult 'Image build' "Gallery version $version marked failed" 'Fixed' -Detail 'avdlz-validation=failed:build: never validated or promoted.'
  }
}
if ($summary.runState -ne 'Succeeded') {
  $detail = "runState=$($summary.runState) subState=$(if ($run) { $run.runSubState }) message=$($summary.message)"
  Add-AvdCheckResult 'Image build' "Run $templateName" 'Fail' -Detail $detail -Remediation $(if ($log) { "Customization log: $log. Last lines:`n$tail" } else { 'The customization log could not be read; see the run status message.' })
}
else {
  Add-AvdCheckResult 'Image build' "Run $templateName" 'Pass' -Detail "built and generalized; $(@($summary.validation).Count) validation check(s) read from the log"
  # ---------------------------------------------------------------------
  # 5. The version exists
  # ---------------------------------------------------------------------
  $published = Invoke-AvdArm -Path "$definitionPath/versions/$version`?$cg" -AllowNotFound
  if ($published -and $published.properties.provisioningState -eq 'Succeeded') {
    $summary.status = 'succeeded'
    Add-AvdCheckResult 'Image build' "Gallery version $version" 'Pass' -Detail "excluded from latest until validated (spec section 6.3); replicated to $(@($published.properties.publishingProfile.targetRegions | ForEach-Object { $_.name }) -join ', ')"
  }
  else { Add-AvdCheckResult 'Image build' "Gallery version $version" 'Fail' -Detail "provisioningState=$(if ($published) { $published.properties.provisioningState } else { 'missing' })" }
}

# The template only exists for this build; deleting it also removes the staging resources.
Write-Host "  Deleting $templateName ..." -ForegroundColor DarkGray
Invoke-AvdArm -Method DELETE -Path "$templatesPath/$templateName`?$aib" | Out-Null
$gone = $false
for ($i = 0; $i -lt 40; $i++) {
  if (-not (Invoke-AvdArm -Path "$templatesPath/$templateName`?$aib" -AllowNotFound)) { $gone = $true; break }
  Start-Sleep -Seconds ([math]::Min($PollSeconds, 30))
}
if ($gone) { Add-AvdCheckResult 'Image build' "Template $templateName removed" 'Pass' }
else { Add-AvdCheckResult 'Image build' "Template $templateName removed" 'Warn' -Detail 'Still present; the next build removes it after 24 hours.' }

Complete-AvdImageBuild $(if ($summary.status -eq 'succeeded') { 0 } else { 1 })
