// Prod: zone-redundant, backed up, Defender on, budget set.
// Tenant-specific values come from environment variables (see docs/deploy.md).

using '../bicep/main.bicep'

param namePrefix = 'avdlz'
param environmentName = 'prod'
// Default region; deploy.sh -l and the preflight's -Location override it (AVD_LOCATION).
param location = empty(readEnvironmentVariable('AVD_LOCATION', ''))
  ? 'northcentralus'
  : readEnvironmentVariable('AVD_LOCATION', '')
// Recovery region the guardrails also allow (build/specs/recovery-spec.md); empty: none.
param recoveryLocation = readEnvironmentVariable('AVD_RECOVERY_LOCATION', '')

// ---- Identity (Entra ID) ----
param avdUsersGroupObjectId = readEnvironmentVariable('AVD_USERS_GROUP_ID')
param avdAdminsGroupObjectId = readEnvironmentVariable('AVD_ADMINS_GROUP_ID')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_ID')
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---- Connectivity ----
// Standalone by default. To join an existing hub instead:
//   param connectivityMode = 'HubPeered'
//   param hubVnetResourceId = '/subscriptions/<hub-sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<hub>'
//   param hubFirewallPrivateIp = '10.0.0.4'
//   param dnsServers = ['10.0.0.4']
//   param centralPrivateDnsZoneResourceIds = { file: '...', keyVault: '...', avd: '...' }
param connectivityMode = 'Standalone'
param spokeAddressPrefix = '10.100.0.0/22'
param sessionHostSubnetPrefix = '10.100.0.0/23'
param privateEndpointSubnetPrefix = '10.100.2.0/27'
// Golden image build subnets (build/specs/image-pipeline-spec.md): only in the image build environment.
// AVD_IMAGE_BUILD_SUBNETS=true adds them (empty = off).
param deployImageBuildSubnets = empty(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', '')) ? false : bool(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', ''))
// Operator jumpbox through Bastion Developer (decision 0019), off by default: deploy.sh --jumpbox sets
// AVD_DEPLOY_JUMPBOX=true, and --jumpbox-keep-running <yyyy-MM-ddTHH:mmZ> skips its daily stop until then
// (empty = off and the daily stop; lesson 0004).
param deployJumpbox = empty(readEnvironmentVariable('AVD_DEPLOY_JUMPBOX', '')) ? false : bool(readEnvironmentVariable('AVD_DEPLOY_JUMPBOX', ''))
param jumpboxKeepRunningUntil = readEnvironmentVariable('AVD_JUMPBOX_KEEP_RUNNING_UNTIL', '')
// --jumpbox-os windows: Windows Server instead of Linux (AVD_JUMPBOX_OS)
param jumpboxOs = toLower(readEnvironmentVariable('AVD_JUMPBOX_OS', '')) == 'windows' ? 'Windows' : 'Linux'
// deploy.sh sets AVD_JUMPBOX_EXISTS when the VM already exists, so it isn't re-sent (decision 0019)
param jumpboxExists = empty(readEnvironmentVariable('AVD_JUMPBOX_EXISTS', '')) ? false : bool(readEnvironmentVariable('AVD_JUMPBOX_EXISTS', ''))

// ---- Session hosts ----
// Sizing: the deployment portal's sizing step, deploy.sh (--hosts, --vm-size, --max-sessions,
// --profile-quota) and the pre-deployment preflight override these through AVD_SESSION_HOST_COUNT,
// AVD_SESSION_HOST_VM_SIZE, AVD_MAX_SESSION_LIMIT and AVD_PROFILE_QUOTA_GIB (empty = the value here).
param sessionHostCount = empty(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', '')) ? 4 : int(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', ''))
param sessionHostVmSize = empty(readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')) ? 'Standard_E4as_v5' : readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')
// Regional hosts work in every region (North Central US has no zones) and profiles
// use locally redundant storage. For zone redundancy, use a zonal region (e.g.
// centralus) with availabilityZones = [1, 2, 3] and profileStorageSku = 'Premium_ZRS'.
param availabilityZones = []
param maxSessionLimit = empty(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', '')) ? 8 : int(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', ''))
// Image and generation (build/specs/image-pipeline-spec.md section 6.1): deploy.sh --image-id and
// --generation, or the host pool's avdlz-image and avdlz-generation tags when the flags are absent, so a
// deployment never changes the image or the host names by itself. Empty: the marketplace image, original names.
param sessionHostImageId = readEnvironmentVariable('AVD_SESSION_HOST_IMAGE_ID', '')
param sessionHostGeneration = readEnvironmentVariable('AVD_SESSION_HOST_GENERATION', '')
// The rotation tags the host pool already carries, kept across deployments (deploy.sh reads them).
param hostPoolStateTags = json(empty(readEnvironmentVariable('AVD_HOST_POOL_STATE_TAGS', '')) ? '{}' : readEnvironmentVariable('AVD_HOST_POOL_STATE_TAGS', ''))

// ---- Profiles ----
param profileStorageSku = 'Premium_LRS'
param profileShareQuotaGiB = empty(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', '')) ? 1024 : int(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', ''))
param enableProfileBackup = true
param profileBackupRetentionDays = 30

// ---- Scaling ----
param scalingTimeZone = 'Central Standard Time'

// ---- Operations & governance ----
param logRetentionDays = 90
param enableDefenderForCloud = true
param enablePolicyGuardrails = true
param alertEmailAddresses = empty(readEnvironmentVariable('AVD_ALERT_EMAIL', ''))
  ? []
  : [readEnvironmentVariable('AVD_ALERT_EMAIL', '')]
param monthlyBudgetAmount = empty(readEnvironmentVariable('AVD_MONTHLY_BUDGET', '')) ? 0 : int(readEnvironmentVariable('AVD_MONTHLY_BUDGET', ''))
param budgetStartDate = '2026-10-01'

// ---- Auto shutdown (decision 0011) ----
// deploy.sh pins the runbook to the commit being deployed (AVD_RUNBOOK_URI).
param autoShutdownRunbookUri = empty(readEnvironmentVariable('AVD_RUNBOOK_URI', ''))
  ? 'https://raw.githubusercontent.com/avd-ops/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1'
  : readEnvironmentVariable('AVD_RUNBOOK_URI', '')
// Prod relies on the scaling plan for daily scale-down; a budget alert locks the hosts
// (autoShutdownBudgetAction = 'Lock', the default) until someone runs Resume.
// No scheduled stop by default. The deployment portal's Cost step and deploy.sh (--auto-shutdown
// HH:mm | none, --start-vm-on-connect true | false) set one and Start VM on Connect through
// AVD_AUTO_SHUTDOWN_TIME and AVD_START_VM_ON_CONNECT (empty = the value here; 'none' = no scheduled stop).
param autoShutdownTime = empty(readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '')) || readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '') == 'none' ? '' : readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '')
param startVmOnConnect = empty(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', '')) ? true : bool(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', ''))

// ---- Multi-pool, workspaces, app groups, Private Link & DNS topology (optional) ----
param topology = json(empty(readEnvironmentVariable('AVD_TOPOLOGY_JSON', '')) ? '{}' : readEnvironmentVariable('AVD_TOPOLOGY_JSON', ''))
