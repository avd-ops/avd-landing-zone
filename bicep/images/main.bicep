// =====================================================================
// Golden image pipeline: the shared parts (build/specs/image-pipeline-spec.md, decision 0013)
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// One gallery per name prefix, shared by dev, test and prod, so every
// environment runs the same artifact. Each build is a separate, short-lived
// image template (build.bicep), deployed and removed by
// scripts/ops/Start-AvdImageBuild.ps1 from .github/workflows/image-build.yml.
//
// Deployed at SUBSCRIPTION scope, after the build environment's landing zone
// has been deployed with deployImageBuildSubnets = true.
// =====================================================================

targetScope = 'subscription'

metadata name = 'AVD landing zone golden image pipeline'
metadata description = 'Azure Compute Gallery, image definition and identities for monthly Azure Image Builder builds.'

@description('The landing zone name prefix (the same as the landing zone\'s namePrefix).')
@minLength(2)
@maxLength(8)
param namePrefix string

@description('Region for the gallery, its resource groups and the identities.')
param location string = deployment().location

@description('The landing zone environment whose spoke holds the build subnets (snet-image-build, snet-image-aci).')
@allowed([
  'dev'
  'test'
  'prod'
])
param buildEnvironment string = 'dev'

@description('GitHub repository (owner/name) whose image-build workflow may sign in as the build identity, through the "images" GitHub Environment. Empty = no federated credential.')
param githubRepository string = ''

@description('Extra tags merged onto every resource group and resource.')
param tags object = {}

var cleanPrefix = toLower(replace(namePrefix, '-', ''))
var buildBaseName = '${cleanPrefix}-${buildEnvironment}'
// Custom role names are unique per tenant; the suffix keeps two subscriptions with the same prefix apart.
var roleSuffix = '${cleanPrefix}-${take(uniqueString(subscription().id), 6)}'
var allTags = union(
  {
    workload: 'avd'
    managedBy: 'bicep'
    landingZone: 'avd-cloud-native'
    component: 'image-pipeline'
  },
  tags
)
var names = {
  rgImages: 'rg-${cleanPrefix}-images'
  rgStaging: 'rg-${cleanPrefix}-images-staging'
  gallery: 'gal${cleanPrefix}'
  definition: 'win11-avd-m365'
  aibIdentity: 'id-${cleanPrefix}-aib'
  buildIdentity: 'id-${cleanPrefix}-image-build'
  buildNetworkRg: 'rg-${buildBaseName}-network'
  buildVnet: 'vnet-${buildBaseName}'
}
// Built-in roles (Microsoft's role definitions).
var builtInRoles = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  storageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
}

// ---------- Resource groups ----------
resource rgImages 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgImages
  location: location
  tags: allTags
}

// Azure Image Builder puts the build VM, its disk, the build container and its logs
// here. Nothing else lives in this group, and AIB needs Contributor on it.
resource rgStaging 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgStaging
  location: location
  tags: allTags
}

// ---------- Custom roles (least privilege for Azure Image Builder) ----------
resource distributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, cleanPrefix, 'avdlz-image-distributor')
  properties: {
    roleName: 'AVD LZ image distributor (${roleSuffix})'
    description: 'Lets Azure Image Builder publish image versions to the landing zone gallery.'
    type: 'CustomRole'
    assignableScopes: [
      subscription().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
          'Microsoft.Compute/images/read'
          'Microsoft.Compute/images/write'
          'Microsoft.Compute/images/delete'
        ]
        notActions: []
      }
    ]
  }
}

resource buildNetworkRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, cleanPrefix, 'avdlz-image-build-network')
  properties: {
    roleName: 'AVD LZ image build network (${roleSuffix})'
    description: 'Lets Azure Image Builder place the build VM and the build container in the image build subnets.'
    type: 'CustomRole'
    assignableScopes: [
      subscription().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
        ]
        notActions: []
      }
    ]
  }
}

// ---------- Gallery, definition, identities ----------
module images 'modules/gallery.bicep' = {
  name: 'avdlz-images-gallery'
  scope: rgImages
  params: {
    location: location
    tags: allTags
    galleryName: names.gallery
    definitionName: names.definition
    aibIdentityName: names.aibIdentity
    buildIdentityName: names.buildIdentity
    githubRepository: githubRepository
    distributorRoleId: distributorRole.id
    contributorRoleId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.contributor)
  }
}

// AIB: Contributor on the staging group. The build workflow: Reader there and on the
// customization logs, to report a failed build (build/lessons/0012).
module staging 'modules/stagingAccess.bicep' = {
  name: 'avdlz-images-staging'
  scope: rgStaging
  params: {
    aibPrincipalId: images.outputs.aibPrincipalId
    buildPrincipalId: images.outputs.buildPrincipalId
    contributorRoleId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.contributor)
    storageBlobDataReaderRoleId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.storageBlobDataReader)
  }
}

// AIB: join the two build subnets in the build environment's spoke. Fails here, early,
// when that landing zone was deployed without deployImageBuildSubnets.
module buildNetwork 'modules/buildNetworkAccess.bicep' = {
  name: 'avdlz-images-build-network'
  scope: resourceGroup(names.buildNetworkRg)
  params: {
    vnetName: names.buildVnet
    aibPrincipalId: images.outputs.aibPrincipalId
    buildNetworkRoleId: buildNetworkRole.id
  }
}

// The build workflow reads source image versions, quota and provider state.
resource buildReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, names.buildIdentity, builtInRoles.reader)
  properties: {
    principalId: images.outputs.buildPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtInRoles.reader)
  }
}

output imagesResourceGroupName string = rgImages.name
output stagingResourceGroupId string = rgStaging.id
output galleryName string = names.gallery
output imageDefinitionId string = images.outputs.imageDefinitionId
output aibIdentityId string = images.outputs.aibIdentityId
output buildSubnetId string = buildNetwork.outputs.buildSubnetId
output buildAciSubnetId string = buildNetwork.outputs.aciSubnetId
@description('Set as the AZURE_CLIENT_ID secret of the "images" GitHub Environment.')
output buildIdentityClientId string = images.outputs.buildClientId
