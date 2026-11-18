// Lab: near-$0 standing footprint for nonproduction testing.
// Disables Private Link, backup, Defender, and jumpbox, and defaults sessionHostCount to 0
// (set AVD_SESSION_HOST_COUNT=1 when testing session hosts).
// Tenant-specific values come from environment variables (see docs/deploy.md).

using '../bicep/main.bicep'

param namePrefix = empty(readEnvironmentVariable('AVD_NAME_PREFIX', '')) ? 'avdlz' : readEnvironmentVariable('AVD_NAME_PREFIX', '')
param environmentName = 'dev'
param batchId = empty(readEnvironmentVariable('BATCH_ID', '')) ? readEnvironmentVariable('AVD_BATCH_ID', '') : readEnvironmentVariable('BATCH_ID', '')
param location = empty(readEnvironmentVariable('AVD_LOCATION', ''))
  ? 'northcentralus'
  : readEnvironmentVariable('AVD_LOCATION', '')
param recoveryLocation = readEnvironmentVariable('AVD_RECOVERY_LOCATION', '')
param cloud = empty(readEnvironmentVariable('AVD_CLOUD', '')) ? 'commercial' : readEnvironmentVariable('AVD_CLOUD', '')
param complianceProfile = empty(readEnvironmentVariable('AVD_COMPLIANCE_PROFILE', '')) ? (empty(readEnvironmentVariable('AVD_CLOUD', '')) || readEnvironmentVariable('AVD_CLOUD', '') == 'commercial' ? 'standard' : 'itar-cui') : readEnvironmentVariable('AVD_COMPLIANCE_PROFILE', '')

// ---- Identity (Entra ID) ----
param avdUsersGroupObjectId = readEnvironmentVariable('AVD_USERS_GROUP_ID')
param avdAdminsGroupObjectId = readEnvironmentVariable('AVD_ADMINS_GROUP_ID')
param avdServicePrincipalObjectId = readEnvironmentVariable('AVD_SERVICE_PRINCIPAL_ID')
param localAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD')

// ---- Connectivity ----
param connectivityMode = 'Standalone'
param enableAvdPrivateLink = false
param deployImageBuildSubnets = empty(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', '')) ? false : bool(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', ''))
param deployJumpbox = empty(readEnvironmentVariable('AVD_DEPLOY_JUMPBOX', '')) ? false : bool(readEnvironmentVariable('AVD_DEPLOY_JUMPBOX', ''))
param jumpboxKeepRunningUntil = readEnvironmentVariable('AVD_JUMPBOX_KEEP_RUNNING_UNTIL', '')
param jumpboxOs = toLower(readEnvironmentVariable('AVD_JUMPBOX_OS', '')) == 'windows' ? 'Windows' : 'Linux'
param jumpboxExists = empty(readEnvironmentVariable('AVD_JUMPBOX_EXISTS', '')) ? false : bool(readEnvironmentVariable('AVD_JUMPBOX_EXISTS', ''))

// ---- Session hosts ----
param availabilityZones = []
param sessionHostCount = empty(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', '')) ? 0 : int(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', ''))
param sessionHostVmSize = empty(readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')) ? 'Standard_E4as_v5' : readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')
param maxSessionLimit = empty(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', '')) ? 8 : int(readEnvironmentVariable('AVD_MAX_SESSION_LIMIT', ''))
param sessionHostImageId = readEnvironmentVariable('AVD_SESSION_HOST_IMAGE_ID', '')
param sessionHostGeneration = readEnvironmentVariable('AVD_SESSION_HOST_GENERATION', '')
param hostPoolStateTags = json(empty(readEnvironmentVariable('AVD_HOST_POOL_STATE_TAGS', '')) ? '{}' : readEnvironmentVariable('AVD_HOST_POOL_STATE_TAGS', ''))

// ---- Profiles ----
param profileStorageSku = 'Premium_LRS'
param profileShareQuotaGiB = empty(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', '')) ? 100 : int(readEnvironmentVariable('AVD_PROFILE_QUOTA_GIB', ''))
param enableProfileBackup = false

// ---- Operations & governance ----
param logRetentionDays = 30
param enableDefenderForCloud = false
param alertEmailAddresses = empty(readEnvironmentVariable('AVD_ALERT_EMAIL', ''))
  ? []
  : [readEnvironmentVariable('AVD_ALERT_EMAIL', '')]

// Budget (optional): set AVD_MONTHLY_BUDGET and AVD_ALERT_EMAIL before deploy.sh.
param monthlyBudgetAmount = empty(readEnvironmentVariable('AVD_MONTHLY_BUDGET', '')) ? 0 : int(readEnvironmentVariable('AVD_MONTHLY_BUDGET', ''))
param budgetStartDate = '2026-10-01'

// ---- Auto shutdown (decision 0011) ----
param autoShutdownRunbookUri = empty(readEnvironmentVariable('AVD_RUNBOOK_URI', ''))
  ? 'https://raw.githubusercontent.com/avd-ops/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1'
  : readEnvironmentVariable('AVD_RUNBOOK_URI', '')
param autoShutdownTime = empty(readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '')) ? '20:00' : (readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '') == 'none' ? '' : readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', ''))
param startVmOnConnect = empty(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', '')) ? true : bool(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', ''))
param autoShutdownTimeZone = 'Central Standard Time'

// ---- Multi-pool, workspaces, app groups, Private Link & DNS topology (optional) ----
param topology = json(empty(readEnvironmentVariable('AVD_TOPOLOGY_JSON', '')) ? '{}' : readEnvironmentVariable('AVD_TOPOLOGY_JSON', ''))

// ---- Estate tripwires (avd-swarm/docs/tripwires.md, optional) ----
param deployTripwires = empty(readEnvironmentVariable('AVD_DEPLOY_TRIPWIRES', '')) ? false : bool(readEnvironmentVariable('AVD_DEPLOY_TRIPWIRES', ''))
param tripwireSecretName = readEnvironmentVariable('AVD_TRIPWIRE_SECRET_NAME', '')
param tripwireAlertMinutes = readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '5' ? 5 : (readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '15' ? 15 : (readEnvironmentVariable('AVD_TRIPWIRE_ALERT_MINUTES', '') == '30' ? 30 : 0))
