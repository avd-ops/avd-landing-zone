// Additional AVD host pool and optional autoscale plan (when topology.hostPools defines more than one pool).
// Deployed in the control-plane resource group alongside the primary host pool; outputs its
// registrationToken so main.bicep can register that pool's session hosts.

param location string
param tags object
param baseName string
param pool object
param defaultMaxSessionLimit int = 8
param defaultRdpProperties string
param defaultValidationEnvironment bool = false
param defaultStartVmOnConnect bool = true
param defaultScalingTimeZone string = 'UTC'
param defaultEnableAvdPrivateLink bool = true
param defaultPublicNetworkAccess string = 'EnabledForClientsOnly'
param privateEndpointSubnetResourceId string
param privateEndpointResourceGroupResourceId string = ''
param avdPrivateDnsZoneResourceId string = ''
param logAnalyticsWorkspaceResourceId string

var diagnostics = [
  {
    workspaceResourceId: logAnalyticsWorkspaceResourceId
  }
]

var rawName = string(pool.?name ?? 'pool')
var hostPoolName = startsWith(rawName, 'vdpool-') ? rawName : 'vdpool-${baseName}-${rawName}'
var scalingPlanName = startsWith(rawName, 'vdpool-')
  ? replace(rawName, 'vdpool-', 'vdscaling-')
  : 'vdscaling-${baseName}-${rawName}'
var hostPoolType = (pool.?hostPoolType ?? 'Pooled') == 'Personal' ? 'Personal' : 'Pooled'
var personalAssignmentType = (pool.?personalDesktopAssignmentType ?? 'Automatic') == 'Direct' ? 'Direct' : 'Automatic'
var rawLbType = string(pool.?loadBalancerType ?? (hostPoolType == 'Personal' ? 'Persistent' : 'BreadthFirst'))
var loadBalancerType = rawLbType == 'Persistent'
  ? 'Persistent'
  : (rawLbType == 'DepthFirst' ? 'DepthFirst' : 'BreadthFirst')
var rawPrefAppGroup = string(pool.?preferredAppGroupType ?? 'Desktop')
var preferredAppGroupType = rawPrefAppGroup == 'RailApplications'
  ? 'RailApplications'
  : (rawPrefAppGroup == 'None' ? 'None' : 'Desktop')
var maxSessionLimit = int(pool.?maxSessionLimit ?? defaultMaxSessionLimit)
var rdpProperties = string(pool.?rdpProperties ?? defaultRdpProperties)
var validationEnvironment = bool(pool.?validationEnvironment ?? defaultValidationEnvironment)
var startVmOnConnect = bool(pool.?startVmOnConnect ?? defaultStartVmOnConnect)
var scalingTimeZone = string(pool.?scalingTimeZone ?? defaultScalingTimeZone)
var deployScalingPlan = bool(pool.?deployScalingPlan ?? true) && hostPoolType == 'Pooled'
var enablePe = bool(pool.?enablePrivateEndpoint ?? defaultEnableAvdPrivateLink) && !empty(avdPrivateDnsZoneResourceId)
var rawPubAccess = string(pool.?publicNetworkAccess ?? (enablePe ? defaultPublicNetworkAccess : 'Enabled'))
var publicNetworkAccess = rawPubAccess == 'Disabled'
  ? 'Disabled'
  : (rawPubAccess == 'EnabledForClientsOnly'
      ? 'EnabledForClientsOnly'
      : (rawPubAccess == 'EnabledForSessionHostsOnly' ? 'EnabledForSessionHostsOnly' : 'Enabled'))
var friendlyName = string(pool.?friendlyName ?? '')

module hostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.8.1' = {
  name: take('hp-${hostPoolName}', 64)
  params: {
    name: hostPoolName
    location: location
    tags: union(tags, startVmOnConnect ? {} : { 'avdlz-start-vm-on-connect': 'false' })
    friendlyName: friendlyName
    hostPoolType: hostPoolType
    personalDesktopAssignmentType: hostPoolType == 'Personal' ? personalAssignmentType : null
    loadBalancerType: loadBalancerType
    preferredAppGroupType: preferredAppGroupType
    maxSessionLimit: maxSessionLimit
    customRdpProperty: rdpProperties
    validationEnvironment: validationEnvironment
    startVMOnConnect: startVmOnConnect
    tokenValidityLength: 'PT4H'
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: enablePe
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

module scalingPlan 'br/public:avm/res/desktop-virtualization/scaling-plan:0.5.0' = if (deployScalingPlan) {
  name: take('sp-${scalingPlanName}', 64)
  params: {
    name: scalingPlanName
    location: location
    tags: tags
    hostPoolType: 'Pooled'
    timeZone: scalingTimeZone
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

output hostPoolResourceId string = hostPool.outputs.resourceId
output hostPoolName string = hostPool.outputs.name

@secure()
output registrationToken string = hostPool.outputs.registrationToken!
