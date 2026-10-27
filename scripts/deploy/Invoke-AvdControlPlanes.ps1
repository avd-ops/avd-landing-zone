#requires -Version 7.2
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
<#
.SYNOPSIS
  Top-level orchestrator for the five AVD control planes (Decision 0009).

.DESCRIPTION
  Sequences deployment or reverse-order teardown across the selected control planes:
    Stage 1: entra          (avd-entra)          -> emits entra-manifest.json
    Stage 2: intune         (avd-intune)         -> consumes entra-manifest.json, emits intune-manifest.json
             m365           (avd-m365)           -> consumes entra-manifest.json, emits m365-manifest.json
             azure          (avd-azure)          -> consumes entra-manifest.json, emits azure-outputs.json
    Stage 3: power-platform (avd-power-platform) -> consumes entra-manifest.json + azure-outputs.json, emits power-platform-manifest.json

  Uses local sibling checkouts when present (../avd-<plane>) or clones/checks out each
  selected control-plane repository at its pinned commit SHA from contracts/control-planes.json
  in Azure Cloud Shell (~/avd-<plane>).

  Coordinated teardown (-Teardown) runs in reverse dependency order
  (power-platform -> azure -> m365 -> intune -> entra) and requires -DiscardLastCopy.

.EXAMPLE
  ./scripts/deploy/Invoke-AvdControlPlanes.ps1 -Preset greenfield -NamePrefix avdlz -Environment dev -Location northcentralus -DryRun

.EXAMPLE
  ./scripts/deploy/Invoke-AvdControlPlanes.ps1 -Planes entra,intune,azure -NamePrefix avdlz -Environment dev -Location eastus2

.EXAMPLE
  ./scripts/deploy/Invoke-AvdControlPlanes.ps1 -Preset greenfield -NamePrefix avdlz -Environment dev -Teardown -DiscardLastCopy -DryRun
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter()]
  [string[]] $Planes = @('entra', 'intune', 'm365', 'azure', 'power-platform'),

  [Parameter()]
  [ValidateSet('', 'greenfield', 'brownfield', 'brownfield-azure-intune', 'azure-only')]
  [string] $Preset = '',

  [Parameter()]
  [Alias('Prefix')]
  [ValidateLength(2, 8)]
  [string] $NamePrefix = 'avdlz',

  [Parameter()]
  [ValidateSet('dev', 'test', 'prod')]
  [string] $Environment = 'dev',

  [Parameter()]
  [string] $ParameterFile = '',

  [Parameter()]
  [string] $Location = 'northcentralus',

  [Parameter()]
  [string] $SubscriptionId = '',

  [Parameter()]
  [string] $UsersGroup = 'AVD Users',

  [Parameter()]
  [string] $AdminsGroup = 'AVD Admins',

  [Parameter()]
  [string] $WorkspaceDirectory = '',

  [Parameter()]
  [Alias('OutputDirectory', 'WorkingDirectory')]
  [string] $ManifestDirectory = '',

  [Parameter()]
  [string] $PinsPath = '',

  [Parameter()]
  [switch] $SkipCheckout,

  [Parameter()]
  [switch] $Teardown,

  [Parameter()]
  [switch] $DiscardLastCopy,

  [Parameter()]
  [switch] $DryRun,

  [Parameter()]
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ($Force) { $ConfirmPreference = 'None' }

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$repoParent = Split-Path -Parent $repoRoot
if (-not $ParameterFile) { $ParameterFile = "parameters/$Environment.bicepparam" }
if (-not $ManifestDirectory) { $ManifestDirectory = $repoRoot }
if (-not $PinsPath) { $PinsPath = Join-Path $repoRoot 'contracts/control-planes.json' }

if (-not (Test-Path -LiteralPath $PinsPath)) {
  throw "Control-plane pin manifest not found at: $PinsPath"
}

$pinConfig = Get-Content -LiteralPath $PinsPath -Raw | ConvertFrom-Json

function ConvertTo-CanonicalPlaneId {
  param([Parameter(Mandatory)][string] $Name)
  $trimmed = $Name.Trim()
  switch ($trimmed.ToLowerInvariant()) {
    'entra' { return 'entra' }
    'avd-entra' { return 'entra' }
    'intune' { return 'intune' }
    'avd-intune' { return 'intune' }
    'm365' { return 'm365' }
    'avd-m365' { return 'm365' }
    'azure' { return 'azure' }
    'avd-azure' { return 'azure' }
    'power-platform' { return 'power-platform' }
    'powerplatform' { return 'power-platform' }
    'avd-power-platform' { return 'power-platform' }
    default { throw "Unknown control plane '$trimmed'. Valid planes: entra, intune, m365, azure, power-platform." }
  }
}

function Resolve-AvdControlPlaneList {
  param(
    [string[]] $RawPlanes,
    [string] $PresetName,
    [pscustomobject] $Config
  )
  if ($PresetName) {
    $presetKey = switch ($PresetName.ToLowerInvariant()) {
      'brownfield-azure-intune' { 'brownfield' }
      default { $PresetName.ToLowerInvariant() }
    }
    $presetObj = $Config.presets.$presetKey
    if (-not $presetObj) {
      throw "Unknown control-plane preset '$PresetName'."
    }
    return @($presetObj.planes | ForEach-Object { [string]$_ })
  }

  $expanded = @()
  foreach ($item in $RawPlanes) {
    if (-not $item) { continue }
    foreach ($part in ($item -split ',')) {
      if ($part.Trim()) {
        $expanded += (ConvertTo-CanonicalPlaneId -Name $part)
      }
    }
  }
  if (-not $expanded.Count) {
    throw 'At least one control plane must be selected.'
  }
  return $expanded
}

function Resolve-AvdControlPlaneRepo {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][pscustomobject] $Plane,
    [string] $WorkspaceRoot,
    [string] $SiblingRoot,
    [switch] $NoCheckout,
    [switch] $IsDryRun
  )
  $candidates = @()
  if ($WorkspaceRoot) {
    $candidates += (Join-Path $WorkspaceRoot $Plane.name)
  }
  $siblingPath = Join-Path $SiblingRoot $Plane.name
  $candidates += $siblingPath
  if ($HOME) {
    $candidates += (Join-Path $HOME $Plane.name)
  }

  $resolvedDir = $null
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      $resolvedDir = [IO.Path]::GetFullPath($candidate)
      break
    }
  }

  if (-not $resolvedDir) {
    $targetDir = if ($WorkspaceRoot) { Join-Path $WorkspaceRoot $Plane.name } elseif ($HOME) { Join-Path $HOME $Plane.name } else { $siblingPath }
    $resolvedDir = [IO.Path]::GetFullPath($targetDir)
    $gitUrl = "$($Plane.url).git"
    if (-not $IsDryRun -and $PSCmdlet.ShouldProcess($resolvedDir, "Clone $($Plane.repo) at $($Plane.shortCommit)")) {
      & git clone $gitUrl $resolvedDir
      if ($LASTEXITCODE -ne 0) { throw "Failed to clone $($Plane.repo) from $gitUrl." }
      & git -C $resolvedDir checkout -q $Plane.commit
      if ($LASTEXITCODE -ne 0) { throw "Failed to check out pinned commit $($Plane.commit) in $resolvedDir." }
    }
  }
  elseif (-not $NoCheckout -and -not $IsDryRun -and (Test-Path -LiteralPath (Join-Path $resolvedDir '.git'))) {
    $head = (& git -C $resolvedDir rev-parse HEAD 2>$null | Out-String).Trim()
    if ($head -and -not $head.StartsWith($Plane.commit, [System.StringComparison]::OrdinalIgnoreCase)) {
      if ($PSCmdlet.ShouldProcess($resolvedDir, "Check out pinned commit $($Plane.shortCommit)")) {
        & git -C $resolvedDir fetch -q origin
        & git -C $resolvedDir checkout -q $Plane.commit
        if ($LASTEXITCODE -ne 0) { throw "Failed to check out pinned commit $($Plane.commit) in $resolvedDir." }
      }
    }
  }

  return $resolvedDir
}

function Test-AvdControlPlaneManifest {
  param(
    [Parameter(Mandatory)][string] $ManifestPath,
    [Parameter(Mandatory)][string] $SchemaPath,
    [Parameter(Mandatory)][string] $ExpectedSchemaId
  )
  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Required handoff manifest not found: $ManifestPath"
  }
  if (-not (Test-Path -LiteralPath $SchemaPath)) {
    throw "Contract schema file not found: $SchemaPath"
  }
  if (-not (Test-Json -Path $ManifestPath -SchemaFile $SchemaPath)) {
    throw "Handoff manifest '$ManifestPath' failed JSON Schema validation against '$SchemaPath'."
  }
  $data = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  if ($data.schema -ne $ExpectedSchemaId) {
    throw "Handoff manifest '$ManifestPath' has schema '$($data.schema)'; expected '$ExpectedSchemaId'."
  }
  return $data
}

function Write-AvdAzureOutputManifest {
  param(
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $Prefix,
    [Parameter(Mandatory)][string] $EnvName,
    [Parameter(Mandatory)][string] $Region,
    [string] $SubId = '00000000-0000-0000-0000-000000000000'
  )
  $base = "$Prefix-$EnvName"
  $effectiveSub = if ($SubId) { $SubId } else { '00000000-0000-0000-0000-000000000000' }
  $manifest = [ordered]@{
    schema         = 'avd-ops-azure-outputs/v1'
    environment    = $EnvName
    location       = $Region
    resourceGroups = [ordered]@{
      controlPlane = "rg-$base-avd"
      sessionHosts = "rg-$base-hosts"
      network      = "rg-$base-network"
      storage      = "rg-$base-storage"
    }
    hostPools      = @(
      [ordered]@{
        name        = "vdpool-$base"
        type        = 'Pooled'
        workspace   = "vdws-$base"
        appGroupIds = @(
          "/subscriptions/$effectiveSub/resourceGroups/rg-$base-avd/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-$base-desktop"
        )
      }
    )
    network        = [ordered]@{
      vnetName           = "vnet-$base"
      privateLinkEnabled = $true
    }
  }
  $parentDir = Split-Path -Parent $OutputPath
  if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
  }
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if ($Teardown -and -not $DiscardLastCopy -and -not $WhatIfPreference) {
  throw 'Never delete the last copy: coordinated control-plane teardown requires -DiscardLastCopy. Nothing was removed.'
}

$requestedSet = Resolve-AvdControlPlaneList -RawPlanes $Planes -PresetName $Preset -Config $pinConfig
$sequenceOrder = if ($Teardown) {
  @($pinConfig.teardownOrder | Where-Object { $requestedSet -contains $_ })
}
else {
  @($pinConfig.executionOrder | Where-Object { $requestedSet -contains $_ })
}

if (-not (Test-Path -LiteralPath $ManifestDirectory)) {
  New-Item -ItemType Directory -Path $ManifestDirectory -Force | Out-Null
}

$modeLabel = if ($Teardown) { 'TEARDOWN' } else { 'DEPLOY' }
Write-Host "==> AVD Control Planes Orchestrator ($modeLabel): $($sequenceOrder -join ' -> ')" -ForegroundColor Cyan

$stageResults = @()
$completedPlanes = @()
$emittedManifests = @()

foreach ($planeId in $sequenceOrder) {
  $plane = $pinConfig.planes.$planeId
  if (-not $plane) {
    throw "Control plane '$planeId' is missing from $PinsPath."
  }

  $planeRepoDir = Resolve-AvdControlPlaneRepo `
    -Plane $plane `
    -WorkspaceRoot $WorkspaceDirectory `
    -SiblingRoot $repoParent `
    -NoCheckout:$SkipCheckout `
    -IsDryRun:$DryRun

  $handoffPath = Join-Path $ManifestDirectory $plane.handoffManifest
  $runManifestPath = Join-Path $ManifestDirectory $plane.runManifest
  $schemaPath = Join-Path $repoRoot $plane.schemaFile

  if ($Teardown) {
    Write-Host "  [Stage $($plane.stage)] Teardown $($plane.name)@$($plane.shortCommit)" -ForegroundColor Yellow
    $teardownScriptPath = if ($plane.teardownScript) { Join-Path $planeRepoDir $plane.teardownScript } else { $null }

    if ($planeId -eq 'azure') {
      if ($DryRun) {
        Write-Host "  [DRY-RUN] Would remove Azure landing zone rg-$NamePrefix-$Environment-*" -ForegroundColor DarkGray
      }
      elseif ($PSCmdlet.ShouldProcess("avd-azure ($NamePrefix-$Environment)", 'Remove Azure landing zone')) {
        $removeDemoPath = Join-Path $repoRoot 'scripts/ops/Remove-AvdDemo.ps1'
        & $removeDemoPath -NamePrefix $NamePrefix -Environment $Environment -IncludeLandingZone -DiscardLastCopy -Force:$Force
      }
    }
    else {
      if (-not $teardownScriptPath -or -not (Test-Path -LiteralPath $teardownScriptPath)) {
        throw "Teardown script not found for $($plane.name): $teardownScriptPath"
      }
      if ($DryRun -and -not (Test-Path -LiteralPath $runManifestPath)) {
        Write-Host "  [DRY-RUN] Run manifest '$runManifestPath' not present; skipping $($plane.name) teardown." -ForegroundColor DarkGray
      }
      elseif ($PSCmdlet.ShouldProcess("$($plane.name) ($NamePrefix-$Environment)", 'Remove control plane resources')) {
        Push-Location $planeRepoDir
        try {
          & $teardownScriptPath -RunManifestPath $runManifestPath -DiscardLastCopy:$DiscardLastCopy -DryRun:$DryRun | Out-Null
        }
        finally {
          Pop-Location
        }
      }
    }

    $completedPlanes += $planeId
    $stageResults += [pscustomobject]@{
      Plane          = $planeId
      Repo           = $plane.repo
      Commit         = $plane.commit
      ShortCommit    = $plane.shortCommit
      Stage          = [int]$plane.stage
      Action         = 'Teardown'
      Script         = $plane.teardownScript
      RepositoryPath = $planeRepoDir
      ManifestPath   = $runManifestPath
      Status         = if ($WhatIfPreference -and -not $DryRun) { 'WhatIf' } else { 'Removed' }
    }
    continue
  }

  Write-Host "  [Stage $($plane.stage)] Deploy $($plane.name)@$($plane.shortCommit) -> $($plane.handoffManifest)" -ForegroundColor Cyan

  $entraManifestPath = Join-Path $ManifestDirectory 'entra-manifest.json'
  $entraSchemaPath = Join-Path $repoRoot 'contracts/schemas/entra-manifest.schema.json'
  $azureOutputsPath = Join-Path $ManifestDirectory 'azure-outputs.json'
  $azureSchemaPath = Join-Path $repoRoot 'contracts/schemas/azure-outputs.schema.json'

  if ($planeId -in @('intune', 'm365', 'power-platform')) {
    Test-AvdControlPlaneManifest -ManifestPath $entraManifestPath -SchemaPath $entraSchemaPath -ExpectedSchemaId 'avd-ops-entra-manifest/v1' | Out-Null
  }
  if ($planeId -eq 'power-platform') {
    Test-AvdControlPlaneManifest -ManifestPath $azureOutputsPath -SchemaPath $azureSchemaPath -ExpectedSchemaId 'avd-ops-azure-outputs/v1' | Out-Null
  }

  $entryScriptPath = Join-Path $planeRepoDir $plane.entryPoint

  switch ($planeId) {
    'entra' {
      if (-not (Test-Path -LiteralPath $entryScriptPath)) {
        throw "Entry-point script not found for avd-entra: $entryScriptPath"
      }
      if ($DryRun -or $PSCmdlet.ShouldProcess("avd-entra ($NamePrefix-$Environment)", 'Deploy Entra ID control plane')) {
        Push-Location $planeRepoDir
        try {
          & $entryScriptPath `
            -Prefix $NamePrefix `
            -Environment $Environment `
            -OutputPath $handoffPath `
            -RunManifestPath $runManifestPath `
            -DryRun:$DryRun | Out-Null
        }
        finally {
          Pop-Location
        }
      }
    }
    'intune' {
      if (-not (Test-Path -LiteralPath $entryScriptPath)) {
        throw "Entry-point script not found for avd-intune: $entryScriptPath"
      }
      if ($DryRun -or $PSCmdlet.ShouldProcess("avd-intune ($NamePrefix-$Environment)", 'Deploy Intune control plane')) {
        Push-Location $planeRepoDir
        try {
          & $entryScriptPath `
            -EntraManifestPath $entraManifestPath `
            -OutputPath $handoffPath `
            -RunManifestPath $runManifestPath `
            -Prefix $NamePrefix `
            -DryRun:$DryRun | Out-Null
        }
        finally {
          Pop-Location
        }
      }
    }
    'm365' {
      if (-not (Test-Path -LiteralPath $entryScriptPath)) {
        throw "Entry-point script not found for avd-m365: $entryScriptPath"
      }
      if ($DryRun -or $PSCmdlet.ShouldProcess("avd-m365 ($NamePrefix-$Environment)", 'Deploy Microsoft 365 control plane')) {
        Push-Location $planeRepoDir
        try {
          & $entryScriptPath `
            -EntraManifestPath $entraManifestPath `
            -OutputPath $handoffPath `
            -RunManifestPath $runManifestPath `
            -DryRun:$DryRun | Out-Null
        }
        finally {
          Pop-Location
        }
      }
    }
    'azure' {
      $effectiveUsers = $UsersGroup
      $effectiveAdmins = $AdminsGroup
      if (Test-Path -LiteralPath $entraManifestPath) {
        $entraData = Test-AvdControlPlaneManifest -ManifestPath $entraManifestPath -SchemaPath $entraSchemaPath -ExpectedSchemaId 'avd-ops-entra-manifest/v1'
        if ($entraData.groups.avdUsersGroupId) { $effectiveUsers = [string]$entraData.groups.avdUsersGroupId }
        if ($entraData.groups.avdAdminsGroupId) { $effectiveAdmins = [string]$entraData.groups.avdAdminsGroupId }
      }
      if ($DryRun) {
        Write-AvdAzureOutputManifest -OutputPath $handoffPath -Prefix $NamePrefix -EnvName $Environment -Region $Location -SubId $SubscriptionId
      }
      elseif ($PSCmdlet.ShouldProcess("avd-azure ($NamePrefix-$Environment)", 'Deploy Azure infrastructure control plane')) {
        $deploySh = if (Test-Path -LiteralPath $entryScriptPath) { $entryScriptPath } else { Join-Path $repoRoot 'scripts/deploy/deploy.sh' }
        $bashCmd = if ($env:AVDLZ_TEST_BASH) { $env:AVDLZ_TEST_BASH } else { 'bash' }
        $deployArgs = @($deploySh, '-p', $ParameterFile, '-l', $Location, '--users-group', $effectiveUsers, '--admins-group', $effectiveAdmins, '--azure-outputs', $handoffPath)
        if ($SubscriptionId) { $deployArgs += @('-s', $SubscriptionId) }
        & $bashCmd @deployArgs
        if ($LASTEXITCODE -ne 0) {
          throw "avd-azure deployment failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $handoffPath)) {
          Write-AvdAzureOutputManifest -OutputPath $handoffPath -Prefix $NamePrefix -EnvName $Environment -Region $Location -SubId $SubscriptionId
        }
      }
    }
    'power-platform' {
      if (-not (Test-Path -LiteralPath $entryScriptPath)) {
        throw "Entry-point script not found for avd-power-platform: $entryScriptPath"
      }
      if ($DryRun -or $PSCmdlet.ShouldProcess("avd-power-platform ($NamePrefix-$Environment)", 'Deploy Power Platform control plane')) {
        Push-Location $planeRepoDir
        try {
          & $entryScriptPath `
            -EntraManifestPath $entraManifestPath `
            -AzureOutputsPath $azureOutputsPath `
            -OutputPath $handoffPath `
            -RunManifestPath $runManifestPath `
            -DryRun:$DryRun | Out-Null
        }
        finally {
          Pop-Location
        }
      }
    }
  }

  if ($DryRun -or -not $WhatIfPreference) {
    Test-AvdControlPlaneManifest -ManifestPath $handoffPath -SchemaPath $schemaPath -ExpectedSchemaId $plane.schemaId | Out-Null
    $emittedManifests += $plane.handoffManifest
  }

  $completedPlanes += $planeId
  $stageResults += [pscustomobject]@{
    Plane          = $planeId
    Repo           = $plane.repo
    Commit         = $plane.commit
    ShortCommit    = $plane.shortCommit
    Stage          = [int]$plane.stage
    Action         = 'Deploy'
    Script         = $plane.entryPoint
    RepositoryPath = $planeRepoDir
    ManifestPath   = $handoffPath
    SchemaId       = $plane.schemaId
    Status         = if ($WhatIfPreference -and -not $DryRun) { 'WhatIf' } else { 'Succeeded' }
  }
}

$controlPlanesMap = [ordered]@{
  entra         = [bool]($requestedSet -contains 'entra')
  intune        = [bool]($requestedSet -contains 'intune')
  m365          = [bool]($requestedSet -contains 'm365')
  azure         = [bool]($requestedSet -contains 'azure')
  powerPlatform = [bool]($requestedSet -contains 'power-platform')
}

$stateObj = [ordered]@{
  v       = 1
  stage   = 'controlplanes'
  status  = if ($Teardown) { 'done' } else { 'succeeded' }
  context = [ordered]@{
    namePrefix      = $NamePrefix
    environment     = $Environment
    location        = $Location
    parameterFile   = $ParameterFile
    teardown        = [bool]$Teardown
    dryRun          = [bool]$DryRun
    controlPlanes   = $controlPlanesMap
    completedPlanes = @($completedPlanes)
    manifests       = @($emittedManifests)
  }
  counts   = [ordered]@{
    pass  = $completedPlanes.Count
    fail  = 0
    warn  = 0
    fixed = 0
  }
  failures = @()
  warnings = @()
}

if (-not $WhatIfPreference -or $DryRun) {
  Write-Host ("<<<AVDLZ-STATE " + ($stateObj | ConvertTo-Json -Depth 8 -Compress) + " AVDLZ-STATE>>>")
}

[pscustomobject]@{
  Status          = 'succeeded'
  Mode            = if ($Teardown) { 'Teardown' } else { 'Deploy' }
  Teardown        = [bool]$Teardown
  NamePrefix      = $NamePrefix
  Environment     = $Environment
  Location        = $Location
  ParameterFile   = $ParameterFile
  DryRun          = [bool]$DryRun
  Planes          = @($sequenceOrder)
  SelectedPlanes  = @($requestedSet)
  ExecutionOrder  = @($sequenceOrder)
  CompletedPlanes = @($completedPlanes)
  Manifests       = @($emittedManifests)
  ControlPlanes   = [pscustomobject]$controlPlanesMap
  Stages          = @($stageResults)
  State           = [pscustomobject]$stateObj
}
