// Test: the dev footprint as a second landing zone in the same subscription, beside dev
// (a live demo deployment next to a working one; docs/demo.md). Its resources are named
// avdlz-test and its session hosts avdlztsh-*, so nothing collides with dev.
// Dev owns the subscription-wide pieces (policy guardrails, activity log export), so this
// file leaves them alone: deploySubscriptionSettings = false.
// Tenant-specific values come from environment variables (see docs/deploy.md),
// so this file is safe to commit. deploy.sh sets them for you.

using '../bicep/main.bicep'

param namePrefix = 'avdlz'
param environmentName = 'test'
param deploySubscriptionSettings = false
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
param connectivityMode = 'Standalone'
// Golden image build subnets (build/specs/image-pipeline-spec.md): only in the image build environment.
// AVD_IMAGE_BUILD_SUBNETS=true adds them (empty = off).
param deployImageBuildSubnets = empty(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', '')) ? false : bool(readEnvironmentVariable('AVD_IMAGE_BUILD_SUBNETS', ''))

// ---- Session hosts ----
// Regional hosts (no zones) work in every region, including those without
// availability zones such as North Central US.
param availabilityZones = []
// Sizing: the deployment portal's sizing step, deploy.sh (--hosts, --vm-size, --max-sessions,
// --profile-quota) and the pre-deployment preflight override these through AVD_SESSION_HOST_COUNT,
// AVD_SESSION_HOST_VM_SIZE, AVD_MAX_SESSION_LIMIT and AVD_PROFILE_QUOTA_GIB (empty = the value here).
param sessionHostCount = empty(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', '')) ? 1 : int(readEnvironmentVariable('AVD_SESSION_HOST_COUNT', ''))
param sessionHostVmSize = empty(readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')) ? 'Standard_E4as_v5' : readEnvironmentVariable('AVD_SESSION_HOST_VM_SIZE', '')
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
// deploy.sh pins the runbook to the commit being deployed (AVD_RUNBOOK_URI).
param autoShutdownRunbookUri = empty(readEnvironmentVariable('AVD_RUNBOOK_URI', ''))
  ? 'https://raw.githubusercontent.com/nickprignano/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1'
  : readEnvironmentVariable('AVD_RUNBOOK_URI', '')
// Test stops every idle host at 20:00 Central, like dev, and a budget alert (when set) locks them.
// The deployment portal's Cost step and deploy.sh (--auto-shutdown HH:mm | none, --start-vm-on-connect
// true | false) override the schedule and Start VM on Connect through AVD_AUTO_SHUTDOWN_TIME and
// AVD_START_VM_ON_CONNECT (empty = the value here; 'none' = no scheduled stop).
param autoShutdownTime = empty(readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '')) ? '20:00' : (readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', '') == 'none' ? '' : readEnvironmentVariable('AVD_AUTO_SHUTDOWN_TIME', ''))
param startVmOnConnect = empty(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', '')) ? true : bool(readEnvironmentVariable('AVD_START_VM_ON_CONNECT', ''))
param autoShutdownTimeZone = 'Central Standard Time'
