#!/usr/bin/env bash
# Deploy the cloud-native AVD landing zone at subscription scope.
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer or with Microsoft.
#
# Usage:
#   ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
#       --users-group "AVD Users" --admins-group "AVD Admins" [-s <subscription>] [--what-if] \
#       [--hosts 3 --vm-size Standard_D8as_v5 --max-sessions 16 --profile-quota 600] \
#       [--auto-shutdown 20:00|none --start-vm-on-connect true|false] [--unlock] \
#       [--topology <json-or-file>] \
#       [--image-id <gallery image version ID> [--generation a|b]] \
#       [--jumpbox [--jumpbox-os linux|windows] [--jumpbox-keep-running <yyyy-MM-ddTHH:mmZ>]]
#
# -s is the subscription (ID or name) to deploy to. Without it, the subscription az has
# selected. Either way the target is printed before anything changes, and -s never changes
# az's selected subscription. It must be in the tenant az is signed in to.
# -l is the region the landing zone is deployed to (it sets AVD_LOCATION, which
# the parameter files read). The sizing flags (from the deployment portal's sizing
# step) override the parameter file's session hosts and profile share the same way;
# the power flags (its Cost step) override the scheduled stop and Start VM on Connect.
# While the hosts are locked by auto shutdown (a budget alert, decision 0011) the
# deployment is refused: run Resume first, or pass --unlock to deploy anyway.
# --image-id and --generation set a new landing zone's first image and host generation. After
# that the host pool's avdlz-image and avdlz-generation tags decide, and only host rotation
# (build/specs/image-pipeline-spec.md section 6.5) changes them: deploy.sh never replaces software.
# The rotation script alone passes --rotation and --deployment-name (the name it then looks up).
# --jumpbox adds the operator jumpbox and Bastion Developer (build/decisions/0019); once it exists,
# later deployments keep it. --jumpbox-os windows makes it Windows Server instead of Linux (only when
# it is created). --jumpbox-keep-running skips its daily stop until that UTC time.
#
# Environment variables (any flag above overrides):
#   AVD_USERS_GROUP_ID, AVD_ADMINS_GROUP_ID   Entra group object IDs
#   AVD_LOCAL_ADMIN_PASSWORD                  break-glass password (random if unset)
#   AVD_SERVICE_PRINCIPAL_ID                  looked up if unset (CI sets it to avoid Graph reads)
#   AVD_ALERT_EMAIL, AVD_MONTHLY_BUDGET       optional (a budget also arms the auto-shutdown trigger)
set -euo pipefail

# Bash 4 or later (lowercase expansion, mapfile). macOS ships Bash 3.2 (avd-ops docs/run-anywhere.md).
if (( BASH_VERSINFO[0] < 4 )); then
  echo "deploy.sh needs Bash 4 or later; this is Bash $BASH_VERSION (macOS ships 3.2)." >&2
  echo "Run it from Azure Cloud Shell, or install a newer bash (brew install bash) and run it with that bash." >&2
  exit 1
fi
# Git Bash on Windows rewrites arguments that start with / (resource IDs) into Windows paths.
export MSYS_NO_PATHCONV=1

PARAM_FILE=""
LOCATION=""
SUBSCRIPTION=""
USERS_GROUP=""
ADMINS_GROUP=""
WHATIF=false
HOSTS=""
VM_SIZE=""
MAX_SESSIONS=""
PROFILE_QUOTA=""
AUTO_SHUTDOWN=""
START_ON_CONNECT=""
UNLOCK=false
IMAGE_ID=""
IMAGE_ID_SET=false
GENERATION=""
GENERATION_SET=false
ROTATION=false
DEPLOY_NAME=""
JUMPBOX=false
JUMPBOX_KEEP_RUNNING=""
JUMPBOX_OS="${AVD_JUMPBOX_OS:-}"
TOPOLOGY="${AVD_TOPOLOGY_JSON:-}"
AVD_APP_ID="9cdead84-a844-4324-93f2-b2e6bb768d07"   # Azure Virtual Desktop first-party app

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PARAM_FILE="$2"; shift 2 ;;
    -l) LOCATION="$2"; shift 2 ;;
    -s|--subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --users-group) USERS_GROUP="$2"; shift 2 ;;
    --admins-group) ADMINS_GROUP="$2"; shift 2 ;;
    --what-if) WHATIF=true; shift ;;
    --hosts) HOSTS="$2"; shift 2 ;;
    --vm-size) VM_SIZE="$2"; shift 2 ;;
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --profile-quota) PROFILE_QUOTA="$2"; shift 2 ;;
    --auto-shutdown) AUTO_SHUTDOWN="$2"; shift 2 ;;
    --start-vm-on-connect) START_ON_CONNECT="$2"; shift 2 ;;
    --unlock) UNLOCK=true; shift ;;
    --image-id) IMAGE_ID="$2"; IMAGE_ID_SET=true; shift 2 ;;
    --generation) GENERATION="$2"; GENERATION_SET=true; shift 2 ;;
    --rotation) ROTATION=true; shift ;;   # only Invoke-AvdHostRotation.ps1 passes this
    --deployment-name) DEPLOY_NAME="$2"; shift 2 ;;   # and this
    --jumpbox) JUMPBOX=true; shift ;;
    --jumpbox-keep-running) JUMPBOX_KEEP_RUNNING="$2"; shift 2 ;;
    --jumpbox-os) JUMPBOX_OS="$2"; shift 2 ;;
    --topology) TOPOLOGY="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$PARAM_FILE" || -z "$LOCATION" ]] && usage
[[ ! -f "$PARAM_FILE" ]] && { echo "Parameter file not found: $PARAM_FILE"; exit 1; }
for n in "$HOSTS" "$MAX_SESSIONS" "$PROFILE_QUOTA"; do
  [[ -z "$n" || "$n" =~ ^[0-9]+$ ]] || { echo "Sizing flags take whole numbers: '$n'"; exit 1; }
done
[[ -z "$DEPLOY_NAME" || "$DEPLOY_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "Not a deployment name: '$DEPLOY_NAME'"; exit 1; }
[[ -z "$VM_SIZE" || "$VM_SIZE" =~ ^Standard_[A-Za-z0-9_]+$ ]] || { echo "Not a VM size: '$VM_SIZE'"; exit 1; }
[[ -z "$AUTO_SHUTDOWN" || "$AUTO_SHUTDOWN" == none || "$AUTO_SHUTDOWN" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--auto-shutdown takes HH:mm or none: '$AUTO_SHUTDOWN'"; exit 1; }
[[ -z "$START_ON_CONNECT" || "$START_ON_CONNECT" == true || "$START_ON_CONNECT" == false ]] || { echo "--start-vm-on-connect takes true or false: '$START_ON_CONNECT'"; exit 1; }
if [[ -n "$TOPOLOGY" && -f "$TOPOLOGY" ]]; then
  TOPOLOGY=$(tr -d '\r\n' < "$TOPOLOGY")
fi
[[ -z "$TOPOLOGY" || "$TOPOLOGY" =~ ^\{.*\}$ ]] || { echo "--topology takes a JSON object or path to a JSON file: '$TOPOLOGY'"; exit 1; }
[[ -z "$GENERATION" || "$GENERATION" == a || "$GENERATION" == b ]] || { echo "--generation takes a or b: '$GENERATION'"; exit 1; }
# A gallery image version, never a definition or latest (image pipeline spec section 6.1).
[[ -z "$IMAGE_ID" || "$IMAGE_ID" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/images/[^/]+/versions/[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "--image-id takes a Compute Gallery image version resource ID (.../images/<definition>/versions/<x.y.z>): '$IMAGE_ID'"; exit 1; }

case "${JUMPBOX_OS,,}" in
  "") ;;
  linux) JUMPBOX_OS=Linux ;;
  windows) JUMPBOX_OS=Windows ;;
  *) echo "--jumpbox-os takes linux or windows: '$JUMPBOX_OS'"; exit 1 ;;
esac
[[ -z "$JUMPBOX_KEEP_RUNNING" || "$JUMPBOX_KEEP_RUNNING" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "--jumpbox-keep-running takes a UTC time, yyyy-MM-ddTHH:mmZ: '$JUMPBOX_KEEP_RUNNING'"; exit 1; }
if [[ -n "$JUMPBOX_KEEP_RUNNING" ]]; then
  # Never leave the meter running (avd-second-brain decision 0017): an opt-out has an end, in the future.
  # GNU date (Linux, Git Bash) takes -d; BSD date (macOS) takes -j -f.
  until_s=$(date -u -d "${JUMPBOX_KEEP_RUNNING/T/ }" +%s 2>/dev/null \
    || date -j -u -f '%Y-%m-%dT%H:%MZ' "$JUMPBOX_KEEP_RUNNING" +%s 2>/dev/null) \
    || { echo "Not a time: '$JUMPBOX_KEEP_RUNNING'"; exit 1; }
  (( until_s > $(date -u +%s) )) || { echo "--jumpbox-keep-running is in the past: '$JUMPBOX_KEEP_RUNNING'"; exit 1; }
fi
# Regions with Azure Bastion Developer (Microsoft Learn, bastion-sku-comparison; the same list as
# Get-AvdBastionDeveloperRegion in scripts/ops/AvdLandingZone.psm1, a test checks they match).
BASTION_DEVELOPER_REGIONS=" brazilsouth canadacentral canadaeast centralus centraluseuap eastus2 eastus2euap mexicocentral northcentralus westcentralus westus francecentral germanywestcentral italynorth northeurope norwayeast spaincentral swedencentral switzerlandnorth uksouth ukwest westeurope australiacentral australiaeast australiasoutheast centralindia eastasia japaneast japanwest koreacentral koreasouth southindia southeastasia southafricanorth uaenorth "
if $JUMPBOX && [[ "$BASTION_DEVELOPER_REGIONS" != *" ${LOCATION,,} "* ]]; then
  echo "Azure Bastion Developer isn't offered in $LOCATION, so --jumpbox can't be used there. Regions:$BASTION_DEVELOPER_REGIONS"
  exit 1
fi

# Pin the auto-shutdown runbook (decision 0011) to the commit being deployed, before anything touches
# Azure. It is never read from master (avd-ops decision 0008): when GitHub doesn't have this commit,
# push it or set AVD_RUNBOOK_URI to the raw URL at a commit or v* tag. A what-if deploys nothing, so
# it previews with master and says so.
RUNBOOK_PIN='^https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/([0-9a-f]{7,40}|v[0-9][A-Za-z0-9.-]*)/scripts/automation/Invoke-AvdPowerAction\.ps1$'
if [[ -n "${AVD_RUNBOOK_URI:-}" ]]; then
  [[ $AVD_RUNBOOK_URI =~ $RUNBOOK_PIN ]] \
    || { echo "AVD_RUNBOOK_URI must be the runbook's raw.githubusercontent.com URL at a commit SHA or a v* tag: '$AVD_RUNBOOK_URI'"; exit 1; }
else
  # pwd -W gives Git Bash's Windows path: with MSYS_NO_PATHCONV set, native git can't read /d/... paths.
  repo_dir=$(cd "$(dirname "$0")/../.." && { pwd -W 2>/dev/null || pwd; })
  sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  origin=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
  if [[ $origin =~ github\.com[:/]([^/]+)/([^/]+)$ ]] && [[ -n "$sha" ]] &&
     git -C "$repo_dir" branch -r --contains "$sha" 2>/dev/null | grep -q .; then
    owner=${BASH_REMATCH[1]}; repo=${BASH_REMATCH[2]%.git}
    AVD_RUNBOOK_URI="https://raw.githubusercontent.com/$owner/$repo/$sha/scripts/automation/Invoke-AvdPowerAction.ps1"
  elif $WHATIF; then
    echo "Note: commit ${sha:-unknown} is not on a GitHub remote; this what-if previews the runbook from master. A deployment would stop here."
    AVD_RUNBOOK_URI="https://raw.githubusercontent.com/avd-ops/avd-landing-zone/master/scripts/automation/Invoke-AvdPowerAction.ps1"
  else
    echo "ERROR: can't pin the auto-shutdown runbook: commit ${sha:-unknown} is not on a GitHub remote of this clone." >&2
    echo "       Deploy from a release tag or a pushed commit, or set AVD_RUNBOOK_URI to the runbook's raw URL at a commit or v* tag." >&2
    exit 1
  fi
fi
export AVD_RUNBOOK_URI

echo "==> Checking az and Bicep"
az bicep version >/dev/null 2>&1 || az bicep install
az account show >/dev/null 2>&1 || { echo "Run 'az login' first."; exit 1; }
# Azure Resource Manager calls go through arm, which adds -s to each one, so deploying to another
# subscription never changes the one az has selected. Graph calls (az ad, az rest) read the tenant,
# and a call given resource --ids already names its subscription.
arm() {
  if [[ -n "$SUBSCRIPTION" ]]; then az "$@" --subscription "$SUBSCRIPTION"; else az "$@"; fi
}
if ! SUB_ID=$(arm account show --query id -o tsv 2>/dev/null) || [[ -z "$SUB_ID" ]]; then
  echo "Subscription not found, or not one this account can use: $SUBSCRIPTION (az account list shows them)." >&2; exit 1
fi
SUB_NAME=$(arm account show --query name -o tsv)
echo "    Subscription: $SUB_NAME ($SUB_ID)"
[[ -n "$SUBSCRIPTION" ]] || echo "    (the one az has selected; pass -s to choose)"
# Entra lookups below read the signed-in tenant: groups and the AVD service principal from another
# tenant would be the wrong objects.
SUB_TENANT=$(arm account show --query tenantId -o tsv)
AZ_TENANT=$(az account show --query tenantId -o tsv)
if [[ "$SUB_TENANT" != "$AZ_TENANT" ]]; then
  echo "Subscription $SUB_ID is in tenant $SUB_TENANT, but az is signed in to $AZ_TENANT." >&2
  echo "Run 'az login --tenant $SUB_TENANT' first." >&2; exit 1
fi

# --- Resource providers + features (idempotent; a fresh subscription has none) ---
echo "==> Registering resource providers"
for ns in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Storage Microsoft.Network \
          Microsoft.Insights Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.RecoveryServices \
          Microsoft.Security Microsoft.PolicyInsights Microsoft.GuestConfiguration Microsoft.Consumption; do
  state=$(arm provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
  if [[ "$state" != "Registered" ]]; then
    echo "    $ns"
    arm provider register -n "$ns" --wait >/dev/null
  fi
done

echo "==> Ensuring the EncryptionAtHost feature is registered"
feature_state=$(arm feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv 2>/dev/null || echo NotRegistered)
if [[ "$feature_state" != "Registered" ]]; then
  arm feature register --namespace Microsoft.Compute --name EncryptionAtHost >/dev/null
  until [[ "$(arm feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv)" == "Registered" ]]; do
    echo "    waiting for EncryptionAtHost ..."; sleep 20
  done
fi
# Re-register Compute every time: the feature only takes effect after a
# provider re-registration, even when it was registered in an earlier run.
arm provider register -n Microsoft.Compute >/dev/null

# --- Entra ID lookups ---
# A group given by name must not be one an ordinary user created with that name: it would get VM
# Admin Login, the break-glass secret and elevated share access. Its owners must be administrators
# (or you). A group given by object ID was picked deliberately and is used as it is.
admin_role_member_ids() {
  # Active members of Global, Privileged Role, Groups and User Administrator (role template IDs).
  local t r
  for t in 62e90394-69f5-4237-9190-012177145e10 e8611ab8-c189-46e8-94e1-60213ab1f814 fdd7a751-b60b-444a-984c-02652fe8fa1c fe930be7-5e62-47db-91af-98c3a49a38b1; do
    for r in $(az rest --method get --url "https://graph.microsoft.com/v1.0/directoryRoles?\$filter=roleTemplateId eq '$t'" --query "value[].id" -o tsv 2>/dev/null); do
      az rest --method get --url "https://graph.microsoft.com/v1.0/directoryRoles/$r/members?\$select=id" --query "value[].id" -o tsv 2>/dev/null
    done
  done
}
resolve_group() {
  local id owners allowed o
  id=$(az ad group show --group "$1" --query id -o tsv 2>/dev/null) || { echo "Entra group not found: $1" >&2; exit 1; }
  if [[ ! $1 =~ ^[0-9a-fA-F-]{36}$ ]]; then
    owners=$(az ad group owner list --group "$id" --query "[].id" -o tsv 2>/dev/null || true)
    if [[ -n "$owners" ]]; then
      allowed=$(printf '%s\n' "$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)" "$(admin_role_member_ids)")
      for o in $owners; do
        grep -qx "$o" <<<"$allowed" || {
          echo "Entra group '$1' ($id) has an owner who is not an administrator; a group anyone created must not get the landing zone's rights." >&2
          echo "Pass the object ID of a group an administrator created (AVD_USERS_GROUP_ID / AVD_ADMINS_GROUP_ID), or remove that owner." >&2
          exit 1
        }
      done
    fi
    echo "    $1 -> $id" >&2
  fi
  echo "$id"
}
[[ -n "$USERS_GROUP" ]] && AVD_USERS_GROUP_ID=$(resolve_group "$USERS_GROUP")
[[ -n "$ADMINS_GROUP" ]] && AVD_ADMINS_GROUP_ID=$(resolve_group "$ADMINS_GROUP")
: "${AVD_USERS_GROUP_ID:?Set AVD_USERS_GROUP_ID or pass --users-group}"
: "${AVD_ADMINS_GROUP_ID:?Set AVD_ADMINS_GROUP_ID or pass --admins-group}"

if [[ -z "${AVD_SERVICE_PRINCIPAL_ID:-}" ]]; then
  echo "==> Looking up the Azure Virtual Desktop service principal"
  AVD_SERVICE_PRINCIPAL_ID=$(az ad sp show --id "$AVD_APP_ID" --query id -o tsv 2>/dev/null || true)
fi
if [[ -z "$AVD_SERVICE_PRINCIPAL_ID" ]]; then
  echo "    Not found in this tenant; creating it from the first-party app"
  AVD_SERVICE_PRINCIPAL_ID=$(az ad sp create --id "$AVD_APP_ID" --query id -o tsv)
fi

if [[ -z "${AVD_LOCAL_ADMIN_PASSWORD:-}" ]]; then
  # Random break-glass password. Azure applies it only when a host is created
  # (existing hosts keep theirs), and it is stored in Key Vault. Recovery for any
  # host: VM > Reset password, which needs no old password.
  rand=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  AVD_LOCAL_ADMIN_PASSWORD="${rand}#Aa1"
  echo "    Generated a random break-glass password for new session hosts (stored in Key Vault as sessionhost-localadmin-password)."
fi

AVD_LOCATION="$LOCATION"
export AVD_USERS_GROUP_ID AVD_ADMINS_GROUP_ID AVD_SERVICE_PRINCIPAL_ID AVD_LOCAL_ADMIN_PASSWORD AVD_LOCATION
# Sizing overrides (empty = the parameter file's values).
AVD_SESSION_HOST_COUNT="$HOSTS" AVD_SESSION_HOST_VM_SIZE="$VM_SIZE" AVD_MAX_SESSION_LIMIT="$MAX_SESSIONS" AVD_PROFILE_QUOTA_GIB="$PROFILE_QUOTA"
export AVD_SESSION_HOST_COUNT AVD_SESSION_HOST_VM_SIZE AVD_MAX_SESSION_LIMIT AVD_PROFILE_QUOTA_GIB
if [[ -n "$HOSTS$VM_SIZE$MAX_SESSIONS$PROFILE_QUOTA" ]]; then
  echo "    Sizing: ${HOSTS:-file} host(s) x ${VM_SIZE:-file size}, ${MAX_SESSIONS:-file} sessions per host, ${PROFILE_QUOTA:-file} GiB profile share"
fi

# Power overrides from the portal's Cost step (empty = the parameter file's values; none = no scheduled stop).
AVD_AUTO_SHUTDOWN_TIME="$AUTO_SHUTDOWN" AVD_START_VM_ON_CONNECT="$START_ON_CONNECT" AVD_TOPOLOGY_JSON="$TOPOLOGY"
export AVD_AUTO_SHUTDOWN_TIME AVD_START_VM_ON_CONNECT AVD_TOPOLOGY_JSON
if [[ -n "$AUTO_SHUTDOWN$START_ON_CONNECT" ]]; then
  echo "    Power: scheduled stop ${AUTO_SHUTDOWN:-file}, Start VM on Connect ${START_ON_CONNECT:-file}"
fi
if [[ -n "$TOPOLOGY" ]]; then
  echo "    Topology: custom manifest configured (AVD_TOPOLOGY_JSON)"
fi

DEPLOY_NAME="${DEPLOY_NAME:-avdlz-$(basename "$PARAM_FILE" .bicepparam)-$(date +%Y%m%d-%H%M%S)}"

# Machine-readable state for the deployment portal (site/portal). Schema: site/portal/README.md.
# AVD_PORTAL_URL points at a copy published into the subscription (Publish-AvdPortal.ps1, decision 0017).
DEFAULT_PORTAL_URL="https://deploy.avd-ops.dev/portal/"
PORTAL_URL="$DEFAULT_PORTAL_URL"
if [[ "${AVD_PORTAL_URL:-}" =~ ^https://[A-Za-z0-9.-]+(/[^[:space:]\"\'\<\>]*)?$ ]]; then PORTAL_URL="${AVD_PORTAL_URL%/}/"; fi
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
# The commit these scripts run from, so the portal can tell when it is older than them (red team PH-8).
PORTAL_COMMIT=$(git -C "$(cd "$(dirname "$0")" && pwd)" rev-parse --short HEAD 2>/dev/null || true)
[[ "$PORTAL_COMMIT" =~ ^[0-9a-f]{7,40}$ ]] || PORTAL_COMMIT=""
portal_state() {
  # $1 = status (started | succeeded | failed | whatif); $2 = extra context JSON members (optional)
  printf '\nDeployment portal: paste this output into %s for the next step.\n' "$PORTAL_URL"
  if [[ "$PORTAL_URL" != "$DEFAULT_PORTAL_URL" ]]; then
    local portal_host=${PORTAL_URL#https://}; printf 'Portal host: %s, set by AVD_PORTAL_URL\n' "${portal_host%%/*}"
  fi
  local sizing=""
  if [[ -n "$HOSTS$VM_SIZE$MAX_SESSIONS$PROFILE_QUOTA" ]]; then
    sizing=",\"sizing\":{\"hosts\":${HOSTS:-null},\"vmSize\":$( [[ -n "$VM_SIZE" ]] && json_str "$VM_SIZE" || printf null ),\"maxSessions\":${MAX_SESSIONS:-null},\"profileQuotaGiB\":${PROFILE_QUOTA:-null}}"
  fi
  if [[ -n "$AUTO_SHUTDOWN$START_ON_CONNECT" ]]; then
    sizing="$sizing,\"power\":{\"autoShutdownTime\":$( [[ -n "$AUTO_SHUTDOWN" ]] && json_str "$AUTO_SHUTDOWN" || printf null ),\"startVmOnConnect\":${START_ON_CONNECT:-null}}"
  fi
  if [[ -n "$TOPOLOGY" ]]; then
    sizing="$sizing,\"topology\":$TOPOLOGY"
  fi
  local commit=""
  [[ -n "$PORTAL_COMMIT" ]] && commit=",\"commit\":$(json_str "$PORTAL_COMMIT")"
  printf '<<<AVDLZ-STATE {"v":1,"stage":"deploy","status":"%s","context":{"parameterFile":%s,"location":%s,"usersGroup":%s,"adminsGroup":%s,"deploymentName":%s%s%s%s}} AVDLZ-STATE>>>\n' \
    "$1" "$(json_str "$PARAM_FILE")" "$(json_str "$LOCATION")" "$(json_str "$USERS_GROUP")" "$(json_str "$ADMINS_GROUP")" "$(json_str "$DEPLOY_NAME")" "$sizing" "$commit" "${2:-}"
}

# --- Session hosts that aren't running (lesson 0026) ---
# A redeploy updates each existing host's run commands, and Azure refuses that on a VM that isn't
# running ("Cannot modify extensions in the VM when the VM is not running"). Power management keeps
# hosts deallocated most of the time, so a redeploy starts them and deallocates them again after.
param_value() { sed -n "s/^param $1 = '\([^']*\)'.*/\1/p" "$PARAM_FILE" | head -n 1; }
NAME_PREFIX=$(param_value namePrefix); ENV_NAME=$(param_value environmentName)
NAME_PREFIX=${NAME_PREFIX//-/}; NAME_PREFIX=${NAME_PREFIX,,}   # cleanPrefix in bicep/main.bicep
HOSTS_RG="rg-$NAME_PREFIX-$ENV_NAME-hosts"
STOPPED_HOSTS=()
# Read whether or not the hosts resource group exists: a pool that outlived its hosts still records
# their image, generation and any rotation in progress.
if [[ -n "$NAME_PREFIX" && -n "$ENV_NAME" ]]; then
  # --- Image and generation (image pipeline spec section 6.1) ---
  # The host pool's tags record which image and generation its hosts run; only the rotation script
  # changes them. Without --image-id and --generation the deployment keeps both, and it passes the
  # rotation tags back so they survive the deployment.
  # Only a pool that doesn't exist counts as having no tags: any other read error stops here, because
  # deploying on a guess could change the hosts' image or names (lesson 0012: report what Azure said).
  POOL_ERR=$(mktemp)
  if ! POOL_STATE=$(arm resource show -g "rg-$NAME_PREFIX-$ENV_NAME-avd" -n "vdpool-$NAME_PREFIX-$ENV_NAME" \
    --resource-type Microsoft.DesktopVirtualization/hostPools \
    --query '{"avdlz-image": tags."avdlz-image", "avdlz-generation": tags."avdlz-generation", "avdlz-image-next": tags."avdlz-image-next", "avdlz-image-previous": tags."avdlz-image-previous", "avdlz-rotation": tags."avdlz-rotation"}' \
    -o json 2>"$POOL_ERR"); then
    if grep -qE 'ResourceNotFound|ResourceGroupNotFound|was not found' "$POOL_ERR"; then
      POOL_STATE=""
    else
      echo "==> Could not read the host pool vdpool-$NAME_PREFIX-$ENV_NAME to keep its image and generation. Not deploying." >&2
      cat "$POOL_ERR" >&2; rm -f "$POOL_ERR"
      exit 1
    fi
  fi
  rm -f "$POOL_ERR"
  if [[ -n "$POOL_STATE" ]]; then
    POOL_FOUND=true
    # Keep the tags that are set, as a JSON object (absent tags come back null and are left out).
    POOL_STATE=$(tr -d '\n' <<<"$POOL_STATE"); kept=()
    for tag in avdlz-image avdlz-generation avdlz-image-next avdlz-image-previous avdlz-rotation; do
      [[ $POOL_STATE =~ \"$tag\":\ *(\"([^\"\\]|\\.)*\") ]] && kept+=("\"$tag\":${BASH_REMATCH[1]}")
    done
    AVD_HOST_POOL_STATE_TAGS="{$(IFS=,; echo "${kept[*]}")}"
    POOL_IMAGE=""; POOL_GENERATION=""
    [[ $POOL_STATE =~ \"avdlz-image\":\ *\"([^\"]*)\" ]] && POOL_IMAGE=${BASH_REMATCH[1]}
    [[ $POOL_STATE =~ \"avdlz-generation\":\ *\"([^\"]*)\" ]] && POOL_GENERATION=${BASH_REMATCH[1]}
    $IMAGE_ID_SET || IMAGE_ID="$POOL_IMAGE"
    $GENERATION_SET || GENERATION="$POOL_GENERATION"
    if ! $ROTATION; then
      # A rotation in progress owns the pool, and only a rotation changes its image or generation:
      # Azure rejects a new image on an existing VM, and a new generation deploys a second set of hosts.
      if [[ $POOL_STATE =~ \"avdlz-rotation\":\ *\" ]]; then
        echo "==> A host rotation is in progress on vdpool-$NAME_PREFIX-$ENV_NAME (tag avdlz-rotation). Not deploying." >&2
        echo "    Finish or roll it back first: ./scripts/ops/Invoke-AvdHostRotation.ps1 -NamePrefix $NAME_PREFIX -Environment $ENV_NAME" >&2
        exit 1
      fi
      if [[ "$IMAGE_ID" != "$POOL_IMAGE" || "$GENERATION" != "$POOL_GENERATION" ]]; then
        echo "==> The host pool runs image '${POOL_IMAGE:-marketplace}', generation '${POOL_GENERATION:-none}'. Not deploying a different one." >&2
        echo "    New images reach existing hosts by rotation (build/specs/image-pipeline-spec.md section 6.5), not by deploy.sh." >&2
        exit 1
      fi
    fi
  fi
fi
if [[ -n "$NAME_PREFIX" && -n "$ENV_NAME" ]] && [[ "$(arm group exists -n "$HOSTS_RG")" == "true" ]]; then
  # --- Hosts locked by auto shutdown (decision 0011) ---
  # Lock tags the host pool, drains and tags the hosts and turns Start VM on Connect off. A
  # deployment would start every host, replace the tags and turn Start VM on Connect back on,
  # silently undoing what the budget alert bought. So it is refused until Resume has run.
  POWER_LOCK=$(arm resource show -g "rg-$NAME_PREFIX-$ENV_NAME-avd" -n "vdpool-$NAME_PREFIX-$ENV_NAME" \
    --resource-type Microsoft.DesktopVirtualization/hostPools --query 'tags."avdlz-power-lock"' -o tsv 2>/dev/null || true)
  if [[ -n "$POWER_LOCK" ]]; then
    if $WHATIF; then
      echo "==> The session hosts are locked by auto shutdown ($POWER_LOCK). The deployment itself is refused until Resume runs (or --unlock)."
    elif $UNLOCK; then
      echo "==> The session hosts are locked by auto shutdown ($POWER_LOCK); deploying anyway (--unlock)."
      echo "    The deployment removes the lock tag and the scaling exclusion. The hosts stay in drain mode until Resume runs."
    else
      echo "==> The session hosts are locked by auto shutdown ($POWER_LOCK). Not deploying." >&2
      echo "    A deployment would start the hosts and turn Start VM on Connect back on. Run Resume first:" >&2
      echo "      ./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume -NamePrefix $NAME_PREFIX -Environment $ENV_NAME" >&2
      echo "    or pass --unlock to deploy over the lock (the hosts stay drained until Resume)." >&2
      exit 1
    fi
  fi
  echo "==> Checking the session hosts' power state in $HOSTS_RG"
  mapfile -t STOPPED_HOSTS < <(arm vm list -d -g "$HOSTS_RG" --query "[?powerState!='VM running'].id" -o tsv)
  if $ROTATION && ((${#STOPPED_HOSTS[@]})); then
    # A rotation deploys only the new generation, so only its VMs are started and deallocated: starting
    # a retiring host would let users onto it, and deallocating it after would end their sessions.
    # The names follow hostNamePrefix in bicep/main.bicep.
    BASE_PREFIX=$(param_value sessionHostNamePrefix)
    [[ -n "$BASE_PREFIX" ]] || { BASE_PREFIX="$NAME_PREFIX${ENV_NAME:0:1}sh"; BASE_PREFIX=${BASE_PREFIX:0:11}; }
    GEN_PREFIX="${BASE_PREFIX:0:10}$GENERATION"
    KEEP=()
    for id in "${STOPPED_HOSTS[@]}"; do
      if [[ "${id##*/}" =~ ^${GEN_PREFIX}-[0-9]{3}$ ]]; then KEEP+=("$id"); else echo "    Leaving ${id##*/} as it is (not generation $GENERATION)."; fi
    done
    STOPPED_HOSTS=("${KEEP[@]}")
  fi
fi
# A new host pool records the image and generation its first hosts get, so later deployments keep them.
if ! ${POOL_FOUND:-false} && [[ -n "$IMAGE_ID$GENERATION" ]]; then
  first=()
  [[ -n "$IMAGE_ID" ]] && first+=("\"avdlz-image\":$(json_str "$IMAGE_ID")")
  [[ -n "$GENERATION" ]] && first+=("\"avdlz-generation\":$(json_str "$GENERATION")")
  AVD_HOST_POOL_STATE_TAGS="{$(IFS=,; echo "${first[*]}")}"
fi
# --- Operator jumpbox (decision 0019) ---
# Once the jumpbox exists, a deployment without --jumpbox would try to remove its subnet while the VM
# is in it, and fail: keep it. Remove-AvdDemo.ps1 -IncludeJumpbox removes it.
if ! $JUMPBOX && [[ -n "$NAME_PREFIX" && -n "$ENV_NAME" ]] && [[ "$(arm group exists -n "rg-$NAME_PREFIX-$ENV_NAME-jumpbox")" == "true" ]]; then
  JUMPBOX=true
  echo "==> Keeping the jumpbox in rg-$NAME_PREFIX-$ENV_NAME-jumpbox (Remove-AvdDemo.ps1 -IncludeJumpbox removes it)."
fi
[[ -z "$JUMPBOX_KEEP_RUNNING" ]] || $JUMPBOX || { echo "--jumpbox-keep-running needs --jumpbox (or a jumpbox that already exists)"; exit 1; }
[[ -z "$JUMPBOX_OS" ]] || $JUMPBOX || { echo "--jumpbox-os needs --jumpbox"; exit 1; }
# An existing VM is never re-sent: Azure refuses a change to its custom data (first boot) and admin
# password. Its daily stop and tags are updated on their own (bicep/modules/jumpbox.bicep).
# Its operating system is chosen once: an existing one keeps its own, and asking for the other is refused.
JUMPBOX_EXISTS=''
if $JUMPBOX && [[ -n "$NAME_PREFIX" && -n "$ENV_NAME" ]]; then
  jumpbox_err=$(mktemp)
  if existing_os=$(arm vm show -g "rg-$NAME_PREFIX-$ENV_NAME-jumpbox" -n "vm-$NAME_PREFIX-$ENV_NAME-jumpbox" --query storageProfile.osDisk.osType -o tsv 2>"$jumpbox_err"); then
    JUMPBOX_EXISTS=true
    if [[ -n "$JUMPBOX_OS" && "$JUMPBOX_OS" != "$existing_os" ]]; then
      echo "The jumpbox runs $existing_os; --jumpbox-os can't change it. Remove it first (Remove-AvdDemo.ps1 -IncludeJumpbox -DiscardLastCopy)."
      exit 1
    fi
    JUMPBOX_OS="$existing_os"
  elif ! grep -qE "ResourceNotFound|ResourceGroupNotFound" "$jumpbox_err"; then
    # Only "not found" means there is no jumpbox; anything else would re-send an existing VM.
    echo "Can't read the jumpbox VM:"; cat "$jumpbox_err"; exit 1
  fi
  rm -f "$jumpbox_err"
fi
AVD_DEPLOY_JUMPBOX=$($JUMPBOX && echo true || echo '') AVD_JUMPBOX_KEEP_RUNNING_UNTIL="$JUMPBOX_KEEP_RUNNING" AVD_JUMPBOX_EXISTS="$JUMPBOX_EXISTS" AVD_JUMPBOX_OS="$JUMPBOX_OS"
export AVD_DEPLOY_JUMPBOX AVD_JUMPBOX_KEEP_RUNNING_UNTIL AVD_JUMPBOX_EXISTS AVD_JUMPBOX_OS
if $JUMPBOX; then
  echo "    Jumpbox: ${JUMPBOX_OS:-Linux}, $([[ -n "$JUMPBOX_KEEP_RUNNING" ]] && echo "kept running until $JUMPBOX_KEEP_RUNNING (no daily stop)" || echo 'stops daily'); connect with ./scripts/ops/Connect-AvdJumpbox.ps1"
fi

# Image and generation (empty = the marketplace image and the original host names).
AVD_SESSION_HOST_IMAGE_ID="$IMAGE_ID" AVD_SESSION_HOST_GENERATION="$GENERATION" AVD_HOST_POOL_STATE_TAGS="${AVD_HOST_POOL_STATE_TAGS:-}"
export AVD_SESSION_HOST_IMAGE_ID AVD_SESSION_HOST_GENERATION AVD_HOST_POOL_STATE_TAGS
if [[ -n "$IMAGE_ID$GENERATION" ]]; then
  echo "    Hosts: image ${IMAGE_ID:-marketplace}, generation ${GENERATION:-none}"
fi

restore_hosts() {
  ((${#STOPPED_HOSTS[@]})) || return 0
  echo "==> Deallocating the session hosts started for the deployment: ${STOPPED_HOSTS[*]##*/}"
  az vm deallocate --ids "${STOPPED_HOSTS[@]}" --no-wait -o none \
    || echo "    Could not deallocate them; the scaling plan or the scheduled stop will."
}

if $WHATIF; then
  if ((${#STOPPED_HOSTS[@]})); then
    echo "    Not running: ${STOPPED_HOSTS[*]##*/}. The deployment starts them first and deallocates them after."
  fi
  echo "==> What-if ($DEPLOY_NAME) — no changes applied"
  arm deployment sub what-if -n "$DEPLOY_NAME" -l "$LOCATION" -p "$PARAM_FILE"
  portal_state whatif
  exit 0
fi

if ((${#STOPPED_HOSTS[@]})); then
  echo "==> Starting the session hosts that aren't running: ${STOPPED_HOSTS[*]##*/}"
  echo "    The deployment updates their run commands, which needs them running. They are deallocated again afterwards."
  az vm start --ids "${STOPPED_HOSTS[@]}" -o none
fi

echo "==> Deploying ($DEPLOY_NAME). A first deployment takes 30-45 minutes."
echo "    If Cloud Shell disconnects, the deployment keeps running in Azure."
portal_state started
if ! arm deployment sub create -n "$DEPLOY_NAME" -l "$LOCATION" -p "$PARAM_FILE" \
  --query properties.outputs -o jsonc; then
  restore_hosts
  portal_state failed
  exit 1
fi
restore_hosts

STORAGE_NAME=$(arm deployment sub show -n "$DEPLOY_NAME" --query properties.outputs.storageAccountName.value -o tsv)
# rg-<prefix>-<env>-avd -> <prefix> and <env>, for the post-deployment command.
BASE_NAME=$(arm deployment sub show -n "$DEPLOY_NAME" --query properties.outputs.resourceGroups.value.controlPlane -o tsv)
BASE_NAME=${BASE_NAME#rg-}; BASE_NAME=${BASE_NAME%-avd}

cat <<EOF

==> Landing zone deployed.

Next, three one-time tenant steps that Bicep can't do: admin consent for the
storage account's Entra app, excluding it from MFA Conditional Access policies,
and the profile share permissions. The post-deployment preflight checks and
applies all three. From Azure Cloud Shell (PowerShell):

  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ${BASE_NAME%-*} -Environment ${BASE_NAME##*-} -SubscriptionId $SUB_ID -Fix -AllowHostStart

To do them by hand instead (storage account $STORAGE_NAME), see docs/deploy.md#5-post-deployment.
EOF
portal_state succeeded ",\"namePrefix\":$(json_str "${BASE_NAME%-*}"),\"environment\":$(json_str "${BASE_NAME##*-}"),\"storageAccount\":$(json_str "$STORAGE_NAME")"
