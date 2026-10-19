// =====================================================================
// Golden image pipeline: one build (build/specs/image-pipeline-spec.md section 5.2)
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// A short-lived Azure Image Builder template, named after the version it builds.
// scripts/ops/Start-AvdImageBuild.ps1 deploys it into rg-<prefix>-images, runs it,
// saves its log and deletes it. Every script is inlined from this commit, so
// nothing is fetched from this repository at build time and private forks work.
// Only WDOT is downloaded, from its own repository, and verified file by file.
// =====================================================================

targetScope = 'resourceGroup'

@description('The landing zone name prefix.')
@minLength(2)
@maxLength(8)
param namePrefix string

@description('The environment whose spoke holds the build subnets.')
@allowed([
  'dev'
  'test'
  'prod'
])
param buildEnvironment string = 'dev'

param location string = resourceGroup().location

@description('The image version to publish: YYYY.MDD.N, no zero padding (spec section 4.2).')
param version string

@description('The marketplace image version this build starts from (resolved from latest by the build script, so it is recorded).')
param sourceImageVersion string

@description('The marketplace image the golden image starts from.')
param sourceImage object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
}

@description('The repository commit the template and scripts come from.')
param commit string

@description('The workflow run that built this version.')
param runUrl string = ''

@description('A security build (spec section 5.7): recorded on the version.')
param emergency bool = false

@description('Regions to replicate to, one per environment region, with ZRS where the region has availability zones: [{ name, storageAccountType, replicaCount }].')
param replicaRegions array = [
  {
    name: location
    storageAccountType: 'Standard_LRS'
    replicaCount: 1
  }
]

@description('Build VM size: 4 vCPUs of a current D-series by default (spec section 5.2, red-team M3).')
param buildVmSize string = 'Standard_D4s_v5'

@description('Build timeout: a cumulative update, WDOT and three restarts can take more than 4 hours.')
@minValue(60)
@maxValue(960)
param buildTimeoutInMinutes int = 360

@description('Disconnected sessions end after this many hours (spec section 5.7).')
@minValue(1)
@maxValue(168)
param disconnectedSessionLimitHours int = 8

@description('Minimum FSLogix version the image must carry.')
param minimumFslogixVersion string = '2.9.0.0'

@description('Windows release the image must report (DisplayVersion).')
param expectedRelease string = '24H2'

@description('When the template was created; the build script sweeps templates older than 24 hours (red-team M7).')
param createdAt string = utcNow()

@description('End of life for this version: six months out (spec section 4.2).')
param endOfLifeDate string = dateTimeAdd(utcNow(), 'P6M')

var cleanPrefix = toLower(replace(namePrefix, '-', ''))
var buildBaseName = '${cleanPrefix}-${buildEnvironment}'
var templateName = 'it-${cleanPrefix}-${replace(version, '.', '-')}'
var versionId = resourceId('Microsoft.Compute/galleries/images/versions', 'gal${cleanPrefix}', 'win11-avd-m365', version)
var aibIdentityId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-${cleanPrefix}-aib')
var stagingResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', 'rg-${cleanPrefix}-images-staging')
var networkRg = 'rg-${buildBaseName}-network'
var buildSubnetId = resourceId(subscription().subscriptionId, networkRg, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${buildBaseName}', 'snet-image-build')
var aciSubnetId = resourceId(subscription().subscriptionId, networkRg, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${buildBaseName}', 'snet-image-aci')

// ---------- Inlined scripts (Windows PowerShell 5.1) ----------
var wdotLock = loadJsonContent('../../scripts/image/wdot/wdot.lock.json')
var protectedServices = loadJsonContent('../../scripts/image/protected-services.json').services
var wdotCall = 'Invoke-AvdWdot -LockBase64 \'${loadFileAsBase64('../../scripts/image/wdot/wdot.lock.json')}\' -ProfileBase64 @{ \'AppxPackages.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/AppxPackages.json')}\'; \'Autologgers.Json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/Autologgers.Json')}\'; \'DefaultUserSettings.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/DefaultUserSettings.json')}\'; \'EdgeSettings.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/EdgeSettings.json')}\'; \'LanManWorkstation.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/LanManWorkstation.json')}\'; \'PolicyRegSettings.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/PolicyRegSettings.json')}\'; \'ScheduledTasks.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/ScheduledTasks.json')}\'; \'Services.json\' = \'${loadFileAsBase64('../../scripts/image/wdot/profile/Services.json')}\' }'
var validateCall = 'Test-AvdGoldenImage -ExpectedRelease \'${expectedRelease}\' -MinimumUbr ${int(split(sourceImageVersion, '.')[1])} -MinimumFslogixVersion \'${minimumFslogixVersion}\' -WdotCommit \'${wdotLock.commit}\' -WdotProfileSha256 \'${wdotLock.profileSha256}\' -DisconnectedHours ${disconnectedSessionLimitHours} -ProtectedService @(\'${join(protectedServices, '\',\'')}\'); if ($script:AvdImageFailures) { exit 1 }'

func psStep(name string, lines string[]) object => {
  type: 'PowerShell'
  name: name
  inline: lines
  runElevated: true
  runAsSystem: true
  validExitCodes: [
    0
  ]
}

var customize = [
  {
    type: 'WindowsUpdate'
    name: 'windows-update'
    searchCriteria: 'IsInstalled=0 and Type=\'Software\''
    filters: [
      'exclude:$_.Title -like \'*Preview*\''
      'include:$true'
    ]
    updateLimit: 500
  }
  {
    type: 'WindowsRestart'
    name: 'restart-after-updates'
    restartTimeout: '30m'
  }
  psStep('storage-sense-off', split(loadTextContent('../../scripts/image/Disable-StorageSense.ps1'), '\n'))
  psStep('time-zone-redirection', split(loadTextContent('../../scripts/image/Enable-TimeZoneRedirection.ps1'), '\n'))
  psStep('session-time-limit', concat(split(loadTextContent('../../scripts/image/Set-SessionTimeLimit.ps1'), '\n'), [
    'Set-AvdSessionTimeLimit -DisconnectedHours ${disconnectedSessionLimitHours}'
  ]))
  psStep('automatic-updates-off', split(loadTextContent('../../scripts/image/Disable-AutomaticUpdates.ps1'), '\n'))
  psStep('wdot', concat(split(loadTextContent('../../scripts/image/Invoke-Wdot.ps1'), '\n'), [
    wdotCall
  ]))
  {
    type: 'WindowsRestart'
    name: 'restart-after-wdot'
    restartTimeout: '30m'
  }
  psStep('defender-signatures', split(loadTextContent('../../scripts/image/Update-DefenderSignature.ps1'), '\n'))
  psStep('custom', split(loadTextContent('../../scripts/image/custom/Invoke-CustomImageStep.ps1'), '\n'))
  psStep('cleanup', split(loadTextContent('../../scripts/image/Invoke-ImageCleanup.ps1'), '\n'))
  {
    type: 'WindowsRestart'
    name: 'restart-before-validation'
    restartTimeout: '30m'
  }
]

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: templateName
  location: location
  tags: {
    'avdlz-created': createdAt
    'avdlz-version': version
    'avdlz-commit': commit
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aibIdentityId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    stagingResourceGroup: stagingResourceGroupId
    vmProfile: {
      vmSize: buildVmSize
      osDiskSizeGB: 127
      vnetConfig: {
        subnetId: buildSubnetId
        containerInstanceSubnetId: aciSubnetId
      }
    }
    source: {
      type: 'PlatformImage'
      publisher: sourceImage.publisher
      offer: sourceImage.offer
      sku: sourceImage.sku
      version: sourceImageVersion
    }
    customize: customize
    validate: {
      continueDistributeOnFailure: false
      sourceValidationOnly: false
      inVMValidations: [
        psStep('golden-image', concat(split(loadTextContent('../../scripts/image/Test-GoldenImage.ps1'), '\n'), [
          validateCall
        ]))
      ]
    }
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: versionId
        runOutputName: 'avdlz-${replace(version, '.', '-')}'
        excludeFromLatest: true
        targetRegions: replicaRegions
        artifactTags: {
          'avdlz-commit': commit
          'avdlz-source-image': '${sourceImage.publisher}/${sourceImage.offer}/${sourceImage.sku}/${sourceImageVersion}'
          'avdlz-run': runUrl
          'avdlz-wdot': '${wdotLock.version}@${wdotLock.commit}'
          'avdlz-wdot-profile': wdotLock.profileSha256
          'avdlz-emergency': string(emergency)
          'avdlz-validation': 'pending'
          'avdlz-validated': 'false'
          'avdlz-end-of-life': endOfLifeDate
        }
      }
    ]
  }
}

output templateName string = imageTemplate.name
output imageVersionId string = versionId
