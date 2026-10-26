// Private DNS — creates local privatelink zones and links them to the spoke.
// Each zone can be created locally or skipped when an existing zone resource ID
// is supplied via centralPrivateDnsZoneResourceIds or topology.privateLink.dnsZones.

param tags object
param vnetResourceId string
param deployFileZone bool = true
param deployKeyVaultZone bool = true
param deployAvdZone bool = true
param deployAvdGlobalZone bool = false

// Key Vault's privatelink zone follows the cloud's vault DNS suffix
// (e.g. .vault.azure.net -> privatelink.vaultcore.azure.net).
var keyVaultZone = 'privatelink${replace(environment().suffixes.keyvaultDns, '.vault.', '.vaultcore.')}'

// The AVD zone is created by default even if AVD Private Link is off, so turning
// it on later is a parameter change rather than a DNS change. The global AVD zone
// (privatelink-global.wvd.microsoft.com) is created when the global workspace
// private endpoint is enabled.
var zones = [
  'privatelink.file.${environment().suffixes.storage}'
  keyVaultZone
  'privatelink.wvd.microsoft.com'
  'privatelink-global.wvd.microsoft.com'
]

var enabled = [
  deployFileZone
  deployKeyVaultZone
  deployAvdZone
  deployAvdGlobalZone
]

module zone 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for (z, i) in zones: if (enabled[i]) {
    name: 'pdns-${z}'
    params: {
      name: z
      tags: tags
      virtualNetworkLinks: [
        {
          virtualNetworkResourceId: vnetResourceId
          registrationEnabled: false
        }
      ]
    }
  }
]

output fileZoneResourceId string = deployFileZone ? zone[0]!.outputs.resourceId : ''
output keyVaultZoneResourceId string = deployKeyVaultZone ? zone[1]!.outputs.resourceId : ''
output avdZoneResourceId string = deployAvdZone ? zone[2]!.outputs.resourceId : ''
output avdGlobalZoneResourceId string = deployAvdGlobalZone ? zone[3]!.outputs.resourceId : ''
