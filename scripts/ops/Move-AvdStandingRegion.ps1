#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Moves the standing subscription resources (run store, golden image gallery/identities, and source
  Network Watcher) from one Azure region to another without losing run records.

.DESCRIPTION
  Run from Azure Cloud Shell (PowerShell) or a workstation signed in with Azure CLI (az). Azure does
  not support in-place cross-region move for Storage Accounts with subscription Activity Log
  diagnostic settings, Automation Accounts, Azure Compute Galleries, or User-Assigned Managed
  Identities. Moving these standing stacks between regions is therefore a
  stage -> verify -> remove -> redeploy -> restore workflow:

    1. Preflight checks: refuses when SourceLocation equals TargetLocation, when any landing zone
       resource group (rg-<prefix>-<env>-*) is deployed, when any deadline teardown schedule in
       aa-avdlz-runs is armed in the future, or when Compute Gallery gal<prefix> holds published
       image versions (unless -DiscardImageVersions is passed).
    2. Stage and verify (never delete the last copy, spec R9): downloads every blob from every
       container in the run store (records, runs, insights-activity-logs) into BundlePath, computes
       SHA-256 and byte length, verifies every local file against the manifest, and records extra
       RBAC role assignments on avdlz-runs-rg.
    3. Remove source stacks: deletes the subscription Activity Log diagnostic setting
       avdlz-runs-activity, deletes avdlz-runs-rg, waits for Azure Storage to release the deterministic
       account name (avdlzruns<hash>), deletes rg-<prefix>-images and rg-<prefix>-images-staging,
       cleans up orphaned subscription-scope role assignments from the deleted managed identities,
       and removes NetworkWatcher_<SourceLocation> unless -KeepNetworkWatcher is set.
    4. Redeploy in TargetLocation: deploys the run store in TargetLocation and deploys the golden
       image gallery, image definition, and managed identities in TargetLocation.
    5. Restore and verify: uploads every staged blob into the recreated run store, reads back and
       verifies SHA-256 hashes against the manifest, and restores extra RBAC role assignments on
       avdlz-runs-rg.

  Supports -WhatIf (runs all read-only checks and inventories what would move) and -Resume (resumes
  from step 4 using an existing verified bundle in BundlePath if the session dropped after step 3).

.EXAMPLE
  ./scripts/ops/Move-AvdStandingRegion.ps1 -SourceLocation northcentralus -TargetLocation centralus -PrivateRepo contoso/avd-run-records -WhatIf

.EXAMPLE
  ./scripts/ops/Move-AvdStandingRegion.ps1 -SourceLocation northcentralus -TargetLocation centralus -PrivateRepo contoso/avd-run-records
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string] $SourceLocation,
  [Parameter(Mandatory)][string] $TargetLocation,
  [ValidateLength(2, 8)][string] $NamePrefix = 'avdlz',
  [ValidateSet('dev', 'test', 'prod')][string] $BuildEnvironment = 'dev',
  [ValidateSet('Keep', 'Ask', 'Delete')][string] $TeardownLogs = 'Keep',
  [string] $PrivateRepo = $env:AVD_PRIVATE_REPO,
  [string] $GithubRepository = $env:AVD_GITHUB_REPOSITORY,
  [string] $BundlePath,
  [switch] $Resume,
  [switch] $DiscardImageVersions,
  [switch] $KeepNetworkWatcher,
  [switch] $AcceptDefenderCharge,
  [switch] $NoActivityLogExport,
  [switch] $NoDeadlineTeardown,
  [string] $DeadlineRunbookUri = $env:AVD_DEADLINE_RUNBOOK_URI,
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AvdLandingZone.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AvdRunRecorder.psm1') -Force

$script:UseAzModule = [bool]((Get-Module -Name 'AzMock' -ErrorAction SilentlyContinue) -or (
    (Get-Module -ListAvailable -Name 'Az.Accounts') -and
    (Get-Module -ListAvailable -Name 'Az.Resources') -and
    (Get-Module -ListAvailable -Name 'Az.Compute') -and
    (Get-Module -ListAvailable -Name 'Az.Storage')
  ))

function Initialize-StandingContext {
  param([string] $SubId)
  if ($script:UseAzModule) {
    return Initialize-AvdAzContext -SubscriptionId $SubId
  }
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Either Azure PowerShell (Az.*) or Azure CLI (az) is required.'
  }
  if ($SubId) {
    $null = az account set --subscription $SubId 2>$null
  }
  $acctJson = az account show -o json 2>$null
  if ($LASTEXITCODE -or -not $acctJson) {
    throw 'Not signed in to Azure. Run Connect-AzAccount or az login.'
  }
  $acct = $acctJson | ConvertFrom-Json
  [pscustomobject]@{
    Subscription = [pscustomobject]@{
      Id   = [string]$acct.id
      Name = [string]$acct.name
    }
  }
}

function Invoke-StandingArm {
  param(
    [Parameter(Mandatory)][string] $Path,
    [ValidateSet('GET', 'PUT', 'PATCH', 'DELETE', 'POST')][string] $Method = 'GET',
    [object] $Body,
    [switch] $AllowNotFound
  )
  if ($script:UseAzModule) {
    return Invoke-AvdArm -Path $Path -Method $Method -Body $Body -AllowNotFound:$AllowNotFound
  }
  $url = if ($Path -match '^https://') { $Path } else { "https://management.azure.com$Path" }
  $tmpBody = $null
  try {
    $azArgs = @('rest', '--method', $Method.ToLowerInvariant(), '--url', $url, '-o', 'json')
    if ($null -ne $Body) {
      $tmpBody = Join-Path ([IO.Path]::GetTempPath()) "avdlz-arm-$([guid]::NewGuid().ToString('N')).json"
      $Body | ConvertTo-Json -Depth 30 -Compress | Set-Content -LiteralPath $tmpBody -Encoding utf8NoBOM
      $azArgs += @('--body', "@$tmpBody", '--headers', 'Content-Type=application/json')
    }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $out = & az @azArgs 2>&1
      $exitCode = $LASTEXITCODE
    }
    finally {
      $ErrorActionPreference = $oldEap
    }
    if ($exitCode) {
      $msg = ($out | Out-String).Trim()
      if ($AllowNotFound -and $msg -match '404|NotFound|ResourceGroupNotFound|ResourceNotFound') {
        $global:LASTEXITCODE = 0
        return $null
      }
      throw "ARM $Method $Path failed: $msg"
    }
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $text = ($stdout | Out-String).Trim()
    if ($text) { return ($text | ConvertFrom-Json -Depth 30) }
    return $null
  }
  finally {
    if ($tmpBody -and (Test-Path -LiteralPath $tmpBody)) {
      Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-StandingArmList {
  param([Parameter(Mandatory)][string] $Path)
  $items = @(); $next = $Path; $page = 0
  while ($next -and $page -lt 50) {
    $page++
    $r = Invoke-StandingArm -Path $next -AllowNotFound
    if (-not $r) { break }
    $items += @($r.value | Where-Object { $_ })
    $next = if ($r.PSObject.Properties['nextLink']) { $r.nextLink } else { $null }
  }
  $items
}

function Get-StandingSignedInUserId {
  if ($script:UseAzModule) {
    return [string](Get-AzADUser -SignedIn -ErrorAction Stop).Id
  }
  $id = (az ad signed-in-user show --query id -o tsv 2>$null)
  if ($LASTEXITCODE -or -not $id) { throw 'Could not read signed-in Entra user ID (az ad signed-in-user show).' }
  "$id".Trim()
}

function Get-StandingBlobInventory {
  param([Parameter(Mandatory)][string] $AccountName)
  if ($script:UseAzModule) {
    $sc = New-AzStorageContext -StorageAccountName $AccountName -UseConnectedAccount -ErrorAction Stop
    $containers = @(Get-AzStorageContainer -Context $sc -ErrorAction Stop | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
    $blobs = @()
    foreach ($c in $containers) {
      foreach ($b in @(Get-AzStorageBlob -Container $c -Context $sc -ErrorAction Stop | Where-Object { $_ })) {
        $blobs += [pscustomobject]@{ container = $c; name = [string]$b.Name; bytes = [long]$b.Length }
      }
    }
    return [pscustomobject]@{ Containers = $containers; Blobs = $blobs; Context = $sc }
  }
  $cJson = az storage container list --account-name $AccountName --auth-mode login --query "[].name" -o json 2>&1
  if ($LASTEXITCODE) { throw "Listing containers in $AccountName failed: $cJson" }
  $containers = @(($cJson | Out-String | ConvertFrom-Json) | Where-Object { $_ } | ForEach-Object { [string]$_ })
  $blobs = @()
  foreach ($c in $containers) {
    $bJson = az storage blob list --account-name $AccountName --container-name $c --auth-mode login --query "[].{name:name, bytes:properties.contentLength}" -o json 2>&1
    if ($LASTEXITCODE) { throw "Listing blobs in $AccountName/$c failed: $bJson" }
    foreach ($b in @(($bJson | Out-String | ConvertFrom-Json) | Where-Object { $_ })) {
      $blobs += [pscustomobject]@{ container = $c; name = [string]$b.name; bytes = [long]$b.bytes }
    }
  }
  [pscustomobject]@{ Containers = $containers; Blobs = $blobs; Context = $null }
}

function Save-StandingBlobToFile {
  param([Parameter(Mandatory)][string] $AccountName, $Context, [Parameter(Mandatory)][string] $Container, [Parameter(Mandatory)][string] $Blob, [Parameter(Mandatory)][string] $Destination)
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force
  if ($script:UseAzModule) {
    $client = (Get-AzStorageContainer -Name $Container -Context $Context -ErrorAction Stop).BlobContainerClient.GetBlobClient($Blob)
    $null = $client.DownloadTo($Destination)
    return
  }
  $out = az storage blob download --account-name $AccountName --container-name $Container --name $Blob --file $Destination --auth-mode login --no-progress -o none 2>&1
  if ($LASTEXITCODE) { throw "Downloading $Container/$Blob failed: $out" }
}

function Send-StandingBlobFromFile {
  param([Parameter(Mandatory)][string] $AccountName, $Context, [Parameter(Mandatory)][string] $Container, [Parameter(Mandatory)][string] $Blob, [Parameter(Mandatory)][string] $SourcePath)
  if ($script:UseAzModule) {
    $null = Set-AzStorageBlobContent -File $SourcePath -Container $Container -Blob $Blob -Context $Context -Force -ErrorAction Stop
    return
  }
  $out = az storage blob upload --account-name $AccountName --container-name $Container --name $Blob --file $SourcePath --auth-mode login --overwrite true --no-progress -o none 2>&1
  if ($LASTEXITCODE) { throw "Uploading $Container/$Blob failed: $out" }
}

function Invoke-StandingContainerEnsure {
  param([Parameter(Mandatory)][string] $AccountName, $Context, [Parameter(Mandatory)][string] $Container)
  if ($script:UseAzModule) {
    if (-not (Get-AzStorageContainer -Name $Container -Context $Context -ErrorAction SilentlyContinue)) {
      $null = New-AzStorageContainer -Name $Container -Context $Context -ErrorAction Stop
    }
    return
  }
  $out = az storage container create --account-name $AccountName --name $Container --auth-mode login -o none 2>&1
  if ($LASTEXITCODE) { throw "Creating container $Container in $AccountName failed: $out" }
}

function Invoke-StandingResourceGroupDelete {
  param([Parameter(Mandatory)][string] $Name)
  if ($script:UseAzModule) {
    $null = Remove-AzResourceGroup -Name $Name -Force -ErrorAction Stop
    return
  }
  $out = az group delete --name $Name --yes 2>&1
  if ($LASTEXITCODE) { throw "Deleting resource group $Name failed: $out" }
}

function Get-LocalBundleObserved {
  param([Parameter(Mandatory)][string] $BlobsRoot, [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Manifest)
  $observed = @{}
  foreach ($m in @($Manifest | Where-Object { $_ })) {
    $key = "$($m.container)/$($m.name)"
    $localFile = Join-Path $BlobsRoot ($key -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $localFile) {
      $item = Get-Item -LiteralPath $localFile
      $sha = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash.ToLowerInvariant()
      $observed[$key] = @{ bytes = [long]$item.Length; sha256 = $sha }
    }
  }
  $observed
}

$ctx = Initialize-StandingContext -SubId $SubscriptionId
Clear-AvdCheckResult
$subId = $ctx.Subscription.Id
$storeName = Get-AvdRunStoreName -SubscriptionId $subId
$cleanPrefix = ($NamePrefix -replace '-', '').ToLowerInvariant()

if (-not $BundlePath) {
  $homeDir = if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
  $cloudDrive = Join-Path $homeDir 'clouddrive'
  $baseDir = if (Test-Path -LiteralPath $cloudDrive) { $cloudDrive } else { [IO.Path]::GetTempPath() }
  $BundlePath = Join-Path $baseDir "avdlz-region-move-$cleanPrefix"
}

Write-Host "Standing region move ($SourceLocation -> $TargetLocation) - '$($ctx.Subscription.Name)'" -ForegroundColor White
Write-AvdSection 'Preflight checks'

Write-Host '  Reading subscription resource groups...' -ForegroundColor DarkGray
$rgs = @(Get-StandingArmList -Path "/subscriptions/$subId/resourceGroups?api-version=2024-03-01")
$standingRgNames = @('avdlz-runs-rg', "rg-$cleanPrefix-images", "rg-$cleanPrefix-images-staging", 'NetworkWatcherRG')
$activeLzGroups = @($rgs | Where-Object { $_.name -like "rg-$cleanPrefix-*" -and $_.name -notin $standingRgNames } | ForEach-Object { [string]$_.name })

$armedSchedules = @()
$oldAutomationPrincipalId = $null
$runsRg = $rgs | Where-Object { $_.name -eq 'avdlz-runs-rg' } | Select-Object -First 1
if ($runsRg) {
  $aa = Invoke-StandingArm -Path "/subscriptions/$subId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Automation/automationAccounts/aa-avdlz-runs?api-version=2023-11-01" -AllowNotFound
  if ($aa -and $aa.identity -and $aa.identity.principalId) {
    $oldAutomationPrincipalId = [string]$aa.identity.principalId
  }
  $scheds = @(Get-StandingArmList -Path "/subscriptions/$subId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Automation/automationAccounts/aa-avdlz-runs/schedules?api-version=2023-11-01")
  $nowUtc = [datetime]::UtcNow
  foreach ($s in $scheds) {
    if ($s.properties.isEnabled -and $s.properties.expiryTime -and ([datetime]$s.properties.expiryTime).ToUniversalTime() -gt $nowUtc) {
      $armedSchedules += [string]$s.name
    }
  }
  $sa = Invoke-StandingArm -Path "/subscriptions/$subId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Storage/storageAccounts/$storeName`?api-version=2023-05-01" -AllowNotFound
  if ($sa -and $sa.tags) {
    if (-not $PrivateRepo -and $sa.tags.PSObject.Properties['avdlz-private-repo'] -and $sa.tags.'avdlz-private-repo') {
      $PrivateRepo = [string]$sa.tags.'avdlz-private-repo'
    }
    if (-not $PSBoundParameters.ContainsKey('TeardownLogs') -and $sa.tags.PSObject.Properties['avdlz-teardown-logs'] -and $sa.tags.'avdlz-teardown-logs' -in @('Keep', 'Ask', 'Delete')) {
      $TeardownLogs = [string]$sa.tags.'avdlz-teardown-logs'
    }
  }
}

$imageVersions = @()
$oldImagePrincipalIds = @()
$imagesRg = $rgs | Where-Object { $_.name -eq "rg-$cleanPrefix-images" } | Select-Object -First 1
if ($imagesRg) {
  $vers = @(Get-StandingArmList -Path "/subscriptions/$subId/resourceGroups/rg-$cleanPrefix-images/providers/Microsoft.Compute/galleries/gal$cleanPrefix/images/win11-avd-m365/versions?api-version=2024-03-03")
  $imageVersions = @($vers | ForEach-Object { [string]$_.name })
  foreach ($idName in @("id-$cleanPrefix-aib", "id-$cleanPrefix-image-build")) {
    $uami = Invoke-StandingArm -Path "/subscriptions/$subId/resourceGroups/rg-$cleanPrefix-images/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$idName`?api-version=2023-01-31" -AllowNotFound
    if ($uami -and $uami.properties -and $uami.properties.principalId) {
      $oldImagePrincipalIds += [string]$uami.properties.principalId
    }
  }
  if (-not $GithubRepository) {
    $fed = Invoke-StandingArm -Path "/subscriptions/$subId/resourceGroups/rg-$cleanPrefix-images/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$cleanPrefix-image-build/federatedIdentityCredentials/github-images-environment?api-version=2023-01-31" -AllowNotFound
    if ($fed -and $fed.properties -and "$($fed.properties.subject)" -match '^repo:([^:]+/[^:]+):environment:images$') {
      $GithubRepository = $Matches[1]
    }
  }
}

$watchers = @(Get-StandingArmList -Path "/subscriptions/$subId/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers?api-version=2024-05-01")

$plan = Get-AvdStandingRegionMovePlan `
  -SourceLocation $SourceLocation `
  -TargetLocation $TargetLocation `
  -NamePrefix $NamePrefix `
  -ResourceGroup $rgs `
  -ActiveLandingZoneGroup $activeLzGroups `
  -ArmedSchedule $armedSchedules `
  -ImageVersion $imageVersions `
  -NetworkWatcher $watchers `
  -DiscardImageVersions:$DiscardImageVersions `
  -KeepNetworkWatcher:$KeepNetworkWatcher `
  -Resume:$Resume

if (-not $plan.Allowed) {
  foreach ($b in $plan.Blockers) {
    Add-AvdCheckResult 'Preflight' 'Standing region move allowed' 'Fail' -Id 'region-move-blocked' -Detail $b
  }
  $null = Write-AvdSummary
  exit 1
}

Add-AvdCheckResult 'Preflight' 'No active landing zone resource groups or armed schedules' 'Pass' -Id 'region-move-idle'
Add-AvdCheckResult 'Preflight' "Run store (avdlz-runs-rg / $storeName)" $(if ($plan.MoveRunStore -or $plan.DeployRunStore) { 'Pass' } else { 'Skip' }) -Id 'region-move-runstore' `
  -Detail $(if ($plan.MoveRunStore) { "In $($plan.SourceLocation) -> will stage blobs, remove, redeploy in $($plan.TargetLocation), and restore." } elseif ($plan.DeployRunStore) { "Resume mode -> will deploy and restore in $($plan.TargetLocation)." } else { "Not in $($plan.SourceLocation)." })
Add-AvdCheckResult 'Preflight' "Golden image pipeline (rg-$cleanPrefix-images, rg-$cleanPrefix-images-staging)" $(if ($plan.MoveImages -or $plan.DeployImages) { 'Pass' } else { 'Skip' }) -Id 'region-move-images' `
  -Detail $(if ($plan.MoveImages) { "In $($plan.SourceLocation) ($($imageVersions.Count) version(s)) -> will remove and redeploy in $($plan.TargetLocation)." } elseif ($plan.DeployImages) { "Resume mode -> will deploy in $($plan.TargetLocation)." } else { "Not in $($plan.SourceLocation)." })
Add-AvdCheckResult 'Preflight' "Source Network Watcher ($($plan.SourceLocation))" $(if ($plan.RemoveNetworkWatchers.Count) { 'Pass' } else { 'Skip' }) -Id 'region-move-watcher' `
  -Detail $(if ($plan.RemoveNetworkWatchers.Count) { "Will remove $($plan.RemoveNetworkWatchers -join ', ')." } else { 'None to remove.' })

$manifestPath = Join-Path $BundlePath 'manifest.json'
$rbacPath = Join-Path $BundlePath 'rbac.json'
$blobsRoot = Join-Path $BundlePath 'blobs'

# =====================================================================
# Step 2: Stage and verify run store blobs + extra RBAC
# =====================================================================
if ($plan.MoveRunStore -and -not $Resume) {
  Write-AvdSection 'Stage run store blobs and RBAC'
  Write-Host "  Listing containers and blobs in $storeName..." -ForegroundColor DarkGray
  $inv = Get-StandingBlobInventory -AccountName $storeName
  $containers = @($inv.Containers)
  $sourceBlobs = @($inv.Blobs)

  $meId = Get-StandingSignedInUserId
  $rgScope = "/subscriptions/$subId/resourceGroups/avdlz-runs-rg"
  $roleAssignments = @(Get-StandingArmList -Path "$rgScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
  $extraRbac = @($roleAssignments | Where-Object {
      $_.properties.scope -like "$rgScope*" -and
      $_.properties.principalId -ne $meId -and
      (-not $oldAutomationPrincipalId -or $_.properties.principalId -ne $oldAutomationPrincipalId)
    } | ForEach-Object {
      [ordered]@{
        principalId      = [string]$_.properties.principalId
        principalType    = [string]$_.properties.principalType
        roleDefinitionId = [string]$_.properties.roleDefinitionId
        relativeScope    = [string]($_.properties.scope.Substring($rgScope.Length))
      }
    })

  if ($PSCmdlet.ShouldProcess("$storeName ($($sourceBlobs.Count) blob(s) across $($containers.Count) container(s))", "Stage blobs and $($extraRbac.Count) extra RBAC assignment(s) to $BundlePath")) {
    $null = New-Item -ItemType Directory -Path $blobsRoot -Force
    $manifest = @()
    foreach ($b in $sourceBlobs) {
      $dest = Join-Path $blobsRoot (Join-Path $b.container ($b.name -replace '/', [IO.Path]::DirectorySeparatorChar))
      Save-StandingBlobToFile -AccountName $storeName -Context $inv.Context -Container $b.container -Blob $b.name -Destination $dest
      $sha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
      $manifest += [ordered]@{
        container = $b.container
        name      = $b.name
        bytes     = $b.bytes
        sha256    = $sha
      }
    }
    $observed = Get-LocalBundleObserved -BlobsRoot $blobsRoot -Manifest $manifest
    $bundleCheck = Test-AvdStandingBlobBundle -Manifest $manifest -Observed $observed
    if (-not $bundleCheck.Verified) {
      Add-AvdCheckResult 'Stage' 'Verified local copy of every run store blob' 'Fail' -Id 'region-move-stage-verify' `
        -Detail "$($bundleCheck.Failed.Count) blob(s) failed verification: $(($bundleCheck.Failed | ForEach-Object { "$($_.Key) ($($_.Reason))" }) -join ', ')." `
        -Remediation 'Nothing was deleted in Azure. Check local disk space and run again.'
      $null = Write-AvdSummary
      exit 1
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
    $extraRbac | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rbacPath -Encoding utf8NoBOM
    Add-AvdCheckResult 'Stage' "Staged and verified $($bundleCheck.Count) blob(s) and $($extraRbac.Count) RBAC assignment(s) in $BundlePath" 'Fixed' -Id 'region-move-stage'
  }
  else {
    Add-AvdCheckResult 'Stage' "Would stage $($sourceBlobs.Count) blob(s) across $($containers.Count) container(s) ($($containers -join ', ')) and $($extraRbac.Count) extra RBAC assignment(s) to $BundlePath" 'Skip' -Id 'region-move-stage'
  }
}

# =====================================================================
# Step 3: Remove source standing stacks
# =====================================================================
if ($plan.MoveRunStore -or $plan.MoveImages -or $plan.RemoveNetworkWatchers.Count) {
  Write-AvdSection "Remove standing stacks from $($plan.SourceLocation)"
}

if ($plan.MoveRunStore) {
  if ($PSCmdlet.ShouldProcess("avdlz-runs-rg / $storeName in $($plan.SourceLocation)", 'Delete activity log export, avdlz-runs-rg, and orphaned Automation role assignments')) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
      throw "Refusing to delete avdlz-runs-rg: no verified manifest at $manifestPath (never delete the last copy)."
    }
    $manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
    $observed = Get-LocalBundleObserved -BlobsRoot $blobsRoot -Manifest $manifest
    $bundleCheck = Test-AvdStandingBlobBundle -Manifest $manifest -Observed $observed
    if (-not $bundleCheck.Verified) {
      throw "Refusing to delete avdlz-runs-rg: local bundle verification failed ($($bundleCheck.Failed.Count) file(s))."
    }

    Write-Host '  Removing subscription diagnostic setting avdlz-runs-activity...' -ForegroundColor DarkGray
    $null = Invoke-StandingArm -Method DELETE -Path "/subscriptions/$subId/providers/microsoft.insights/diagnosticSettings/avdlz-runs-activity?api-version=2021-05-01-preview" -AllowNotFound

    Write-Host '  Removing resource group avdlz-runs-rg (takes 1 to 2 minutes)...' -ForegroundColor DarkGray
    Invoke-StandingResourceGroupDelete -Name 'avdlz-runs-rg'

    if ($oldAutomationPrincipalId) {
      Write-Host '  Cleaning up orphaned subscription role assignments for old aa-avdlz-runs identity...' -ForegroundColor DarkGray
      $subAssignments = @(Get-StandingArmList -Path "/subscriptions/$subId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
      foreach ($ra in @($subAssignments | Where-Object { $_.properties.principalId -eq $oldAutomationPrincipalId })) {
        $null = Invoke-StandingArm -Method DELETE -Path "$($ra.id)?api-version=2022-04-01" -AllowNotFound
      }
    }

    Write-Host "  Waiting for Azure Storage to release account name $storeName..." -ForegroundColor DarkGray
    $released = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
      $avail = Invoke-StandingArm -Method POST -Path "/subscriptions/$subId/providers/Microsoft.Storage/checkNameAvailability?api-version=2023-05-01" -Body @{ name = $storeName; type = 'Microsoft.Storage/storageAccounts' }
      if ($avail -and $avail.nameAvailable) { $released = $true; break }
      Start-Sleep -Seconds 10
    }
    if (-not $released) {
      Add-AvdCheckResult 'Remove' "Storage account name $storeName released" 'Fail' -Id 'region-move-name-wait' `
        -Detail "Azure has not released $storeName yet." -Remediation "Wait a minute and run Move-AvdStandingRegion.ps1 again with -Resume -BundlePath '$BundlePath'."
      $null = Write-AvdSummary
      exit 1
    }
    Add-AvdCheckResult 'Remove' "Removed avdlz-runs-rg from $($plan.SourceLocation) and confirmed $storeName is available" 'Fixed' -Id 'region-move-remove-runstore'
  }
  else {
    Add-AvdCheckResult 'Remove' "Would remove subscription diagnostic setting avdlz-runs-activity and resource group avdlz-runs-rg from $($plan.SourceLocation)" 'Skip' -Id 'region-move-remove-runstore'
  }
}

if ($plan.MoveImages) {
  if ($PSCmdlet.ShouldProcess("rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging in $($plan.SourceLocation)", 'Delete image pipeline resource groups and orphaned role assignments')) {
    foreach ($rgName in @("rg-$cleanPrefix-images", "rg-$cleanPrefix-images-staging")) {
      if ($rgs | Where-Object { $_.name -eq $rgName }) {
        Write-Host "  Removing resource group $rgName..." -ForegroundColor DarkGray
        Invoke-StandingResourceGroupDelete -Name $rgName
      }
    }
    if ($oldImagePrincipalIds.Count) {
      Write-Host '  Cleaning up orphaned subscription role assignments for old image build identities...' -ForegroundColor DarkGray
      $subAssignments = @(Get-StandingArmList -Path "/subscriptions/$subId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
      foreach ($ra in @($subAssignments | Where-Object { $_.properties.principalId -in $oldImagePrincipalIds })) {
        $null = Invoke-StandingArm -Method DELETE -Path "$($ra.id)?api-version=2022-04-01" -AllowNotFound
      }
    }
    Add-AvdCheckResult 'Remove' "Removed rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging from $($plan.SourceLocation)" 'Fixed' -Id 'region-move-remove-images'
  }
  else {
    Add-AvdCheckResult 'Remove' "Would remove rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging from $($plan.SourceLocation)" 'Skip' -Id 'region-move-remove-images'
  }
}

foreach ($w in $plan.RemoveNetworkWatchers) {
  if ($PSCmdlet.ShouldProcess("NetworkWatcherRG/$w in $($plan.SourceLocation)", 'Delete regional Network Watcher')) {
    Write-Host "  Removing Network Watcher $w..." -ForegroundColor DarkGray
    $null = Invoke-StandingArm -Method DELETE -Path "/subscriptions/$subId/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/$w`?api-version=2024-05-01" -AllowNotFound
    Add-AvdCheckResult 'Remove' "Removed NetworkWatcherRG/$w" 'Fixed' -Id 'region-move-remove-watcher'
  }
  else {
    Add-AvdCheckResult 'Remove' "Would remove NetworkWatcherRG/$w ($($plan.SourceLocation))" 'Skip' -Id 'region-move-remove-watcher'
  }
}

# =====================================================================
# Step 4: Redeploy standing stacks in TargetLocation
# =====================================================================
if ($plan.DeployRunStore -or $plan.DeployImages) {
  Write-AvdSection "Deploy standing stacks in $($plan.TargetLocation)"
}

if ($plan.DeployRunStore) {
  if ($PSCmdlet.ShouldProcess("avdlz-runs-rg / $storeName in $($plan.TargetLocation)", 'Deploy run store')) {
    if ($script:UseAzModule) {
      $initScript = Join-Path $PSScriptRoot 'Initialize-AvdRunStore.ps1'
      $initArgs = @{
        Location       = $plan.TargetLocation
        TeardownLogs   = $TeardownLogs
        SubscriptionId = $subId
      }
      if ($PrivateRepo) { $initArgs.PrivateRepo = $PrivateRepo }
      if ($AcceptDefenderCharge) { $initArgs.AcceptDefenderCharge = $true }
      if ($NoActivityLogExport) { $initArgs.NoActivityLogExport = $true }
      if ($NoDeadlineTeardown) { $initArgs.NoDeadlineTeardown = $true }
      if ($DeadlineRunbookUri) { $initArgs.DeadlineRunbookUri = $DeadlineRunbookUri }
      & $initScript @initArgs
      if ($LASTEXITCODE) {
        Add-AvdCheckResult 'Deploy' "Deploy run store in $($plan.TargetLocation)" 'Fail' -Id 'region-move-deploy-runstore' -Detail "Initialize-AvdRunStore.ps1 exited with $LASTEXITCODE."
        $null = Write-AvdSummary
        exit 1
      }
    }
    else {
      $meId = Get-StandingSignedInUserId
      $deadlineScript = 'scripts/automation/Invoke-AvdSandboxDeadline.ps1'
      $deadlineUri = ''
      if (-not $NoDeadlineTeardown) {
        if (-not $DeadlineRunbookUri) {
          $root = Join-Path $PSScriptRoot '../..'
          $sha = "$(git -C $root rev-parse HEAD 2>$null)".Trim()
          $origin = "$(git -C $root remote get-url origin 2>$null)".Trim()
          $onRemote = [bool]$sha -and [bool]"$(git -C $root branch -r --contains $sha 2>$null)".Trim()
          $DeadlineRunbookUri = Get-AvdPinnedRunbookUri -Origin $origin -Sha $sha -OnRemote $onRemote -Script $deadlineScript
        }
        if (-not $DeadlineRunbookUri -or -not (Test-AvdPinnedRunbookUri -Uri $DeadlineRunbookUri -Script $deadlineScript)) {
          throw "Cannot determine pinned deadline runbook URI. Pass -DeadlineRunbookUri or run from a pushed commit."
        }
        $deadlineUri = $DeadlineRunbookUri
      }
      Write-Host "  Deploying bicep/recorder/main.bicep in $($plan.TargetLocation)..." -ForegroundColor DarkGray
      $depName = "avdlzruns-store-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
      $tpl = Join-Path $PSScriptRoot '../../bicep/recorder/main.bicep'
      $exportStr = if ($NoActivityLogExport) { 'false' } else { 'true' }
      $out = az deployment sub create --name $depName --location $plan.TargetLocation --template-file $tpl `
        --parameters location=$($plan.TargetLocation) storageAccountName=$storeName operatorPrincipalId=$meId `
        teardownLogs=$TeardownLogs privateRepo="$(if ($PrivateRepo) { $PrivateRepo } else { '' })" `
        exportActivityLog=$exportStr deadlineRunbookUri="$deadlineUri" -o none 2>&1
      if ($LASTEXITCODE) { throw "Deploying run store failed: $out" }
    }
    Add-AvdCheckResult 'Deploy' "Deployed avdlz-runs-rg / $storeName in $($plan.TargetLocation)" 'Fixed' -Id 'region-move-deploy-runstore'
  }
  else {
    Add-AvdCheckResult 'Deploy' "Would deploy avdlz-runs-rg / $storeName in $($plan.TargetLocation) (TeardownLogs=$TeardownLogs, PrivateRepo=$(if ($PrivateRepo) { $PrivateRepo } else { 'none' }))" 'Skip' -Id 'region-move-deploy-runstore'
  }
}

if ($plan.DeployImages) {
  if ($PSCmdlet.ShouldProcess("rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging in $($plan.TargetLocation)", 'Deploy golden image pipeline')) {
    $buildNetRgName = "rg-$cleanPrefix-$BuildEnvironment-network"
    $buildNetRg = Invoke-StandingArm -Path "/subscriptions/$subId/resourceGroups/$buildNetRgName`?api-version=2024-03-01" -AllowNotFound
    $newClientId = ''
    if ($buildNetRg) {
      Write-Host "  Deploying bicep/images/main.bicep in $($plan.TargetLocation)..." -ForegroundColor DarkGray
      $depName = "avdlz-images-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
      $tpl = Join-Path $PSScriptRoot '../../bicep/images/main.bicep'
      if ($script:UseAzModule) {
        $dep = New-AzSubscriptionDeployment -Name $depName -Location $plan.TargetLocation -TemplateFile $tpl `
          -TemplateParameterObject @{
            namePrefix       = $NamePrefix
            location         = $plan.TargetLocation
            buildEnvironment = $BuildEnvironment
            githubRepository = $(if ($GithubRepository) { $GithubRepository } else { '' })
          } -ErrorAction Stop
        $newClientId = [string]$dep.Outputs.buildIdentityClientId.Value
      }
      else {
        $out = az deployment sub create --name $depName --location $plan.TargetLocation --template-file $tpl `
          --parameters namePrefix=$NamePrefix location=$($plan.TargetLocation) buildEnvironment=$BuildEnvironment `
          githubRepository="$(if ($GithubRepository) { $GithubRepository } else { '' })" --query "properties.outputs.buildIdentityClientId.value" -o tsv 2>&1
        if ($LASTEXITCODE) { throw "Deploying bicep/images/main.bicep failed: $out" }
        $newClientId = "$out".Trim()
      }
    }
    else {
      Write-Host "  Creating rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging in $($plan.TargetLocation)..." -ForegroundColor DarkGray
      $imgTags = @{ workload = 'avd'; managedBy = 'bicep'; landingZone = 'avd-cloud-native'; component = 'image-pipeline' }
      foreach ($rgName in @("rg-$cleanPrefix-images", "rg-$cleanPrefix-images-staging")) {
        $null = Invoke-StandingArm -Method PUT -Path "/subscriptions/$subId/resourceGroups/$rgName`?api-version=2024-03-01" -Body @{
          location = $plan.TargetLocation
          tags     = $imgTags
        }
      }

      $roleDefs = @(Get-StandingArmList -Path "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions?`$filter=type%20eq%20'CustomRole'&api-version=2022-04-01")
      $distRole = $roleDefs | Where-Object { $_.properties.roleName -like "AVD LZ image distributor ($cleanPrefix-*)" } | Select-Object -First 1
      if (-not $distRole) {
        throw "Custom role 'AVD LZ image distributor ($cleanPrefix-*)' not found on subscription."
      }
      $contributorRoleId = "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
      $blobReaderRoleId = "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
      $readerRoleId = "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"

      Write-Host '  Deploying bicep/images/modules/gallery.bicep...' -ForegroundColor DarkGray
      $galTpl = Join-Path $PSScriptRoot '../../bicep/images/modules/gallery.bicep'
      $stgTpl = Join-Path $PSScriptRoot '../../bicep/images/modules/stagingAccess.bicep'
      if ($script:UseAzModule) {
        $galDep = New-AzResourceGroupDeployment -Name 'avdlz-images-gallery' -ResourceGroupName "rg-$cleanPrefix-images" `
          -TemplateFile $galTpl `
          -TemplateParameterObject @{
            location          = $plan.TargetLocation
            tags              = $imgTags
            galleryName       = "gal$cleanPrefix"
            definitionName    = 'win11-avd-m365'
            aibIdentityName   = "id-$cleanPrefix-aib"
            buildIdentityName = "id-$cleanPrefix-image-build"
            githubRepository  = $(if ($GithubRepository) { $GithubRepository } else { '' })
            distributorRoleId = [string]$distRole.id
            contributorRoleId = $contributorRoleId
          } -ErrorAction Stop
        $aibPrincipalId = [string]$galDep.Outputs.aibPrincipalId.Value
        $buildPrincipalId = [string]$galDep.Outputs.buildPrincipalId.Value
        $newClientId = [string]$galDep.Outputs.buildClientId.Value

        Write-Host '  Deploying bicep/images/modules/stagingAccess.bicep...' -ForegroundColor DarkGray
        $null = New-AzResourceGroupDeployment -Name 'avdlz-images-staging' -ResourceGroupName "rg-$cleanPrefix-images-staging" `
          -TemplateFile $stgTpl `
          -TemplateParameterObject @{
            aibPrincipalId              = $aibPrincipalId
            buildPrincipalId            = $buildPrincipalId
            contributorRoleId           = $contributorRoleId
            storageBlobDataReaderRoleId = $blobReaderRoleId
          } -ErrorAction Stop
      }
      else {
        $tagsJson = ($imgTags | ConvertTo-Json -Compress)
        $galOut = az deployment group create --name 'avdlz-images-gallery' --resource-group "rg-$cleanPrefix-images" --template-file $galTpl `
          --parameters location=$($plan.TargetLocation) tags="$tagsJson" galleryName="gal$cleanPrefix" definitionName='win11-avd-m365' `
          aibIdentityName="id-$cleanPrefix-aib" buildIdentityName="id-$cleanPrefix-image-build" `
          githubRepository="$(if ($GithubRepository) { $GithubRepository } else { '' })" `
          distributorRoleId="$([string]$distRole.id)" contributorRoleId="$contributorRoleId" `
          --query "properties.outputs" -o json 2>&1
        if ($LASTEXITCODE) { throw "Deploying gallery.bicep failed: $galOut" }
        $galOutputs = ($galOut | Out-String | ConvertFrom-Json)
        $aibPrincipalId = [string]$galOutputs.aibPrincipalId.value
        $buildPrincipalId = [string]$galOutputs.buildPrincipalId.value
        $newClientId = [string]$galOutputs.buildClientId.value

        Write-Host '  Deploying bicep/images/modules/stagingAccess.bicep...' -ForegroundColor DarkGray
        $stgOut = az deployment group create --name 'avdlz-images-staging' --resource-group "rg-$cleanPrefix-images-staging" --template-file $stgTpl `
          --parameters aibPrincipalId="$aibPrincipalId" buildPrincipalId="$buildPrincipalId" `
          contributorRoleId="$contributorRoleId" storageBlobDataReaderRoleId="$blobReaderRoleId" -o none 2>&1
        if ($LASTEXITCODE) { throw "Deploying stagingAccess.bicep failed: $stgOut" }
      }

      $existingReader = @(Get-StandingArmList -Path "/subscriptions/$subId/providers/Microsoft.Authorization/roleAssignments?`$filter=principalId%20eq%20'$buildPrincipalId'&api-version=2022-04-01" | Where-Object { $_.properties.roleDefinitionId -eq $readerRoleId -and $_.properties.scope -eq "/subscriptions/$subId" })
      if (-not $existingReader.Count) {
        $raId = [guid]::NewGuid().ToString()
        $null = Invoke-StandingArm -Method PUT -Path "/subscriptions/$subId/providers/Microsoft.Authorization/roleAssignments/$raId`?api-version=2022-04-01" -Body @{
          properties = @{
            principalId      = $buildPrincipalId
            principalType    = 'ServicePrincipal'
            roleDefinitionId = $readerRoleId
          }
        }
      }
    }
    Add-AvdCheckResult 'Deploy' "Deployed rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging in $($plan.TargetLocation)" 'Fixed' -Id 'region-move-deploy-images' `
      -Detail $(if ($newClientId) { "New id-$cleanPrefix-image-build clientId: $newClientId (update AZURE_CLIENT_ID in the GitHub 'images' environment if used)." } else { '' })
  }
  else {
    Add-AvdCheckResult 'Deploy' "Would deploy rg-$cleanPrefix-images and rg-$cleanPrefix-images-staging in $($plan.TargetLocation) (GithubRepository=$(if ($GithubRepository) { $GithubRepository } else { 'none' }))" 'Skip' -Id 'region-move-deploy-images'
  }
}

# =====================================================================
# Step 5: Restore run store blobs and extra RBAC, then verify read-back
# =====================================================================
if ($plan.DeployRunStore) {
  Write-AvdSection 'Restore run store blobs and RBAC'
  if ($PSCmdlet.ShouldProcess("$storeName in $($plan.TargetLocation)", "Restore blobs and extra RBAC from $BundlePath")) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
      throw "No manifest at $manifestPath to restore."
    }
    $manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
    $sc = if ($script:UseAzModule) { New-AzStorageContext -StorageAccountName $storeName -UseConnectedAccount -ErrorAction Stop } else { $null }

    foreach ($cName in @($manifest | ForEach-Object { $_.container } | Select-Object -Unique)) {
      Invoke-StandingContainerEnsure -AccountName $storeName -Context $sc -Container $cName
    }

    $verifyRoot = Join-Path $BundlePath 'verify-readback'
    if (Test-Path -LiteralPath $verifyRoot) { Remove-Item -LiteralPath $verifyRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $verifyRoot -Force

    foreach ($m in $manifest) {
      $srcFile = Join-Path $blobsRoot (Join-Path $m.container ($m.name -replace '/', [IO.Path]::DirectorySeparatorChar))
      Send-StandingBlobFromFile -AccountName $storeName -Context $sc -Container $m.container -Blob $m.name -SourcePath $srcFile
      $verifyFile = Join-Path $verifyRoot (Join-Path $m.container ($m.name -replace '/', [IO.Path]::DirectorySeparatorChar))
      Save-StandingBlobToFile -AccountName $storeName -Context $sc -Container $m.container -Blob $m.name -Destination $verifyFile
    }

    $remoteObserved = Get-LocalBundleObserved -BlobsRoot $verifyRoot -Manifest $manifest
    Remove-Item -LiteralPath $verifyRoot -Recurse -Force -ErrorAction SilentlyContinue
    $restoreCheck = Test-AvdStandingBlobBundle -Manifest $manifest -Observed $remoteObserved
    if (-not $restoreCheck.Verified) {
      Add-AvdCheckResult 'Restore' 'Verified read-back of restored blobs' 'Fail' -Id 'region-move-restore-verify' `
        -Detail "$($restoreCheck.Failed.Count) blob(s) failed read-back verification." `
        -Remediation "Local bundle is still intact at $BundlePath. Re-run with -Resume."
      $null = Write-AvdSummary
      exit 1
    }

    $restoredRbac = 0
    if (Test-Path -LiteralPath $rbacPath) {
      $extraRbac = @(Get-Content -LiteralPath $rbacPath -Raw | ConvertFrom-Json | Where-Object { $_ })
      $rgScope = "/subscriptions/$subId/resourceGroups/avdlz-runs-rg"
      $currentAssignments = @(Get-StandingArmList -Path "$rgScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
      foreach ($r in $extraRbac) {
        $targetScope = "$rgScope$($r.relativeScope)"
        $exists = @($currentAssignments | Where-Object { $_.properties.principalId -eq $r.principalId -and $_.properties.roleDefinitionId -eq $r.roleDefinitionId -and $_.properties.scope -eq $targetScope })
        if (-not $exists.Count) {
          $raId = [guid]::NewGuid().ToString()
          $null = Invoke-StandingArm -Method PUT -Path "$targetScope/providers/Microsoft.Authorization/roleAssignments/$raId`?api-version=2022-04-01" -Body @{
            properties = @{
              principalId      = $r.principalId
              principalType    = $r.principalType
              roleDefinitionId = $r.roleDefinitionId
            }
          }
          $restoredRbac++
        }
      }
    }
    Add-AvdCheckResult 'Restore' "Restored and verified $($restoreCheck.Count) blob(s) in $storeName and $restoredRbac extra RBAC assignment(s)" 'Fixed' -Id 'region-move-restore'
  }
  else {
    Add-AvdCheckResult 'Restore' "Would restore staged blobs and extra RBAC assignments to $storeName in $($plan.TargetLocation) and verify SHA-256 read-back" 'Skip' -Id 'region-move-restore'
  }
}

$summary = Write-AvdSummary
exit $(if ($summary.Failed) { 1 } else { 0 })
