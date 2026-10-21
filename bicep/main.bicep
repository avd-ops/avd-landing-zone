// =====================================================================
// Cloud-native AVD Landing Zone — orchestration
// Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
//
// One opinionated path: Entra ID-joined, Intune-enrolled session hosts,
// Entra Kerberos for FSLogix, private-by-default PaaS, and everything —
// including session host registration and FSLogix config — declared here.
// No domain controllers, no post-deploy scripts, no runtime downloads from
// GitHub. See docs/design-decisions.md for how this differs from the
// Microsoft AVD Landing Zone Accelerator.
//
// Deployed at SUBSCRIPTION scope into a dedicated AVD landing zone
// subscription (subscription-vending model).
// =====================================================================

targetScope = 'subscription'

metadata name = 'Cloud-native AVD landing zone'
metadata description = 'Entra ID-only, Intune-managed, private-by-default Azure Virtual Desktop landing zone for greenfield deployments.'

// ---------- Core ----------
@description('Short workload prefix (lowercase letters/digits, 2-8 chars). Resource names derive from this.')
@minLength(2)
@maxLength(8)
param namePrefix string

@description('Environment. Drives naming and a few safe-by-default toggles.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string

@description('Azure region for all regional resources.')
param location string = deployment().location

@description('Extra tags merged onto every resource group and resource.')
param tags object = {}

// ---------- Identity (Entra ID) ----------
@description('Object ID of the Entra ID security group whose members get the desktop (Desktop Virtualization User, VM User Login, SMB Share Contributor).')
param avdUsersGroupObjectId string

@description('Object ID of the Entra ID security group of AVD operators (VM Administrator Login, SMB Share Elevated Contributor, Key Vault Secrets User).')
param avdAdminsGroupObjectId string

@description('Object ID of the Azure Virtual Desktop service principal in this tenant (app ID 9cdead84-a844-4324-93f2-b2e6bb768d07). Needed for autoscale and Start VM on Connect. deploy.sh looks it up for you.')
param avdServicePrincipalObjectId string

@description('Enroll session hosts in Microsoft Intune as part of the Entra join.')
param enrollInIntune bool = true

// ---------- Connectivity ----------
@description('Standalone = self-contained spoke with NAT Gateway egress and local private DNS zones. HubPeered = peer to an existing hub, force egress through its firewall, use its DNS.')
@allowed([
  'Standalone'
  'HubPeered'
])
param connectivityMode string = 'Standalone'

@description('Address space for the AVD spoke VNet.')
param spokeAddressPrefix string = '10.100.0.0/22'

@description('Session host subnet (inside the spoke). /23 = ~500 hosts.')
param sessionHostSubnetPrefix string = '10.100.0.0/23'

@description('Private endpoint subnet (inside the spoke).')
param privateEndpointSubnetPrefix string = '10.100.2.0/27'

@description('Add the golden image build subnets to this spoke (build/specs/image-pipeline-spec.md). Only the image build environment needs them; off by default.')
param deployImageBuildSubnets bool = false

@description('Image build VM subnet (inside the spoke).')
param imageBuildSubnetPrefix string = '10.100.2.128/27'

@description('Image build container subnet, delegated to Azure Container Instances (inside the spoke).')
param imageBuildAciSubnetPrefix string = '10.100.2.160/27'

@description('HubPeered only: resource ID of the hub VNet.')
param hubVnetResourceId string = ''

@description('HubPeered only: create the hub-to-spoke side of the peering too. Requires Network Contributor on the hub VNet for the deploying identity.')
param createHubToSpokePeering bool = true

@description('HubPeered only: private IP of the hub firewall/NVA. 0.0.0.0/0 from the session host subnet is routed here.')
param hubFirewallPrivateIp string = ''

@description('Custom DNS servers for the spoke (e.g. hub firewall DNS proxy or Private DNS Resolver inbound IP). Empty = Azure-provided DNS.')
param dnsServers array = []

@description('Resource IDs of EXISTING, centrally managed private DNS zones: { file: \'...\', keyVault: \'...\', avd: \'...\' }. Leave empty to create zones locally and link them to the spoke (Standalone).')
param centralPrivateDnsZoneResourceIds object = {}

@description('Use Private Link for the AVD host pool connection (session hosts reach the AVD service privately; clients still connect over the internet).')
param enableAvdPrivateLink bool = true

// ---------- Session hosts ----------
@description('Number of session hosts.')
@minValue(0)
@maxValue(200)
param sessionHostCount int = 2

@description('Session host VM size. Memory-optimized E-series by default: multi-session hosts run out of memory before CPU (8 GiB per vCPU, against 4 on D-series). Check vCPU quota (the Easv5 family) and zonal availability first.')
param sessionHostVmSize string = 'Standard_E4as_v5'

@description('Session host name prefix (max 11 chars; a 3-digit index is appended to stay within the 15-char Windows limit).')
@maxLength(11)
param sessionHostNamePrefix string = take('${toLower(replace(namePrefix, '-', ''))}${take(environmentName, 1)}sh', 11)

@description('Availability zones to spread session hosts across. Empty array = regional (no zones).')
param availabilityZones int[] = [
  1
  2
  3
]

@description('Marketplace image for session hosts. Replace with an Azure Compute Gallery image when you have an image pipeline.')
param sessionHostImage object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'office-365'
  sku: 'win11-24h2-avd-m365'
  version: 'latest'
}

@description('Azure Compute Gallery image version resource ID for session hosts, from the image pipeline (build/specs/image-pipeline-spec.md section 6.1). A version, never a definition or latest, so nothing changes software silently. Empty: the marketplace image above.')
param sessionHostImageId string = ''

@description('Host generation for blue/green rotation: empty keeps the original host names; a or b gives take(sessionHostNamePrefix, 10) + the generation, so the two generations never collide. Only the rotation script changes it.')
@allowed([
  ''
  'a'
  'b'
])
param sessionHostGeneration string = ''

@description('The host pool tags the rotation script owns (avdlz-image, avdlz-generation, avdlz-image-next, avdlz-image-previous, avdlz-rotation). deploy.sh passes the pool\'s current values so a deployment keeps them; nothing else sets them.')
param hostPoolStateTags object = {}

@description('Maximum sessions per host (breadth-first). Size to your workload.')
param maxSessionLimit int = 8

@description('Enable encryption at host. Requires the Microsoft.Compute/EncryptionAtHost feature on the subscription (deploy.sh registers it).')
param encryptionAtHost bool = true

@description('Break-glass local administrator name. Day-to-day admin access is via Entra ID (VM Administrator Login).')
param localAdminUsername string = 'avdbreakglass'

@description('Break-glass local administrator password, applied when a host is created and stored in Key Vault. deploy.sh generates a random one unless AVD_LOCAL_ADMIN_PASSWORD is set; never commit it.')
@secure()
@minLength(14)
param localAdminPassword string

@description('RDP properties for the host pool. Defaults: Entra SSO on; drive, COM and USB redirection off.')
param rdpProperties string = 'enablerdsaadauth:i:1;targetisaadjoined:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:1;redirectprinters:i:1;redirectclipboard:i:1;redirectwebauthn:i:1;audiomode:i:0;audiocapturemode:i:1;camerastoredirect:s:*;use multimon:i:1'

@description('Mark the host pool as a validation pool (gets AVD service updates first). Recommended for non-prod.')
param validationEnvironment bool = environmentName != 'prod'

// ---------- Profiles (FSLogix on Azure Files) ----------
@description('Premium Azure Files redundancy. ZRS where the region supports it.')
@allowed([
  'Premium_LRS'
  'Premium_ZRS'
])
param profileStorageSku string = 'Premium_ZRS'

@description('Provisioned size of the profile share in GiB. On Premium, IOPS and throughput scale with this number.')
@minValue(100)
param profileShareQuotaGiB int = 1024

@description('Maximum size of each FSLogix profile container in MiB.')
param fslogixProfileSizeMiB int = 30720

@description('Back up the profile share with Azure Backup.')
param enableProfileBackup bool = true

@description('Daily backup retention for the profile share, in days.')
param profileBackupRetentionDays int = 30

@description('Profile backup tier (build/specs/recovery-spec.md). Snapshot: snapshots kept in the share, lost with it. Vaulted: copies kept in the Recovery Services vault, the offsite copy; Azure Backup then needs storage account key access, so the profile storage account allows it (SMB stays Kerberos-only).')
@allowed([
  'Snapshot'
  'Vaulted'
])
param profileBackupTier string = 'Snapshot'

// ---------- Scaling ----------
@description('Start a deallocated session host when a user connects (Start VM on Connect). Off: users can only connect while the scaling plan keeps hosts running, and hosts run longer (cost).')
param startVmOnConnect bool = true

@description('Time zone for the autoscale schedule (Windows time zone ID).')
param scalingTimeZone string = 'UTC'

// ---------- Operations & governance ----------
@description('Log Analytics retention in days.')
param logRetentionDays int = 90

@description('Email addresses for alerts and budget notifications.')
param alertEmailAddresses string[] = []

@description('Monthly budget for the subscription in billing currency. 0 = no budget.')
param monthlyBudgetAmount int = 0

@description('Budget start date (first of a month, yyyy-MM-01). Required when monthlyBudgetAmount > 0. Keep it fixed across deployments.')
param budgetStartDate string = ''

// ---------- Auto shutdown (decision 0011) ----------
@description('Deploy the auto-shutdown runbook: it stops the session hosts on a schedule and stops or locks them when the budget is exceeded.')
param enableAutoShutdown bool = true

@description('Time to stop the session hosts on the scheduled days (HH:mm, in autoShutdownTimeZone). Empty = no scheduled stop (the scaling plan still scales down).')
param autoShutdownTime string = ''

@description('Days the scheduled stop runs.')
param autoShutdownDays string[] = [
  'Monday'
  'Tuesday'
  'Wednesday'
  'Thursday'
  'Friday'
  'Saturday'
  'Sunday'
]

@description('Windows time zone name for autoShutdownTime.')
param autoShutdownTimeZone string = scalingTimeZone

@description('What the scheduled stop does: Stop deallocates idle hosts; Lock keeps every host off until Resume.')
@allowed([
  'Stop'
  'Lock'
])
param autoShutdownScheduleAction string = 'Stop'

@description('What a budget alert does: Lock keeps every host off until someone runs Resume; Stop deallocates idle hosts; None = no budget trigger. Needs the budget (monthlyBudgetAmount, budgetStartDate, alertEmailAddresses).')
@allowed([
  'Lock'
  'Stop'
  'None'
])
param autoShutdownBudgetAction string = 'Lock'

@description('Percentage of the monthly budget (actual cost) that triggers autoShutdownBudgetAction.')
@minValue(1)
@maxValue(1000)
param autoShutdownBudgetPercent int = 100

@description('Where Automation downloads the runbook from. deploy.sh pins it to the commit being deployed (AVD_RUNBOOK_URI).')
param autoShutdownRunbookUri string = 'https://raw.githubusercontent.com/nickprignano/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1'

// ---------- Operator jumpbox (decision 0018) ----------
@description('Add an operator jumpbox: a small Linux VM in the spoke with the Cloud Shell toolchain, reached in the browser through Azure Bastion Developer (no charge, no public IP). Off by default. Bastion Developer exists only in some regions (Get-AvdBastionDeveloperRegion).')
param deployJumpbox bool = false

@description('Jumpbox subnet (inside the spoke).')
param jumpboxSubnetPrefix string = '10.100.2.32/28'

@description('Jumpbox VM size: the smallest burstable size with room for PowerShell and the Az modules (2 vCPUs, 4 GiB).')
param jumpboxVmSize string = 'Standard_B2als_v2'

@description('Daily stop of the jumpbox (HHmm, in autoShutdownTimeZone). It always has one unless jumpboxKeepRunningUntil is set (avd-second-brain decision 0017).')
param jumpboxAutoShutdownTime string = '2000'

@description('Keep the jumpbox running past its daily stop until this UTC time (yyyy-MM-ddTHH:mmZ), recorded on the avdlz-keep-running-until tag of the VM. Empty: the daily stop applies.')
param jumpboxKeepRunningUntil string = ''

@description('Password of the local account on the jumpbox. Random per deployment and applied only when the VM is created; nobody knows it. scripts/ops/Connect-AvdJumpbox.ps1 sets a one-time password on each connect.')
@secure()
param jumpboxAdminPassword string = newGuid()

@description('Enable Microsoft Defender for Cloud plans (Servers P2, Storage, Key Vault) on the subscription.')
param enableDefenderForCloud bool = true

@description('Deploy the subscription-wide pieces: the policy guardrails (when enablePolicyGuardrails) and the activity log export. One landing zone per subscription owns them; a second one beside it (parameters/test.bicepparam) sets this to false.')
param deploySubscriptionSettings bool = true

@description('Assign the landing zone\'s Azure Policy guardrails (allowed locations, tag inheritance) to the subscription.')
param enablePolicyGuardrails bool = true

@description('Recovery region (build/specs/recovery-spec.md): a second region the guardrails also allow, for restores and recovery tests. Empty: none, and the guardrails allow only location.')
param recoveryLocation string = ''

@description('Allowed regions for resources and resource groups when policy guardrails are on. The default is location plus recoveryLocation when set.')
param allowedLocations string[] = union([location], empty(recoveryLocation) ? [] : [recoveryLocation])

// =====================================================================
// Derived values
// =====================================================================
var cleanPrefix = toLower(replace(namePrefix, '-', ''))
// The same condition as the budget in modules/governance.bicep.
var deployBudget = monthlyBudgetAmount > 0 && !empty(budgetStartDate) && !empty(alertEmailAddresses)
var autoShutdownOnBudget = enableAutoShutdown && deployBudget && autoShutdownBudgetAction != 'None'
// Built-in roles for the runbook's identity (Microsoft's role definitions).
var roleIds = {
  desktopVirtualizationContributor: '082f0a83-3be5-4ba1-904c-961cca79b387'
  desktopVirtualizationPowerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
  tagContributor: '4a9ae827-6dc8-4573-8ac7-8239d42aa03f'
}
var baseName = '${cleanPrefix}-${environmentName}'
var uniq = uniqueString(subscription().id, cleanPrefix, environmentName, location)

var allTags = union(
  {
    workload: 'avd'
    environment: environmentName
    managedBy: 'bicep'
    landingZone: 'avd-cloud-native'
  },
  tags
)

var names = {
  rgNetwork: 'rg-${baseName}-network'
  rgManagement: 'rg-${baseName}-management'
  rgStorage: 'rg-${baseName}-storage'
  rgControlPlane: 'rg-${baseName}-avd'
  rgHosts: 'rg-${baseName}-hosts'
  rgJumpbox: 'rg-${baseName}-jumpbox'
  vnet: 'vnet-${baseName}'
  logAnalytics: 'log-${baseName}'
  keyVault: take('kv${cleanPrefix}${environmentName}${uniq}', 24)
  storage: take('st${cleanPrefix}${environmentName}${uniq}', 24)
  recoveryVault: 'rsv-${baseName}'
  hostPool: 'vdpool-${baseName}'
  appGroup: 'vdag-${baseName}-desktop'
  workspace: 'vdws-${baseName}'
  scalingPlan: 'vdscaling-${baseName}'
  bastion: 'bas-${baseName}'
  jumpbox: 'vm-${baseName}-jumpbox'
}

var profileShareName = 'profiles'
// Rotation (image pipeline spec section 6.1): the image and the names of this deployment's hosts.
var hostImageReference = empty(sessionHostImageId) ? sessionHostImage : { id: sessionHostImageId }
var hostNamePrefix = empty(sessionHostGeneration) ? sessionHostNamePrefix : '${take(sessionHostNamePrefix, 10)}${sessionHostGeneration}'
var rotationTagNames = [
  'avdlz-image'
  'avdlz-generation'
  'avdlz-image-next'
  'avdlz-image-previous'
  'avdlz-rotation'
]
var keptHostPoolStateTags = toObject(filter(items(hostPoolStateTags), t => contains(rotationTagNames, t.key) && !empty(t.value)), t => t.key, t => string(t.value))
var useCentralDns = !empty(centralPrivateDnsZoneResourceIds)

// =====================================================================
// 0. RESOURCE GROUPS — one per lifecycle
// =====================================================================
resource rgNetwork 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgNetwork
  location: location
  tags: allTags
}

resource rgManagement 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgManagement
  location: location
  tags: allTags
}

resource rgStorage 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgStorage
  location: location
  tags: allTags
}

resource rgControlPlane 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgControlPlane
  location: location
  tags: allTags
}

resource rgHosts 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.rgHosts
  location: location
  tags: allTags
}

resource rgJumpbox 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployJumpbox) {
  name: names.rgJumpbox
  location: location
  tags: allTags
}

// =====================================================================
// 1. GOVERNANCE — policy guardrails, Defender, budget, activity log
// =====================================================================
// Subscription-scope deployment names must be unique per subscription+region.
module governance 'modules/governance.bicep' = {
  name: take('avdlz-governance-${baseName}-${location}', 64)
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    enablePolicyGuardrails: enablePolicyGuardrails && deploySubscriptionSettings
    deployActivityLog: deploySubscriptionSettings
    allowedLocations: allowedLocations
    enableDefenderForCloud: enableDefenderForCloud
    monthlyBudgetAmount: monthlyBudgetAmount
    budgetStartDate: budgetStartDate
    alertEmailAddresses: alertEmailAddresses
    budgetActionGroupId: autoShutdownOnBudget ? autoShutdown!.outputs.budgetActionGroupId : ''
    budgetActionPercent: autoShutdownBudgetPercent
  }
}

// =====================================================================
// 2. MONITORING — Log Analytics, AVD Insights DCR, alerts
// =====================================================================
module monitoring 'modules/monitoring.bicep' = {
  name: 'avdlz-monitoring'
  scope: rgManagement
  params: {
    location: location
    tags: allTags
    baseName: baseName
    logAnalyticsName: names.logAnalytics
    retentionInDays: logRetentionDays
    alertEmailAddresses: alertEmailAddresses
  }
}

// =====================================================================
// 3. NETWORK — spoke, NSGs, explicit egress (NAT Gateway or hub firewall)
// =====================================================================
module network 'modules/network.bicep' = {
  name: 'avdlz-network'
  scope: rgNetwork
  params: {
    location: location
    tags: allTags
    vnetName: names.vnet
    addressPrefix: spokeAddressPrefix
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    connectivityMode: connectivityMode
    hubVnetResourceId: hubVnetResourceId
    createHubToSpokePeering: createHubToSpokePeering
    hubFirewallPrivateIp: hubFirewallPrivateIp
    dnsServers: dnsServers
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    availabilityZones: availabilityZones
    deployImageBuildSubnets: deployImageBuildSubnets
    imageBuildSubnetPrefix: imageBuildSubnetPrefix
    imageBuildAciSubnetPrefix: imageBuildAciSubnetPrefix
    deployJumpboxSubnet: deployJumpbox
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
  }
}

module privateDns 'modules/privateDns.bicep' = if (!useCentralDns) {
  name: 'avdlz-private-dns'
  scope: rgNetwork
  params: {
    tags: allTags
    vnetResourceId: network.outputs.vnetResourceId
  }
}

var dnsZoneIds = {
  file: useCentralDns ? centralPrivateDnsZoneResourceIds.file : privateDns!.outputs.fileZoneResourceId
  keyVault: useCentralDns ? centralPrivateDnsZoneResourceIds.keyVault : privateDns!.outputs.keyVaultZoneResourceId
  avd: useCentralDns ? (centralPrivateDnsZoneResourceIds.?avd ?? '') : privateDns!.outputs.avdZoneResourceId
}

// =====================================================================
// 4. KEY VAULT — break-glass credential, private only
// =====================================================================
module keyVault 'modules/keyVault.bicep' = {
  name: 'avdlz-keyvault'
  scope: rgManagement
  params: {
    location: location
    tags: allTags
    name: names.keyVault
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: dnsZoneIds.keyVault
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    adminsGroupObjectId: avdAdminsGroupObjectId
    localAdminUsername: localAdminUsername
    localAdminPassword: localAdminPassword
  }
}

// =====================================================================
// 5. PROFILE STORAGE — Premium Azure Files, Entra Kerberos, private only
// =====================================================================
module storage 'modules/storage.bicep' = {
  name: 'avdlz-storage'
  scope: rgStorage
  params: {
    location: location
    tags: allTags
    name: names.storage
    skuName: profileStorageSku
    shareName: profileShareName
    shareQuotaGiB: profileShareQuotaGiB
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: dnsZoneIds.file
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    usersGroupObjectId: avdUsersGroupObjectId
    adminsGroupObjectId: avdAdminsGroupObjectId
    // Microsoft's Azure Files backup support matrix: the vaulted tier needs key access on the source account.
    allowSharedKeyAccess: enableProfileBackup && profileBackupTier == 'Vaulted'
  }
}

module backup 'modules/backup.bicep' = if (enableProfileBackup) {
  name: 'avdlz-backup'
  scope: rgStorage
  params: {
    location: location
    tags: allTags
    vaultName: names.recoveryVault
    storageAccountResourceId: storage.outputs.resourceId
    shareName: profileShareName
    retentionDays: profileBackupRetentionDays
    profileBackupTier: profileBackupTier
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
  }
}

// =====================================================================
// 6. AVD CONTROL PLANE — host pool, app group, workspace, autoscale
// =====================================================================
module controlPlane 'modules/controlPlane.bicep' = {
  name: 'avdlz-control-plane'
  scope: rgControlPlane
  params: {
    location: location
    tags: allTags
    hostPoolName: names.hostPool
    appGroupName: names.appGroup
    workspaceName: names.workspace
    scalingPlanName: names.scalingPlan
    maxSessionLimit: maxSessionLimit
    rdpProperties: rdpProperties
    validationEnvironment: validationEnvironment
    enableAvdPrivateLink: enableAvdPrivateLink
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    avdPrivateDnsZoneResourceId: dnsZoneIds.avd
    scalingTimeZone: scalingTimeZone
    startVmOnConnect: startVmOnConnect
    hostPoolStateTags: keptHostPoolStateTags
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    usersGroupObjectId: avdUsersGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// =====================================================================
// 7. SESSION HOSTS — Entra joined, Intune enrolled, Trusted Launch,
//    registered to the host pool and FSLogix-configured declaratively
// =====================================================================
module sessionHosts 'modules/sessionHosts.bicep' = {
  name: 'avdlz-session-hosts'
  scope: rgHosts
  params: {
    location: location
    tags: allTags
    count: sessionHostCount
    namePrefix: hostNamePrefix
    vmSize: sessionHostVmSize
    availabilityZones: availabilityZones
    imageReference: hostImageReference
    encryptionAtHost: encryptionAtHost
    subnetResourceId: network.outputs.sessionHostSubnetResourceId
    enrollInIntune: enrollInIntune
    localAdminUsername: localAdminUsername
    localAdminPassword: localAdminPassword
    hostPoolRegistrationToken: controlPlane.outputs.registrationToken
    dataCollectionRuleResourceId: monitoring.outputs.avdInsightsDataCollectionRuleResourceId
    profileShareUncPath: storage.outputs.profileShareUncPath
    fslogixProfileSizeMiB: fslogixProfileSizeMiB
    usersGroupObjectId: avdUsersGroupObjectId
    adminsGroupObjectId: avdAdminsGroupObjectId
    avdServicePrincipalObjectId: avdServicePrincipalObjectId
  }
}

// =====================================================================
// 8. AUTO SHUTDOWN — runbook, schedule and budget triggers (decision 0011)
// =====================================================================
module autoShutdown 'modules/autoShutdown.bicep' = if (enableAutoShutdown) {
  name: 'avdlz-auto-shutdown'
  scope: rgManagement
  params: {
    location: location
    tags: allTags
    baseName: baseName
    namePrefix: cleanPrefix
    environmentName: environmentName
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    runbookUri: autoShutdownRunbookUri
    scheduleTime: autoShutdownTime
    scheduleDays: autoShutdownDays
    timeZone: autoShutdownTimeZone
    scheduleAction: autoShutdownScheduleAction
    budgetAction: autoShutdownOnBudget ? autoShutdownBudgetAction : 'None'
  }
}

// The runbook drains and updates the host pool, and deallocates and tags the hosts.
module autoShutdownRbacControlPlane 'modules/autoShutdownRbac.bicep' = if (enableAutoShutdown) {
  name: 'avdlz-auto-shutdown-rbac-avd'
  scope: rgControlPlane
  params: {
    principalId: autoShutdown!.outputs.principalId
    roleDefinitionIds: [
      roleIds.desktopVirtualizationContributor
    ]
  }
}

module autoShutdownRbacHosts 'modules/autoShutdownRbac.bicep' = if (enableAutoShutdown) {
  name: 'avdlz-auto-shutdown-rbac-hosts'
  scope: rgHosts
  params: {
    principalId: autoShutdown!.outputs.principalId
    roleDefinitionIds: [
      roleIds.desktopVirtualizationPowerOnOffContributor
      roleIds.tagContributor
    ]
  }
}

// =====================================================================
// 9. OPERATOR JUMPBOX — opt-in, through Bastion Developer (decision 0018)
// =====================================================================
module bastion 'modules/bastionDeveloper.bicep' = if (deployJumpbox) {
  name: 'avdlz-bastion'
  scope: rgNetwork
  params: {
    location: location
    tags: allTags
    name: names.bastion
    vnetResourceId: network.outputs.vnetResourceId
    adminsGroupObjectId: avdAdminsGroupObjectId
  }
}

module jumpbox 'modules/jumpbox.bicep' = if (deployJumpbox) {
  name: 'avdlz-jumpbox'
  scope: rgJumpbox
  params: {
    location: location
    tags: allTags
    vmName: names.jumpbox
    vmSize: jumpboxVmSize
    subnetResourceId: network.outputs.jumpboxSubnetResourceId
    encryptionAtHost: encryptionAtHost
    adminUsername: 'avdoperator'
    adminPassword: jumpboxAdminPassword
    autoShutdownTime: jumpboxAutoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    keepRunningUntil: jumpboxKeepRunningUntil
    adminsGroupObjectId: avdAdminsGroupObjectId
  }
}

// ---------- Outputs ----------
output resourceGroups object = {
  network: rgNetwork.name
  management: rgManagement.name
  storage: rgStorage.name
  controlPlane: rgControlPlane.name
  hosts: rgHosts.name
  jumpbox: deployJumpbox ? names.rgJumpbox : ''
}
output hostPoolResourceId string = controlPlane.outputs.hostPoolResourceId
output workspaceResourceId string = controlPlane.outputs.workspaceResourceId
output storageAccountName string = storage.outputs.name
output storageAccountResourceId string = storage.outputs.resourceId
output keyVaultName string = keyVault.outputs.name
output logAnalyticsWorkspaceResourceId string = monitoring.outputs.logAnalyticsWorkspaceResourceId
output sessionHostNames string[] = sessionHosts.outputs.names
output jumpboxName string = deployJumpbox ? names.jumpbox : ''
