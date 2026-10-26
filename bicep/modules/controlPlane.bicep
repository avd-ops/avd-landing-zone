// AVD control plane — primary and additional host pools, application groups,
// workspaces, autoscale plans, and AVD Private Link (connection, feed, global).
// Diagnostics from every object go to Log Analytics (that's what AVD Insights
// and the alerts read).

param location string
param tags object

@description('Rotation tags the host pool keeps across deployments (main.bicep hostPoolStateTags).')
param hostPoolStateTags object = {}
param hostPoolName string
param appGroupName string
param workspaceName string
param scalingPlanName string
param maxSessionLimit int
param rdpProperties string
param validationEnvironment bool
param enableAvdPrivateLink bool
param privateEndpointSubnetResourceId string
param avdPrivateDnsZoneResourceId string
param scalingTimeZone string
param logAnalyticsWorkspaceResourceId string
param usersGroupObjectId string
param avdServicePrincipalObjectId string

@description('Start a deallocated session host when a user connects. Off: hosts must already be running (the scaling plan starts them on weekdays). The host pool carries tag avdlz-start-vm-on-connect = false, so Resume after an auto-shutdown lock keeps it off.')
param startVmOnConnect bool = true

@description('Deploy the autoscale plan. The demo host pool turns this off so its host stays up while it is validated.')
param deployScalingPlan bool = true

@description('Resource group for the host pool private endpoint. Empty = the private endpoint subnet\'s resource group.')
param privateEndpointResourceGroupResourceId string = ''

@description('Optional per-pool overrides for the primary host pool from topology.hostPools[0].')
param primaryPool object = {}

@description('Optional overrides for the primary application group from topology.appGroups[0].')
param primaryAppGroup object = {}

@description('Optional overrides for the primary workspace from topology.workspaces[0].')
param primaryWorkspace object = {}

@description('Default publicNetworkAccess for host pools when Private Link is enabled.')
param defaultHostPoolPublicNetworkAccess string = 'EnabledForClientsOnly'

@description('Default publicNetworkAccess for workspaces.')
param defaultWorkspacePublicNetworkAccess string = 'Enabled'

@description('Enable workspace feed Private Link by default.')
param enableAvdFeedPrivateLink bool = false

@description('Enable workspace global Private Link on the primary workspace by default.')
param enableAvdGlobalPrivateLink bool = false

@description('Private DNS zone resource ID for privatelink-global.wvd.microsoft.com (used when global workspace Private Link is enabled).')
param avdGlobalPrivateDnsZoneResourceId string = ''

@description('Additional application groups beyond the primary one (topology.appGroups[1..]).')
param additionalAppGroups array = []

@description('Additional workspaces beyond the primary one (topology.workspaces[1..]).')
param additionalWorkspaces array = []

@description('Extra application group names (from additionalAppGroups) assigned to the primary workspace.')
param primaryWorkspaceExtraAppGroupNames string[] = []

var roles = {
  desktopVirtualizationUser: '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
  powerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
}
var diagnostics = [
  {
    workspaceResourceId: logAnalyticsWorkspaceResourceId
  }
]

var primaryPoolType = (primaryPool.?hostPoolType ?? 'Pooled') == 'Personal' ? 'Personal' : 'Pooled'
var primaryPersonalAssignment = (primaryPool.?personalDesktopAssignmentType ?? 'Automatic') == 'Direct' ? 'Direct' : 'Automatic'
var rawPrimaryLb = string(primaryPool.?loadBalancerType ?? (primaryPoolType == 'Personal' ? 'Persistent' : 'BreadthFirst'))
var primaryLbType = rawPrimaryLb == 'Persistent'
  ? 'Persistent'
  : (rawPrimaryLb == 'DepthFirst' ? 'DepthFirst' : 'BreadthFirst')
var rawPrimaryPrefAg = string(primaryPool.?preferredAppGroupType ?? 'Desktop')
var primaryPrefAgType = rawPrimaryPrefAg == 'RailApplications'
  ? 'RailApplications'
  : (rawPrimaryPrefAg == 'None' ? 'None' : 'Desktop')
var primaryMaxSessions = int(primaryPool.?maxSessionLimit ?? maxSessionLimit)
var primaryRdpProps = string(primaryPool.?rdpProperties ?? rdpProperties)
var primaryValidation = bool(primaryPool.?validationEnvironment ?? validationEnvironment)
var primaryStartOnConnect = bool(primaryPool.?startVmOnConnect ?? startVmOnConnect)
var primaryScalingTz = string(primaryPool.?scalingTimeZone ?? scalingTimeZone)
var primaryDeployScaling = bool(primaryPool.?deployScalingPlan ?? deployScalingPlan) && primaryPoolType == 'Pooled'
var primaryEnablePe = bool(primaryPool.?enablePrivateEndpoint ?? enableAvdPrivateLink) && !empty(avdPrivateDnsZoneResourceId)
var rawPrimaryHpAccess = string(primaryPool.?publicNetworkAccess ?? (primaryEnablePe ? defaultHostPoolPublicNetworkAccess : 'Enabled'))
var primaryHpAccess = rawPrimaryHpAccess == 'Disabled'
  ? 'Disabled'
  : (rawPrimaryHpAccess == 'EnabledForClientsOnly'
      ? 'EnabledForClientsOnly'
      : (rawPrimaryHpAccess == 'EnabledForSessionHostsOnly' ? 'EnabledForSessionHostsOnly' : 'Enabled'))
var primaryHpFriendlyName = string(primaryPool.?friendlyName ?? '')

// ---------- Host pool ----------
module hostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.8.1' = {
  name: 'host-pool'
  params: {
    name: hostPoolName
    location: location
    tags: union(tags, hostPoolStateTags, primaryStartOnConnect ? {} : { 'avdlz-start-vm-on-connect': 'false' })
    friendlyName: primaryHpFriendlyName
    hostPoolType: primaryPoolType
    personalDesktopAssignmentType: primaryPoolType == 'Personal' ? primaryPersonalAssignment : null
    loadBalancerType: primaryLbType
    preferredAppGroupType: primaryPrefAgType
    maxSessionLimit: primaryMaxSessions
    customRdpProperty: primaryRdpProps
    validationEnvironment: primaryValidation
    startVMOnConnect: primaryStartOnConnect
    // Registration token for this deployment's session hosts; short-lived on purpose.
    tokenValidityLength: 'PT4H'
    // Private Link: session hosts reach the service privately, users still
    // connect from anywhere over the public AVD gateway unless Disabled.
    publicNetworkAccess: primaryHpAccess
    privateEndpoints: primaryEnablePe
      ? [
          {
            subnetResourceId: privateEndpointSubnetResourceId
            resourceGroupResourceId: empty(privateEndpointResourceGroupResourceId) ? null : privateEndpointResourceGroupResourceId
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                {
                  privateDnsZoneResourceId: avdPrivateDnsZoneResourceId
                }
              ]
            }
          }
        ]
      : []
    agentUpdate: {
      type: 'Scheduled'
      useSessionHostLocalTime: true
      maintenanceWindows: [
        {
          dayOfWeek: 'Saturday'
          hour: 2
        }
      ]
    }
    diagnosticSettings: diagnostics
  }
}

var primaryAgType = (primaryAppGroup.?applicationGroupType ?? 'Desktop') == 'RemoteApp' ? 'RemoteApp' : 'Desktop'
var primaryAgFriendlyName = string(primaryAppGroup.?friendlyName ?? 'Desktop')
var primaryAgUsersGroup = !empty(primaryAppGroup.?usersGroupObjectId ?? '')
  ? string(primaryAppGroup.usersGroupObjectId)
  : usersGroupObjectId

// ---------- Primary application group ----------
module appGroup 'br/public:avm/res/desktop-virtualization/application-group:0.4.2' = {
  name: 'app-group'
  params: {
    name: appGroupName
    location: location
    tags: tags
    applicationGroupType: primaryAgType
    hostpoolName: hostPool.outputs.name
    friendlyName: primaryAgFriendlyName
    roleAssignments: [
      {
        principalId: primaryAgUsersGroup
        principalType: 'Group'
        roleDefinitionIdOrName: roles.desktopVirtualizationUser
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// ---------- Additional application groups ----------
module extraAppGroups 'br/public:avm/res/desktop-virtualization/application-group:0.4.2' = [
  for (ag, i) in additionalAppGroups: {
    name: take('ag-${ag.name}', 64)
    params: {
      name: string(ag.name)
      location: location
      tags: tags
      applicationGroupType: (ag.?applicationGroupType ?? 'Desktop') == 'RemoteApp' ? 'RemoteApp' : 'Desktop'
      hostpoolName: !empty(ag.?hostPoolName ?? '') ? string(ag.hostPoolName) : hostPool.outputs.name
      friendlyName: string(ag.?friendlyName ?? ag.name)
      roleAssignments: [
        {
          principalId: !empty(ag.?usersGroupObjectId ?? '') ? string(ag.usersGroupObjectId) : usersGroupObjectId
          principalType: 'Group'
          roleDefinitionIdOrName: roles.desktopVirtualizationUser
        }
      ]
      diagnosticSettings: diagnostics
    }
  }
]

var primaryWsFeedPe = bool(primaryWorkspace.?enableFeedPrivateEndpoint ?? enableAvdFeedPrivateLink) && !empty(avdPrivateDnsZoneResourceId)
var primaryWsGlobalPe = bool(primaryWorkspace.?enableGlobalPrivateEndpoint ?? enableAvdGlobalPrivateLink) && !empty(avdGlobalPrivateDnsZoneResourceId)
var rawPrimaryWsAccess = string(primaryWorkspace.?publicNetworkAccess ?? (primaryWsFeedPe ? (defaultWorkspacePublicNetworkAccess == 'Enabled' ? 'Disabled' : defaultWorkspacePublicNetworkAccess) : defaultWorkspacePublicNetworkAccess))
var primaryWsAccess = rawPrimaryWsAccess == 'Disabled'
  ? 'Disabled'
  : (rawPrimaryWsAccess == 'EnabledForClientsOnly'
      ? 'EnabledForClientsOnly'
      : (rawPrimaryWsAccess == 'EnabledForSessionHostsOnly' ? 'EnabledForSessionHostsOnly' : 'Enabled'))
var primaryWsFriendlyName = string(primaryWorkspace.?friendlyName ?? '')
var primaryWsExtraAgIds = [
  for agName in primaryWorkspaceExtraAppGroupNames: resourceId('Microsoft.DesktopVirtualization/applicationGroups', agName)
]
var primaryWsFeedEndpoints = primaryWsFeedPe
  ? [
      {
        name: 'pe-${workspaceName}-feed'
        service: 'feed'
        subnetResourceId: privateEndpointSubnetResourceId
        resourceGroupResourceId: empty(privateEndpointResourceGroupResourceId) ? null : privateEndpointResourceGroupResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: avdPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  : []
var primaryWsGlobalEndpoints = primaryWsGlobalPe
  ? [
      {
        name: 'pe-${workspaceName}-global'
        service: 'global'
        subnetResourceId: privateEndpointSubnetResourceId
        resourceGroupResourceId: empty(privateEndpointResourceGroupResourceId) ? null : privateEndpointResourceGroupResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: avdGlobalPrivateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  : []

// ---------- Primary workspace ----------
module workspace 'br/public:avm/res/desktop-virtualization/workspace:0.9.2' = {
  name: 'workspace'
  dependsOn: [
    extraAppGroups
  ]
  params: {
    name: workspaceName
    location: location
    tags: tags
    friendlyName: primaryWsFriendlyName
    applicationGroupReferences: union(
      [
        appGroup.outputs.resourceId
      ],
      primaryWsExtraAgIds
    )
    publicNetworkAccess: primaryWsAccess
    privateEndpoints: concat(primaryWsFeedEndpoints, primaryWsGlobalEndpoints)
    diagnosticSettings: diagnostics
  }
}

// ---------- Additional workspaces ----------
module extraWorkspaces 'br/public:avm/res/desktop-virtualization/workspace:0.9.2' = [
  for (ws, i) in additionalWorkspaces: {
    name: take('ws-${ws.name}', 64)
    dependsOn: [
      appGroup
      extraAppGroups
    ]
    params: {
      name: string(ws.name)
      location: location
      tags: tags
      friendlyName: string(ws.?friendlyName ?? ws.name)
      applicationGroupReferences: map(
        ws.?appGroupNames ?? [],
        agName => resourceId('Microsoft.DesktopVirtualization/applicationGroups', string(agName))
      )
      publicNetworkAccess: (ws.?publicNetworkAccess ?? defaultWorkspacePublicNetworkAccess) == 'Disabled'
        ? 'Disabled'
        : ((ws.?publicNetworkAccess ?? defaultWorkspacePublicNetworkAccess) == 'EnabledForClientsOnly'
            ? 'EnabledForClientsOnly'
            : ((ws.?publicNetworkAccess ?? defaultWorkspacePublicNetworkAccess) == 'EnabledForSessionHostsOnly'
                ? 'EnabledForSessionHostsOnly'
                : (bool(ws.?enableFeedPrivateEndpoint ?? enableAvdFeedPrivateLink) ? 'Disabled' : 'Enabled')))
      privateEndpoints: concat(
        (bool(ws.?enableFeedPrivateEndpoint ?? enableAvdFeedPrivateLink) && !empty(avdPrivateDnsZoneResourceId))
          ? [
              {
                name: 'pe-${ws.name}-feed'
                service: 'feed'
                subnetResourceId: privateEndpointSubnetResourceId
                resourceGroupResourceId: empty(privateEndpointResourceGroupResourceId) ? null : privateEndpointResourceGroupResourceId
                privateDnsZoneGroup: {
                  privateDnsZoneGroupConfigs: [
                    {
                      privateDnsZoneResourceId: avdPrivateDnsZoneResourceId
                    }
                  ]
                }
              }
            ]
          : [],
        (bool(ws.?enableGlobalPrivateEndpoint ?? false) && !empty(avdGlobalPrivateDnsZoneResourceId))
          ? [
              {
                name: 'pe-${ws.name}-global'
                service: 'global'
                subnetResourceId: privateEndpointSubnetResourceId
                resourceGroupResourceId: empty(privateEndpointResourceGroupResourceId) ? null : privateEndpointResourceGroupResourceId
                privateDnsZoneGroup: {
                  privateDnsZoneGroupConfigs: [
                    {
                      privateDnsZoneResourceId: avdGlobalPrivateDnsZoneResourceId
                    }
                  ]
                }
              }
            ]
          : []
      )
      diagnosticSettings: diagnostics
    }
  }
]

// ---------- Autoscale ----------
// Weekdays: ramp up 07:00, peak 09:00, ramp down 18:00, off-peak 20:00.
// Weekends: off-peak all day; Start VM on Connect brings a host up on demand.
module scalingPlan 'br/public:avm/res/desktop-virtualization/scaling-plan:0.5.0' = if (primaryDeployScaling) {
  name: 'scaling-plan'
  params: {
    name: scalingPlanName
    location: location
    tags: tags
    hostPoolType: 'Pooled'
    timeZone: primaryScalingTz
    exclusionTag: 'avd-scaling-exclude'
    schedules: [
      {
        name: 'weekdays'
        daysOfWeek: [
          'Monday'
          'Tuesday'
          'Wednesday'
          'Thursday'
          'Friday'
        ]
        rampUpStartTime: { hour: 7, minute: 0 }
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: 20
        rampUpCapacityThresholdPct: 60
        peakStartTime: { hour: 9, minute: 0 }
        peakLoadBalancingAlgorithm: 'BreadthFirst'
        rampDownStartTime: { hour: 18, minute: 0 }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 10
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'This session host is being shut down to save cost. Please save your work and sign out.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: { hour: 20, minute: 0 }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
      {
        name: 'weekends'
        daysOfWeek: [
          'Saturday'
          'Sunday'
        ]
        rampUpStartTime: { hour: 9, minute: 0 }
        rampUpLoadBalancingAlgorithm: 'DepthFirst'
        rampUpMinimumHostsPct: 0
        rampUpCapacityThresholdPct: 90
        peakStartTime: { hour: 10, minute: 0 }
        peakLoadBalancingAlgorithm: 'DepthFirst'
        rampDownStartTime: { hour: 16, minute: 0 }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 0
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'This session host is being shut down to save cost. Please save your work and sign out.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: { hour: 18, minute: 0 }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolResourceId: hostPool.outputs.resourceId
        scalingPlanEnabled: true
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// The AVD service principal also needs Power On Off Contributor where the
// host pool lives (the session-host resource group is covered in sessionHosts.bicep).
resource powerOnOffOnControlPlane 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, avdServicePrincipalObjectId, roles.powerOnOffContributor)
  properties: {
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.powerOnOffContributor)
  }
}

output hostPoolResourceId string = hostPool.outputs.resourceId
output hostPoolName string = hostPool.outputs.name
output workspaceResourceId string = workspace.outputs.resourceId
output appGroupResourceId string = appGroup.outputs.resourceId

@secure()
output registrationToken string = hostPool.outputs.registrationToken!
