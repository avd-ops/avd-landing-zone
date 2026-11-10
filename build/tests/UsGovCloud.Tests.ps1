# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
# Offline tests for Azure US Government / GCC High support (C26 cloud-environments.json, cross-tool cloud guard,
# offline US Gov pricing fallback, orchestrator flags, and Bicep cloud parameters).
# Run: Invoke-Pester ./build/tests/UsGovCloud.Tests.ps1

BeforeAll {
  $script:root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  Import-Module (Join-Path $script:root 'scripts/ops/AvdLandingZone.psm1') -Force
  Import-Module (Join-Path $script:root 'scripts/ops/AvdTargetState.psm1') -Force
  $script:contractsDir = Join-Path $script:root 'contracts'
}

Describe 'C26 Cloud Environment Contract and PINS.json' {
  It 'vendors contracts/cloud-environments.json with matching SHA-256 in contracts/PINS.json' {
    $c26Path = Join-Path $script:contractsDir 'cloud-environments.json'
    Test-Path -LiteralPath $c26Path | Should -BeTrue
    $c26 = Get-Content -LiteralPath $c26Path -Raw | ConvertFrom-Json
    $c26.schema | Should -Be 'avd-cloud-environments/v1'
    $c26.clouds.commercial.psEnvironmentName | Should -Be 'AzureCloud'
    $c26.clouds.usgov.psEnvironmentName | Should -Be 'AzureUSGovernment'
    $c26.clouds.usgov.entraEnvironment | Should -Be 'USGov'
    $c26.clouds.usgov.privateDnsZones.avdConnection | Should -Be 'privatelink.avd.azure.us'
    $c26.clouds.usgov.privateDnsZones.avdGlobal | Should -Be 'privatelink-global.wvd.azure.us'

    $pins = Get-Content -LiteralPath (Join-Path $script:contractsDir 'PINS.json') -Raw | ConvertFrom-Json
    $actualSha = (Get-FileHash -LiteralPath $c26Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $pins.files.'cloud-environments.json' | Should -Be $actualSha
  }

  It 'Resolves commercial and usgov environments via Resolve-AvdCloudEnvironment' {
    $comm = Resolve-AvdCloudEnvironment -Cloud 'commercial'
    $comm.cloud | Should -Be 'commercial'
    $comm.azEnvironment | Should -Be 'AzureCloud'
    $comm.mgEnvironment | Should -Be 'Global'
    $comm.privateDnsZones.avdConnection | Should -Be 'privatelink.wvd.microsoft.com'

    $gov = Resolve-AvdCloudEnvironment -Cloud 'usgov'
    $gov.cloud | Should -Be 'usgov'
    $gov.azEnvironment | Should -Be 'AzureUSGovernment'
    $gov.azCliCloud | Should -Be 'AzureUSGovernment'
    $gov.mgEnvironment | Should -Be 'USGov'
    $gov.endpoints.arm | Should -Be 'https://management.usgovcloudapi.net'
    $gov.endpoints.graph | Should -Be 'https://graph.microsoft.us'
    $gov.privateDnsZones.avdConnection | Should -Be 'privatelink.avd.azure.us'
    $gov.privateDnsZones.avdGlobal | Should -Be 'privatelink-global.wvd.azure.us'
    ($gov.regions -contains 'usgovvirginia') | Should -BeTrue
    ($gov.regions -contains 'usgovarizona') | Should -BeTrue
    ($gov.regions -contains 'usgovtexas') | Should -BeTrue

    $govAlias = Resolve-AvdCloudEnvironment -Cloud 'AzureUSGovernment'
    $govAlias.cloud | Should -Be 'usgov'
  }
}

Describe 'Fail-Closed Cross-Tool Cloud Guard (Test-AvdCrossCloudGuard)' {
  It 'passes when Az, az CLI, MgGraph, and Location all match usgov' {
    $res = Test-AvdCrossCloudGuard -Cloud 'usgov' -AzEnvironmentName 'AzureUSGovernment' -AzCliCloudName 'AzureUSGovernment' -MgEnvironmentName 'USGov' -Location 'usgovvirginia'
    $res.Valid | Should -BeTrue
    $res.Cloud | Should -Be 'usgov'
    $res.Mismatches.Count | Should -Be 0
  }

  It 'passes when Az, az CLI, MgGraph, and Location all match commercial' {
    $res = Test-AvdCrossCloudGuard -Cloud 'commercial' -AzEnvironmentName 'AzureCloud' -AzCliCloudName 'AzureCloud' -MgEnvironmentName 'Global' -Location 'eastus2'
    $res.Valid | Should -BeTrue
    $res.Cloud | Should -Be 'commercial'
    $res.Mismatches.Count | Should -Be 0
  }

  It 'fails closed when Az is AzureUSGovernment but MgGraph is Global (cross-cloud mismatch)' {
    $res = Test-AvdCrossCloudGuard -Cloud 'usgov' -AzEnvironmentName 'AzureUSGovernment' -AzCliCloudName 'AzureUSGovernment' -MgEnvironmentName 'Global' -Location 'usgovvirginia'
    $res.Valid | Should -BeFalse
    ($res.Mismatches -join ' ') | Should -Match 'Microsoft\.Graph context is ''Global'''
  }

  It 'fails closed when Az is AzureCloud but az CLI is AzureUSGovernment' {
    $res = Test-AvdCrossCloudGuard -Cloud 'commercial' -AzEnvironmentName 'AzureCloud' -AzCliCloudName 'AzureUSGovernment' -MgEnvironmentName 'Global' -Location 'eastus2'
    $res.Valid | Should -BeFalse
    ($res.Mismatches -join ' ') | Should -Match 'Azure CLI cloud is ''AzureUSGovernment'''
  }

  It 'fails closed when Cloud is usgov but Location is a commercial region (eastus2)' {
    $res = Test-AvdCrossCloudGuard -Cloud 'usgov' -AzEnvironmentName 'AzureUSGovernment' -AzCliCloudName 'AzureUSGovernment' -MgEnvironmentName 'USGov' -Location 'eastus2'
    $res.Valid | Should -BeFalse
    ($res.Mismatches -join ' ') | Should -Match 'not an allowed US Gov region'
  }

  It 'fails closed when Cloud is commercial but Location is a US Gov region (usgovvirginia)' {
    $res = Test-AvdCrossCloudGuard -Cloud 'commercial' -AzEnvironmentName 'AzureCloud' -AzCliCloudName 'AzureCloud' -MgEnvironmentName 'Global' -Location 'usgovvirginia'
    $res.Valid | Should -BeFalse
    ($res.Mismatches -join ' ') | Should -Match 'US Government region'
  }
}

Describe 'Offline US Gov Retail Pricing Fallback' {
  It 'reads pinned US Gov prices from contracts/usgov-retail-prices.snapshot.json' {
    $snapPath = Join-Path $script:contractsDir 'usgov-retail-prices.snapshot.json'
    Test-Path -LiteralPath $snapPath | Should -BeTrue
    $snap = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json
    $snap.cloud | Should -Be 'usgov'
    ($snap.regions -contains 'usgovvirginia') | Should -BeTrue
    ($snap.regions -contains 'usgovarizona') | Should -BeTrue
    ($snap.regions -contains 'usgovtexas') | Should -BeTrue

    $vmPrice = Get-AvdPinnedUsGovPrice -Region 'usgovvirginia' -ServiceName 'Virtual Machines' -ArmSkuName 'Standard_E4as_v5' | Select-Object -First 1
    $vmPrice | Should -Not -BeNullOrEmpty
    ($vmPrice.unitPrice -gt 0) | Should -BeTrue
  }

  It 'computes a full US Gov cost estimate offline with priceSource = pinned-usgov-snapshot' {
    $plan = @{
      Location              = 'usgovvirginia'
      Environment           = 'prod'
      SessionHostCount      = 2
      SessionHostVmSize     = 'Standard_E4as_v5'
      ProfileShareQuotaGiB  = 200
      ProfileStorageSku     = 'Premium_LRS'
      DeployPrivateDnsZones = $true
      ActiveHoursPerWeek    = 50
    }
    foreach ($govRegion in @('usgovvirginia', 'usgovarizona', 'usgovtexas')) {
      $plan.Location = $govRegion
      $est = Get-AvdCostEstimate -Plan $plan -Cloud 'usgov' -OfflinePricing
      $est.cloud | Should -Be 'usgov'
      $est.location | Should -Be $govRegion
      $est.priceSource | Should -Be 'pinned-usgov-snapshot'
      $est.unpriced.Count | Should -Be 0
      ($est.total -gt 0) | Should -BeTrue
      ($est.alwaysOnTotal -gt $est.total) | Should -BeTrue
    }
  }
}

Describe 'Bicep and Script US Gov Parameters' {
  It 'exposes cloud and complianceProfile in bicep/main.bicep and modules' {
    $mainBicep = Get-Content -LiteralPath (Join-Path $script:root 'bicep/main.bicep') -Raw
    $mainBicep | Should -Match "param cloud string = 'commercial'"
    $mainBicep | Should -Match "param complianceProfile string ="

    $dnsBicep = Get-Content -LiteralPath (Join-Path $script:root 'bicep/modules/privateDns.bicep') -Raw
    $dnsBicep | Should -Match 'privatelink\.wvd\.azure\.us'
    $dnsBicep | Should -Match 'privatelink-global\.wvd\.azure\.us'
  }

  It 'exposes -Cloud on Connect-AvdLandingZone, Test-AvdLandingZoneReadiness, and Invoke-AvdControlPlanes' {
    (Get-Command (Join-Path $script:root 'scripts/ops/Connect-AvdLandingZone.ps1')).Parameters.ContainsKey('Cloud') | Should -BeTrue
    (Get-Command (Join-Path $script:root 'scripts/ops/Test-AvdLandingZoneReadiness.ps1')).Parameters.ContainsKey('Cloud') | Should -BeTrue
    (Get-Command (Join-Path $script:root 'scripts/ops/Test-AvdLandingZoneReadiness.ps1')).Parameters.ContainsKey('OfflinePricing') | Should -BeTrue
    (Get-Command (Join-Path $script:root 'scripts/deploy/Invoke-AvdControlPlanes.ps1')).Parameters.ContainsKey('Cloud') | Should -BeTrue
    (Get-Command (Join-Path $script:root 'scripts/deploy/Invoke-AvdControlPlanes.ps1')).Parameters.ContainsKey('ComplianceProfile') | Should -BeTrue
  }
}
