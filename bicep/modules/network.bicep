// Network — the AVD spoke.
//
// Both subnets are created with default outbound access OFF, so egress is
// always explicit:
//   - Standalone: NAT Gateway on the session host subnet. No hub needed.
//   - HubPeered:  peered to an existing hub (both directions), 0.0.0.0/0
//                 routed to the hub firewall, DNS from the hub.
// The private endpoint subnet enforces NSG rules on its endpoints.
// Optionally (deployImageBuildSubnets), two subnets for the golden image build
// (build/specs/image-pipeline-spec.md): the Azure Image Builder build VM, and the
// container instance that drives an isolated build. Same egress as the hosts.
// Optionally (deployJumpboxSubnet), the operator jumpbox's subnet (decision 0019): reached only
// through Azure Bastion Developer, which needs the jumpbox in this VNet. Same egress as the hosts.

param location string
param tags object
param vnetName string
param addressPrefix string
param sessionHostSubnetPrefix string
param privateEndpointSubnetPrefix string

@allowed([
  'Standalone'
  'HubPeered'
])
param connectivityMode string
param hubVnetResourceId string
param createHubToSpokePeering bool
param hubFirewallPrivateIp string
param dnsServers array
param logAnalyticsWorkspaceResourceId string

@description('The landing zone\'s availability zones. Empty = the region has none (or regional deployment): the NAT Gateway public IP gets no zones.')
param availabilityZones int[] = []

@description('Add the image build subnets (snet-image-build, snet-image-aci) for the golden image pipeline. Only the build environment needs them.')
param deployImageBuildSubnets bool = false

@description('Image build VM subnet (a /27 in the spoke\'s free range).')
param imageBuildSubnetPrefix string = '10.100.2.128/27'

@description('Image build container subnet, delegated to Azure Container Instances (a /27).')
param imageBuildAciSubnetPrefix string = '10.100.2.160/27'

@description('Add the operator jumpbox subnet (snet-jumpbox, decision 0019).')
param deployJumpboxSubnet bool = false

@description('Jumpbox subnet (a /28 in the spoke\'s free range).')
param jumpboxSubnetPrefix string = '10.100.2.32/28'

var isHub = connectivityMode == 'HubPeered'
var useRouteTable = isHub && !empty(hubFirewallPrivateIp)
var diagnostics = [
  {
    workspaceResourceId: logAnalyticsWorkspaceResourceId
  }
]

// ---------- NSGs ----------
module sessionHostNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-session-hosts'
  params: {
    name: 'nsg-${vnetName}-hosts'
    location: location
    tags: tags
    // Session hosts accept no inbound connections (AVD uses reverse connect) and
    // may not RDP/SSH to anything else in the network (no lateral movement).
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-VirtualNetwork-RDP-SSH-Outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

module privateEndpointNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'nsg-private-endpoints'
  params: {
    name: 'nsg-${vnetName}-pe'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Allow-SessionHosts-SMB'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: sessionHostSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '445'
        }
      }
      {
        name: 'Allow-VirtualNetwork-HTTPS'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-VirtualNetwork-RDP-SSH-Outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// Image build subnets: no inbound from the internet; the build container reaches the
// build VM over WinRM (5986) and SSH (22) inside the VNet. Verify the ports against a
// real isolated build (build/specs/image-pipeline-spec.md section 11).
module imageBuildNsg 'br/public:avm/res/network/network-security-group:0.5.3' = if (deployImageBuildSubnets) {
  name: 'nsg-image-build'
  params: {
    name: 'nsg-${vnetName}-image-build'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Allow-BuildContainer-To-BuildVm'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: imageBuildAciSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: imageBuildSubnetPrefix
          destinationPortRanges: [
            '22'
            '5986'
          ]
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// Jumpbox subnet (decision 0019): no public IP and nothing from the internet. Bastion Developer
// reaches the jumpbox over the VNet (the default AllowVnetInBound rule), so the subnet needs no
// rule of its own for it. Like the hosts, the jumpbox may not RDP or SSH onward (it manages the
// hosts through Azure: Run Command, not a session).
module jumpboxNsg 'br/public:avm/res/network/network-security-group:0.5.3' = if (deployJumpboxSubnet) {
  name: 'nsg-jumpbox'
  params: {
    name: 'nsg-${vnetName}-jumpbox'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-VirtualNetwork-RDP-SSH-Outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
    ]
    diagnosticSettings: diagnostics
  }
}

// ---------- Egress ----------
module natGateway 'br/public:avm/res/network/nat-gateway:2.1.1' = if (!isHub) {
  name: 'nat-gateway'
  params: {
    name: 'ng-${vnetName}'
    location: location
    tags: tags
    availabilityZone: -1
    publicIPAddresses: [
      {
        name: 'pip-ng-${vnetName}'
        // The module defaults this IP to zones 1-3, which fails in regions without
        // availability zones (e.g. North Central US). Zone-redundant only when zonal.
        availabilityZones: empty(availabilityZones) ? [] : [1, 2, 3]
      }
    ]
  }
}

module routeTable 'br/public:avm/res/network/route-table:0.5.0' = if (useRouteTable) {
  name: 'route-table'
  params: {
    name: 'rt-${vnetName}-hosts'
    location: location
    tags: tags
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-via-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: hubFirewallPrivateIp
        }
      }
    ]
  }
}

// ---------- VNet ----------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [
      addressPrefix
    ]
    dnsServers: dnsServers
    subnets: concat([
      {
        name: 'snet-session-hosts'
        addressPrefix: sessionHostSubnetPrefix
        defaultOutboundAccess: false
        networkSecurityGroupResourceId: sessionHostNsg.outputs.resourceId
        natGatewayResourceId: isHub ? null : natGateway!.outputs.resourceId
        routeTableResourceId: useRouteTable ? routeTable!.outputs.resourceId : null
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
        defaultOutboundAccess: false
        networkSecurityGroupResourceId: privateEndpointNsg.outputs.resourceId
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
      }
    ], deployImageBuildSubnets
      ? [
          {
            name: 'snet-image-build'
            addressPrefix: imageBuildSubnetPrefix
            defaultOutboundAccess: false
            networkSecurityGroupResourceId: imageBuildNsg!.outputs.resourceId
            natGatewayResourceId: isHub ? null : natGateway!.outputs.resourceId
            routeTableResourceId: useRouteTable ? routeTable!.outputs.resourceId : null
          }
          {
            name: 'snet-image-aci'
            addressPrefix: imageBuildAciSubnetPrefix
            defaultOutboundAccess: false
            networkSecurityGroupResourceId: imageBuildNsg!.outputs.resourceId
            natGatewayResourceId: isHub ? null : natGateway!.outputs.resourceId
            routeTableResourceId: useRouteTable ? routeTable!.outputs.resourceId : null
            delegation: 'Microsoft.ContainerInstance/containerGroups'
          }
        ]
      : [], deployJumpboxSubnet
      ? [
          {
            name: 'snet-jumpbox'
            addressPrefix: jumpboxSubnetPrefix
            defaultOutboundAccess: false
            networkSecurityGroupResourceId: jumpboxNsg!.outputs.resourceId
            natGatewayResourceId: isHub ? null : natGateway!.outputs.resourceId
            routeTableResourceId: useRouteTable ? routeTable!.outputs.resourceId : null
          }
        ]
      : [])
    peerings: isHub
      ? [
          {
            remoteVirtualNetworkResourceId: hubVnetResourceId
            allowForwardedTraffic: true
            allowVirtualNetworkAccess: true
            useRemoteGateways: false
            remotePeeringEnabled: createHubToSpokePeering
            remotePeeringAllowForwardedTraffic: true
            remotePeeringAllowVirtualNetworkAccess: true
          }
        ]
      : []
    diagnosticSettings: diagnostics
  }
}

output vnetResourceId string = vnet.outputs.resourceId
output sessionHostSubnetResourceId string = vnet.outputs.subnetResourceIds[0]
output privateEndpointSubnetResourceId string = vnet.outputs.subnetResourceIds[1]
output imageBuildSubnetResourceId string = deployImageBuildSubnets ? vnet.outputs.subnetResourceIds[2] : ''
output imageBuildAciSubnetResourceId string = deployImageBuildSubnets ? vnet.outputs.subnetResourceIds[3] : ''
// The jumpbox subnet comes after the image build subnets when both are there.
output jumpboxSubnetResourceId string = deployJumpboxSubnet ? vnet.outputs.subnetResourceIds[deployImageBuildSubnets ? 4 : 2] : ''
