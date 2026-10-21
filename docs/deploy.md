# Deploy

> Presenting it live? [demo.md](demo.md) fits a working desktop into a 30-minute slot.

## 1. Prerequisites

**Azure**
- A dedicated subscription for the landing zone. The deploying identity needs **Owner** (it creates role and policy assignments).
- Azure CLI ≥ 2.65 (`az upgrade`), with Bicep (`az bicep install`).
- vCPU quota for `sessionHostCount × sessionHostVmSize` in the region, and a region that supports Premium ZRS file shares if you keep `profileStorageSku = 'Premium_ZRS'`.

**Entra ID / Microsoft 365**
- Two security groups: **AVD Users** (people who get the desktop) and **AVD Admins** (operators).
- Users licensed for AVD, e.g. Microsoft 365 E3/E5/Business Premium or Windows Enterprise E3/E5.
- Intune licensing, if `enrollInIntune = true` (the default). Without it, set `enrollInIntune = false`.
- Someone with **Cloud Application Administrator** or **Application Administrator** for the post-deployment admin consent.
- Profiles on Azure Files through Entra Kerberos: hybrid (synced) identities are fully supported. Check [Microsoft's current guidance](https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable) on cloud-only identity support before relying on it.

## 2. Region

Pick the region closest to your users: session latency matters more than anything else about the region. The [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) measures round-trip time from your browser to each Azure region, then guides the whole deployment: it gives you each command and reads the output you paste back. Open it from the network your users are on, not over a VPN, and not from Cloud Shell, which runs in an Azure datacenter.

The parameter files default to `northcentralus`. `deploy.sh -l <region>` and the preflight's `-Location <region>` override that through the `AVD_LOCATION` environment variable, so you don't edit the file to change region. The files deploy without availability zones, which works in every region. For zone redundancy, pick a zonal region and set `availabilityZones = [1, 2, 3]` and `profileStorageSku = 'Premium_ZRS'`.

The host pool is deployed in the same region, so the region must offer AVD host pools. The preflight checks that.

## 3. Parameters

`parameters/dev.bicepparam` and `parameters/prod.bicepparam` are committed, and so is `parameters/test.bicepparam`. The test file is dev's footprint as a second landing zone beside dev; it leaves the subscription-wide policy guardrails and activity log export to dev (`deploySubscriptionSettings = false`). They hold no tenant data: identity values and secrets come from environment variables.

| Variable | Required | Set by |
|---|---|---|
| `AVD_USERS_GROUP_ID` | yes | `deploy.sh --users-group <name or object ID>` or you. A group given by name must have no owner outside the administrator roles (anyone who can create groups could have made one with that name) |
| `AVD_ADMINS_GROUP_ID` | yes | `deploy.sh --admins-group <name or object ID>` or you, same check |
| `AVD_SERVICE_PRINCIPAL_ID` | yes | `deploy.sh` (looks up app `9cdead84-a844-4324-93f2-b2e6bb768d07`) |
| `AVD_LOCAL_ADMIN_PASSWORD` | no | `deploy.sh` generates a random one if unset. Applied only to hosts it creates; see [gotchas](gotchas.md#the-break-glass-password-is-random-and-set-at-host-creation) |
| `AVD_ALERT_EMAIL` | no | you |
| `AVD_MONTHLY_BUDGET` | no (prod) | you |
| `AVD_LOCATION` | no | `deploy.sh -l`, or the preflight's `-Location`. Defaults to `northcentralus` |
| `AVD_RECOVERY_LOCATION` | no | you, or the preflight's `-RecoveryLocation`: a second region the policy guardrail also allows, for restores and recovery tests ([recovery spec](../build/specs/recovery-spec.md)). The preflight checks policy and quota there. Empty = none |
| `AVD_RUNBOOK_URI` | no | `deploy.sh`: the auto-shutdown runbook at the commit being deployed. Defaults to the repo's `master` |
| `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT`, `AVD_PROFILE_QUOTA_GIB` | no | `deploy.sh --hosts --vm-size --max-sessions --profile-quota`, or the preflight's `-SessionHostCount -SessionHostVmSize -MaxSessionLimit -ProfileShareQuotaGiB`; the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/)'s sizing step fills them in. Empty = the file's values |
| `AVD_AUTO_SHUTDOWN_TIME`, `AVD_START_VM_ON_CONNECT` | no | `deploy.sh --auto-shutdown HH:mm\|none --start-vm-on-connect true\|false`, or the preflight's `-AutoShutdownTime -StartVmOnConnect`; the portal's Cost step fills them in. Empty = the file's values; `none` = no scheduled stop |

Things you'll most likely change in the file: `namePrefix`, address ranges, `scalingTimeZone`, and for hub-peered mode the hub settings (examples are in `prod.bicepparam`).

## 4. Deploy

Run the pre-deployment preflight first, and repeat it until it comes back clean. `-Fix` registers providers and creates the groups and the AVD service principal. It checks your parameter file against the subscription (zones, quota, storage SKU, Key Vault name) and the tenant (Intune, roles). See [operations.md](operations.md#pre-deployment-preflight).

```powershell
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/prod.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins'
```

```bash
az login
az account set --subscription "<subscription-id>"

./scripts/deploy/deploy.sh -p parameters/prod.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins" --what-if

./scripts/deploy/deploy.sh -p parameters/prod.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins"
```

To size the host pool, use the portal's **Size the host pool** step, then its **Cost** step for Start VM on Connect and the scheduled stop. They add their flags to both commands, and the preflight checks quota for that size and prices it at Azure list prices for the region (see [operations.md](operations.md#sizing-and-cost)).

`deploy.sh` registers the resource providers and the `EncryptionAtHost` feature, resolves the group and service principal IDs, and runs `az deployment sub create`. A first deployment takes roughly 30–45 minutes. Session hosts are registered to the pool and FSLogix-configured as part of it. There are no post-deployment scripts.

### From a migration factory manifest

When the design comes from an assessment, it arrives as an approved target-state manifest (`avd-target-state/v1`, contract C14 in [avd-second-brain](https://github.com/nickprignano/avd-second-brain/blob/main/docs/contracts.md)) with its approval file next to it. The reader turns one host pool of it into the two commands above, with the sizing and power settings as flags, and changes nothing in Azure:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git checkout -q master; git pull -q --ff-only
./scripts/ops/ConvertFrom-AvdTargetState.ps1 -Path ~/clouddrive/engagement/manifest.json -ParameterFile parameters/prod.bicepparam -AlertEmail ops@example.com
```

It looks for `manifest.approval.json` next to the manifest (`-ApprovalPath` overrides it) and refuses, with the reason, a manifest that has no matching approval or changed after it, evidence that was stale when it was approved, another renderer or listed gaps, an identity lane other than Entra-only, hub-peered networking, more than one host pool without `-HostPool`, a personal or RemoteApp pool, a GPU size, a Liquidware product, a low-confidence value the approval doesn't accept, or a schedule in a different time zone from the parameter file's. `-AlertEmail` sets `AVD_MONTHLY_BUDGET` to the pool's estimate plus 10%, so the budget lock is armed. The scaling schedule and the C5 attribution tags are printed as lines to set by hand. What it can deploy is in `contracts/target-state-capabilities.json`; the vendored schemas and fact register are pinned in `contracts/PINS.json`.

## 5. Post-deployment

These are tenant-level steps that ARM can't perform. Each is done once per storage account.

**Automated:** from Azure Cloud Shell, `./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix <prefix> -Environment <env> -Fix` checks and applies all three. It confirms each Conditional Access change, and sets the NTFS ACL from a session host. See [operations.md](operations.md). The manual steps are below.

### Grant admin consent for Entra Kerberos
Entra ID → **App registrations** → **All applications** → `[Storage Account] <storage>.file.core.windows.net` → **API permissions** → **Grant admin consent**.
([Microsoft docs](https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable#grant-admin-consent-to-the-new-service-principal))

### Exclude the storage app from MFA Conditional Access
Kerberos ticket requests for the share can't satisfy MFA. Exclude the `[Storage Account] …` app from Conditional Access policies that require MFA for all resources. Security Defaults has no exclusion, so a tenant that still has it on needs it replaced by Conditional Access first ([setup-azure-account.md](setup-azure-account.md#security-defaults)).

### NTFS permissions
The share's default root ACL lets every authenticated user modify every folder. Harden it before production use. Mount the share from a session host while signed in as a member of **AVD Admins** (Elevated Contributor) and apply the FSLogix-recommended ACL:

```powershell
net use P: \\<storage>.file.core.windows.net\profiles
icacls P: /inheritance:r
icacls P: /grant "CREATOR OWNER:(OI)(CI)(IO)(M)"
icacls P: /grant "<AVD Users group>:(M)"            # this folder only
icacls P: /grant "<AVD Admins group>:(OI)(CI)(F)"
icacls P: /remove "Authenticated Users" "Users"
```

Configuring ACLs for Entra identities depends on your identity type (hybrid vs cloud-only). Follow [Configure directory and file-level permissions](https://learn.microsoft.com/azure/storage/files/storage-files-identity-configure-file-level-permissions).

## 6. Verify

`./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix <prefix> -Environment <env> -TestUserUpn <user>` deploys a demo host pool and validates everything below automatically ([operations.md](operations.md)). To check by hand:

- **Host pool** → Session hosts: every host **Available**.
- A member of AVD Users signs in to the [Windows App](https://windows.cloud.microsoft) and opens the desktop.
- On the host, `frx list-redirects` or the `Microsoft-FSLogix-Apps/Operational` log shows the profile attached from `\\<storage>.file.core.windows.net\profiles`.
- **AVD Insights** (host pool → Insights) shows data within about 15 minutes.

## 7. Day-2 operations

- **Scale out:** raise `sessionHostCount` and redeploy. Existing hosts are untouched (their run commands see `IsRegistered = 1` and exit).
- **Redeploying while auto shutdown has the hosts locked** (a budget alert): `deploy.sh` refuses, because the deployment would start the hosts, replace the lock and exclusion tags and turn Start VM on Connect back on. Run Resume first, or pass `--unlock` ([operations.md](operations.md#auto-shutdown)).
- **Redeploying with hosts stopped:** a deployment updates the hosts' run commands, which Azure allows only on a running VM. `deploy.sh` starts any host that isn't running, says so, and deallocates it again afterwards, so the power state stays as it was ([lesson 0026](../build/lessons/0026-redeploy-stopped-hosts.md)).
- **New image:** change `sessionHostImage` or move to an Azure Compute Gallery image. Replace hosts by deploying a new `sessionHostNamePrefix`, drain the old hosts, then delete them. A golden image pipeline with resumable rotation is proposed in [image-pipeline-spec.md](../build/specs/image-pipeline-spec.md).
- **Exclude a host from autoscale:** tag the VM `avd-scaling-exclude`.
- **Break-glass sign-in:** **VM → Reset password** sets a new local admin password on any host. The Key Vault secret `sessionhost-localadmin-password` (AVD Admins have Secrets User, readable from inside the VNet) holds the password of the hosts created by the latest deployment.

## 8. Teardown

1. Recovery Services vault → Backup items → Azure Storage (Azure Files) → **Stop backup** and delete the data. Registration puts a delete lock on the storage account.
2. `az group delete` the five `rg-<prefix>-<env>-*` groups (hosts first).
3. Remove the `avdlz-*` policy assignments and their role assignments, the budget, and set Defender plans back to Free if you want.
4. Delete the session hosts' device objects from Entra ID and Intune, and purge the storage app (`[Storage Account] <account>.file.core.windows.net`) from Entra's deleted applications. The next deployment reuses the storage account name.
5. Key Vault is soft-deleted with purge protection, and its name stays reserved for 90 days. To redeploy with the same prefix, the pre-deployment preflight with `-Fix` recovers it. See [gotchas](gotchas.md#key-vault-name-after-teardown).
