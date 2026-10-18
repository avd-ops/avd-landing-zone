# Operations scripts (Cloud Shell)

PowerShell scripts in [`scripts/ops/`](../scripts/ops) that run against a **deployed** landing zone from Azure Cloud Shell:

| Script | What it does |
|---|---|
| `Test-AvdLandingZoneReadiness.ps1 -PreDeployment` | Preflight **before** deploying: is this subscription and tenant ready for the landing zone your parameter file describes? Check mode by default; `-Fix` remediates. |
| `Test-AvdLandingZoneReadiness.ps1` | Preflight **after** deploying: is the landing zone ready for session hosts and users, **including the three post-deployment tenant steps**? Check mode by default; `-Fix` remediates. |
| `Deploy-AvdDemo.ps1` | Deploys a demo host pool and session host into the landing zone, then validates that a user can sign in. |
| `Remove-AvdDemo.ps1` | Removes the demo. `-IncludeLandingZone` tears down the whole landing zone. |
| `Connect-AvdLandingZone.ps1` | Signs in to Microsoft Graph once for the whole Cloud Shell session; the other scripts reuse the sign-in ([decision 0016](decisions/0016-graph-operator-app.md)). |
| `Initialize-AvdGraphApp.ps1` | One-time, by an administrator: creates the avd-opsbot app, so operators sign in with no consent prompts. |
| `Test-AvdUserConnection.ps1` | After you open the desktop: confirms from Azure telemetry that your sign-in reached it (Verified, Failed or Not verified). The deployment portal's Verify access step ([decision 0014](decisions/0014-verify-access.md)). |

They share `AvdLandingZone.psm1`. The landing zone's resources, Entra groups and AVD service principal are discovered from its naming convention and the role assignments it created, so the only required inputs are `-NamePrefix` and `-Environment`.

## Running them

```powershell
# Cloud Shell (PowerShell), in the landing zone subscription
git clone https://github.com/nickprignano/avd-landing-zone.git
cd avd-landing-zone
Set-AzContext -Subscription '<landing zone subscription>'

# 0. Sign in to Microsoft Graph once for this session (one device code; the scripts below reuse it).
#    With the operator app (see below), set its client ID first: $env:AVD_GRAPH_CLIENT_ID = '<client ID>'
./scripts/ops/Connect-AvdLandingZone.ps1

# 1. Before deploying: repeat until it comes back clean (-Fix remediates what it can).
#    -Location picks the region; omit it for the file's default (northcentralus).
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins'
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' -Fix

# 2. Deploy, as a separate run (the clean preflight prints this command)
bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins'

# 3. After deploying
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev          # check
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix     # fix
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -WellArchitected -SkipTenant -SkipNtfs   # Well-Architected review
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn alex@contoso.com
./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix avdlz -Environment dev

# 4. After opening the desktop: did the connection reach it? (waits up to 15 minutes for the logs)
./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev
```

### Microsoft Graph sign-in

In Cloud Shell, a Microsoft Graph sign-in uses a device code: the script prints a code and waits until you enter it at https://microsoft.com/devicelogin (it times out after 120 seconds). Every script asks for the same scopes ([decision 0016](decisions/0016-graph-operator-app.md)), so the first sign-in covers the rest of the session. Sign in up front with `./scripts/ops/Connect-AvdLandingZone.ps1`, so a code can't time out in the middle of a run (lesson 0029). It checks the sign-in with a real request and warns about any scope the token is missing.

Scopes: `Application.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Group.ReadWrite.All`, `Directory.Read.All`, `Device.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`. These are delegated: a script can do no more than your Entra ID roles allow (the table below).

**The operator app (recommended).** Without it, the scripts sign in through Microsoft's shared "Microsoft Graph Command Line Tools" app, which needs consent for these scopes: an administrator's, for the ReadWrite ones. An administrator runs this once per tenant:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git checkout -q master; git pull -q --ff-only
./scripts/ops/Initialize-AvdGraphApp.ps1 -SaveToProfile    # -OperatorsGroup 'AVD Admins' by default; -WhatIf to preview
```

It creates (or repairs) the **avd-opsbot** app registration: a public client with no secret or certificate, the delegated permissions above (`Device.ReadWrite.All` is granted but not shown under the app's API permissions, because Graph doesn't list it; lesson 0030), admin consent granted once, and **Assignment required** on. It assigns you and the operators group (default `AVD Admins`; assigning a group needs Microsoft Entra ID P1). Only assigned people can sign in through it, and its sign-ins appear under its own name in the sign-in logs, where Conditional Access can target it. It needs a Global Administrator, or a Privileged Role Administrator with an Application Administrator, and signs in through Microsoft's default app for that one run. Running it again changes only what is missing.

The scripts use the app when `$env:AVD_GRAPH_CLIENT_ID` holds its client ID (or `Connect-AvdLandingZone.ps1 -ClientId`), and fall back to Microsoft's default app without it. The client ID is not a secret. `-SaveToProfile` adds the line that sets it to your PowerShell profile; Cloud Shell keeps the profile only when it has a storage account, so in an ephemeral session set it again, or put it in the deployment portal's settings, which add it to every command that signs in.

**How long the sign-in lasts.** The sign-in belongs to the Cloud Shell session. Every script run in that session reuses it, until the session ends or you run `Disconnect-MgGraph`. In the first real run (2026-10-18) one device code covered the pre-deployment preflight, the post-deployment `-Fix`, the demo and its cleanup, about 19 minutes. With `AVD_GRAPH_CLIENT_ID` set, a sign-in through another app is not reused: the next script signs in once through the operator app. It does not survive a Cloud Shell reconnect: the second real run (2026-10-18) showed that a reconnect starts a new session, and `Get-MgContext` comes back empty. After a reconnect, set `AVD_GRAPH_CLIENT_ID` again (or keep it in your profile with `-SaveToProfile`) and run `Connect-AvdLandingZone.ps1` again. It reuses a sign-in that still works and asks for a new code only when it doesn't.

**Earlier name.** The app was first created as `AVD Landing Zone Operator`. Running `Initialize-AvdGraphApp.ps1` again renames that app and its enterprise application to `avd-opsbot` in place, so the client ID, the consent and the assignments stay. No token is stored by these scripts.

Required roles:

| For | Azure | Entra ID |
|---|---|---|
| Pre-deployment preflight | Reader (check); Owner or Contributor to register providers with `-Fix` | Directory Readers (check); Groups Administrator + Application Administrator with `-Fix` (creates groups and the AVD service principal) |
| Preflight (check) | Reader on the subscription, plus Role Based Access Control Administrator on the storage account for the NTFS step (it grants a temporary role) | Global Reader (or Security Reader + Directory Readers) |
| Well-Architected review (`-WellArchitected`) | Reader on the subscription | — (with `-SkipTenant`) |
| Preflight `-Fix` | Owner, or Contributor + Role Based Access Control Administrator | Cloud Application Administrator **and** Conditional Access Administrator |
| Demo deploy | Owner, or Contributor + Role Based Access Control Administrator | Global Reader (Cloud Application Administrator with `-FixNtfs`) |
| Cleanup | Owner | Intune Administrator + Cloud Device Administrator (to remove device objects); Cloud Application Administrator (to purge the storage app from deleted items) |

## Sizing and cost

The portal's **Size the host pool** step starts from the **minimum viable kit**, the same as `parameters/dev.bicepparam`: one `Standard_E4as_v5` host and a 100 GiB profile share. You choose the number of hosts (1–50). The portal shows the sessions they carry, and warns when that is fewer than the people expected at the busiest time or when a single host leaves no redundancy.

Choose **Automatic** to size the host pool from how many people use it, how many are signed in at the busiest time, and how they work instead. It uses Microsoft's multi-session guidance: light 6, medium 4, heavy 2 and power 1 user per vCPU. Only Automatic adds a spare host, and in prod it never goes below two hosts. A number you choose is kept as it is.

It **suggests memory-optimized E-series** sizes: E4as_v5 for light work, E8as_v5 for medium and heavy, and E16as_v5 for power users. Hosts shared by many users run out of memory before CPU, and E-series has 8 GiB per vCPU against 4 on D-series. Every host has a **Premium SSD** OS disk. The template and both parameter files default to `Standard_E4as_v5`.

**Memory warnings.** Both the portal and the preflight warn below 1 GiB of memory per session on any size. On a D-series size they warn below 1.5 GiB and name the E-series equivalent.

**Existing landing zones.** When the landing zone already runs a different size (the first deployments used `Standard_D4as_v5`), the preflight warns that deploying resizes the hosts, and that each one restarts. To keep the current size, pass it with `--vm-size`. The post-deployment quota check and the demo host pool use the deployed hosts' size unless you give one.

The Well-Architected review checks that every OS disk is Premium SSD. It gives the host count, VM size, sessions per host, the vCPU quota needed and the profile share size. In prod it adds a spare host by default and never goes below two. Once applied, the commands carry the sizing:

```powershell
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam -Location northcentralus -UsersGroup 'AVD Users' -AdminsGroup 'AVD Admins' `
  -SessionHostCount 3 -SessionHostVmSize Standard_D8as_v5 -MaxSessionLimit 32 -ProfileShareQuotaGiB 600 -ActiveHoursPerWeek 50
bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins' --hosts 3 --vm-size Standard_D8as_v5 --max-sessions 32 --profile-quota 600
```

**The preflight validates that sizing, not the file's.** It checks the VM size in the region and zones, and family and regional vCPU quota for that many hosts. When quota is short, the portal builds the quota request. It warns above 6 sessions per vCPU.

**It also prices the plan** from the public [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) for the region, at pay-as-you-go list prices in USD. The estimate covers:
- session hosts, at the base compute rate for `-ActiveHoursPerWeek` (multi-session Windows is licensed per user);
- their P10 OS disks;
- the provisioned profile share;
- private endpoints;
- the NAT Gateway and its public IP.

**The Cost step** comes after sizing. Two toggles decide most of the cost, because they decide how long the hosts run:

| Start VM on Connect | Scheduled auto shutdown | Each host runs about |
|---|---|---|
| on | on | the hours people work (default 50 a week): hosts start on the first connection and stop at the scheduled time |
| off | on | from the scaling plan's 07:00 weekday ramp-up to the stop time (65 hours for 20:00), whether or not anyone uses them |
| either | off | around the clock (168 hours): nothing turns them off every day, and disconnected sessions keep hosts up |

The toggles start at what the parameter file deploys: dev and test stop at 20:00, prod has no scheduled stop, and Start VM on Connect is on in all of them. Changing them adds the settings to the commands (`deploy.sh --auto-shutdown 20:00|none --start-vm-on-connect true|false`, preflight `-AutoShutdownTime -StartVmOnConnect`), and the preflight is priced for the hours they imply. Once a preflight has priced the plan, the Cost step reprices it in the page when you change a toggle, the hours, the host count or the profile share. A different VM size or region needs the preflight again. With Start VM on Connect off, the host pool is tagged `avdlz-start-vm-on-connect = false`, and the auto-shutdown Resume keeps it off.

The estimate also shows the cost if the hosts ran around the clock. Usage-based charges are listed as not included: Log Analytics, data processed, backup, Defender and licenses. Each line must match exactly one price meter. A line that matches none, or several, is reported with the meters the API returned instead of being guessed, and is left out of the total. The portal shows the estimate after you paste the output. Reservations, savings plans and agreements lower these prices.

The sizing covers one pooled host pool, which is what the landing zone deploys. The portal keeps it as a list of host pools, so more can be added later ([decision 0010](decisions/0010-sizing-and-cost.md)).

## Pre-deployment preflight

`-PreDeployment` works before the landing zone exists. To choose the region, use the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/): it builds this command with `-Location` set to the region you pick, and reads the output to tell you the next step. It compiles your `.bicepparam` file with the real group and service principal IDs and checks the subscription and tenant against the **effective** values (file values, else template defaults). Once it comes back clean, it prints the `deploy.sh` command to run as a separate step.

| Area | Check | `-Fix` |
|---|---|---|
| Tooling | PowerShell 7, Bicep CLI, `az` and `bash` (used by `deploy.sh`), Microsoft.Graph.Authentication | — |
| Entra ID | `-UsersGroup` / `-AdminsGroup` (name or object ID) resolve to exactly one security group each, with members; the Azure Virtual Desktop service principal exists | Creates missing groups (by name) and the service principal. `-AddMeToGroups` (separate switch) adds you to both groups |
| Parameters | The file compiles, with `-Location` overriding its region; prints prefix, environment, region, host count and size, zones, connectivity mode, Intune enrollment | — |
| Subscription | Owner, or Contributor + RBAC Administrator, plus policy rights when `enablePolicyGuardrails`; every resource provider `deploy.sh` needs; AVD host pools offered in the region; `EncryptionAtHost` (when used); VM size offered in **every requested zone**; family and regional vCPU quota for the host count; the profile storage SKU (Premium ZRS/LRS file shares) in the region; no soft-deleted, purge-protected Key Vault holding the vault name; budget parameters complete | Registers providers and the feature and **waits** for them (up to 15 minutes; the feature takes about that long), then re-registers `Microsoft.Compute` so the feature takes effect. Recovers a soft-deleted vault into its resource group (created again if the cleanup removed it), so a redeploy keeps the name prefix |
| Network | HubPeered only: hub VNet readable; firewall IP set for egress; central DNS zone IDs present | — |
| Landing zone | Whether `rg-<prefix>-<env>-*` already exists (deploying then updates in place), and fails if it exists in another region (resource groups can't move) | — |
| Tenant | Intune licensing when `enrollInIntune = true` (the join fails without it); whether you hold active roles for the post-deployment steps; which Conditional Access policies will need the storage app excluded; whether Security Defaults is on (a warning: it can't exclude the storage app) | — |

## Post-deployment preflight: what it checks and fixes

| Area | Check | `-Fix` |
|---|---|---|
| Tooling | PowerShell 7, Bicep CLI, Microsoft.Graph.Authentication | — |
| Subscription | Your RBAC; resource providers; `EncryptionAtHost` feature; VM size offered in the region and zones; family and regional vCPU quota | Registers providers and the feature, waits for them, then re-registers `Microsoft.Compute` |
| Landing zone | The five resource groups; VNet, storage, Key Vault, Log Analytics, AVD Insights DCR, host pool; Entra Kerberos on the storage; storage and AVD private endpoints with DNS zone groups | — |
| RBAC | AVD Users/Admins groups and AVD service principal assignments; SMB Share Contributor for AVD Users | — |
| Entra ID | Both groups have members; the tenant has Intune licensing | — |
| **Step 1** | Admin consent for `[Storage Account] <account>.file.core.windows.net`; the `kdc_enable_cloud_group_sids` tag, so Kerberos tickets carry cloud-only group SIDs | Grants tenant-wide consent for the scopes the app requests; adds the tag |
| **Step 2** | Every enabled Conditional Access policy that requires MFA (or an authentication strength) for **all** apps and covers AVD users excludes the storage app. Policies scoped to other users or roles are reported for review. Security Defaults being on is a warning, since it has no per-app exclusion | Adds the storage app to the policy's excluded applications. **You confirm each policy** unless `-Force` |
| **Step 3** | The profile share root ACL matches FSLogix guidance: inheritance cut; SYSTEM, Administrators and AVD Admins full control; CREATOR OWNER modify on subfolders; AVD Users modify on this folder only; no write for Authenticated Users, Users or Everyone | Replaces the root ACL |

### How the NTFS step works

The profile share is private and SMB-only, so Cloud Shell can't reach it. The check runs **on a session host** through Run Command:

1. The host's managed identity gets a temporary *Storage File Data Privileged Reader* role on the storage account, or *Privileged Contributor* with `-Fix`.
2. On the host, the script reads the share root's security descriptor through the Azure Files REST API with backup intent, and sets it when fixing. No SMB mount or user ticket is involved.
3. The role is removed again, even if the check fails.

Role assignments can take a few minutes to reach the storage data plane, so the script retries for up to about six minutes. By default it uses a running host in `rg-<prefix>-<env>-hosts`. Use `-NtfsHostName` to pick one, or `-AllowHostStart` to start a stopped host and deallocate it afterwards. `Deploy-AvdDemo.ps1` runs the same check from the demo host.

Group SIDs are the synced group's on-premises SID when it has one, otherwise the Entra `S-1-12-1-…` SID.

## Demo deployment

`Deploy-AvdDemo.ps1` deploys [`bicep/demo/main.bicep`](../bicep/demo/main.bicep) into `rg-<prefix>-<env>-demo`:
- Pooled host pool (validation ring), desktop app group, workspace.
- `-SessionHostCount` hosts (default 1), built by the landing zone's own `controlPlane` and `sessionHosts` modules.
- The existing spoke, profile share, Log Analytics, DCR, private DNS, groups and AVD service principal.
- No scaling plan, so the host stays up while you test. The host pool private endpoint lives in the demo RG, so cleanup removes it.

It then validates sign-in readiness:

| Area | Validation |
|---|---|
| Host pool | Every host **Available**, accepting new sessions, all AVD health checks passing (waits up to `-TimeoutMinutes`) |
| Host configuration | `Configure-FSLogix` and `Register-AvdAgent` run commands succeeded; on the host: Entra joined, Intune enrolled, agent registered, FSLogix and Entra Kerberos configured, profile share resolves to a private IP and answers on TCP 445 |
| Access | AVD Users hold Desktop Virtualization User on the demo app group, VM User Login on the demo RG, and SMB Share Contributor on the storage |
| Tenant | Steps 1–3 as above (check only; `-FixNtfs` applies the ACL) |
| Test user | With `-TestUserUpn`: enabled, a member of AVD Users (including nested groups), licensed |

The demo host's break-glass password is random and isn't stored anywhere. Use **VM > Reset password** if you need it.

## Cleanup

`Remove-AvdDemo.ps1` removes:
- the demo resource group;
- its deployment record;
- the demo hosts' Entra ID and Intune device objects (`-KeepDevices` keeps them).

If the Microsoft Graph sign-in times out, the script keeps the deployment record, which names the hosts. Run it again to finish the device objects ([lesson 0029](lessons/0029-device-cleanup-rerun.md)).

It supports `-WhatIf`.

With `-IncludeLandingZone`, you must type the landing zone name to confirm (`-Force` skips this). It then removes:
1. **Profile backup.** It disables vault immutability and soft delete, which would otherwise block the delete. It stops protection, deletes the recovery points, and unregisters the storage account, which releases the backup delete lock.
2. **The five landing zone resource groups**, in dependency order. First it deletes the Log Analytics workspace permanently. Deleting its resource group would only soft-delete it for 14 days, and the next deployment under the same name would recover it and fail on the AVD Insights data collection rule ([lesson 0023](lessons/0023-log-analytics-soft-delete.md)).
3. **Subscription-level resources:** `avdlz-*` policy assignments with their role assignments, the budget, the activity-log diagnostic setting, and deployment records.
4. **The landing zone hosts' device objects.**
5. **The storage account's Entra app.** Deleting the storage account moves its Entra Kerberos app (`[Storage Account] <account>.file.core.windows.net`) and service principal to Entra's deleted items for 30 days. They still list the account's names, and the next deployment reuses the name, so the cleanup purges them. It waits up to 2 minutes for them to appear there.
6. **Defender plans**, set back to Free, only with `-ResetDefender`.

**Another landing zone in the subscription** (for example `parameters/test.bicepparam` beside dev, [demo.md](demo.md)) keeps what it still uses. The cleanup skips the policy assignments, keeps an activity log export that sends to the other landing zone's workspace, and removes only this landing zone's deployment records.

The Key Vault stays soft-deleted under purge protection for 90 days. To redeploy with the same prefix, run the pre-deployment preflight with `-Fix`, which recovers it.

## Auto shutdown

The landing zone deploys an Azure Automation runbook, [`scripts/automation/Invoke-AvdPowerAction.ps1`](../scripts/automation/Invoke-AvdPowerAction.ps1), with three actions (see [decision 0011](decisions/0011-auto-shutdown.md) for why it is built this way):

| Action | What it does | Started by |
|---|---|---|
| **Stop** | Deallocates the session hosts that have no user sessions (`-Force $true` stops the rest too). The scaling plan and Start VM on Connect still start hosts when users come back. | The schedule (`autoShutdownTime`, `autoShutdownDays`, `autoShutdownTimeZone`; `autoShutdownScheduleAction`) |
| **Lock** | Drains every host, adds the scaling plan's exclusion tag, turns off Start VM on Connect, sends signed-in users a message, and deallocates every host. The host pool is tagged `avdlz-power-lock` with the reason and time. Nothing starts again until Resume. | The budget: at `autoShutdownBudgetPercent` (default 100%) of actual monthly cost (`autoShutdownBudgetAction`) |
| **Resume** | Undoes Lock. Hosts start on the next connection or the scaling plan's ramp-up. | You |

- **Parameter file defaults:** `dev.bicepparam` stops idle hosts at 20:00 Central every day. Both files lock the hosts on a budget alert. The portal's Cost step, or `deploy.sh --auto-shutdown HH:mm|none`, changes the scheduled stop (`AVD_AUTO_SHUTDOWN_TIME`).
- **The budget trigger needs a budget:** set `AVD_MONTHLY_BUDGET` and `AVD_ALERT_EMAIL` before `deploy.sh`. The budget covers the whole subscription. Budgets are evaluated a few times a day, so a lock follows the overspend by hours, not minutes.
- **Checking:** the post-deployment preflight warns while the hosts are locked and gives the Resume command, and so does the portal.

Run it by hand from Cloud Shell, with your own sign-in (`-WhatIf` shows what it would do):

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git checkout -q master; git pull -q --ff-only
./scripts/automation/Invoke-AvdPowerAction.ps1 -Action Resume -NamePrefix avdlz -Environment dev
```

**How it runs**
- Two Logic Apps start the runbook job with their managed identities (Automation Operator on the Automation account): one on the schedule, one called by the budget's action group.
- The runbook acts with the Automation account's managed identity:
  - Desktop Virtualization Contributor on `rg-<prefix>-<env>-avd`;
  - Desktop Virtualization Power On Off Contributor and Tag Contributor on `rg-<prefix>-<env>-hosts`.
- The runbook runs in Windows PowerShell 5.1 with no modules, calling ARM with the identity's token.
- Automation downloads it from GitHub at deployment time: `deploy.sh` pins it to the commit being deployed (`AVD_RUNBOOK_URI`), or uses `master` if that commit isn't on GitHub.
- Job output is in the Automation account (Jobs) and in Log Analytics.

## Well-Architected review

`-WellArchitected` adds a review of the **deployed** landing zone against the [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/), grouped by pillar and ending with a scorecard. It needs only Reader; add `-SkipTenant -SkipNtfs` to leave out the tenant steps (no Graph sign-in). Findings are **warnings, never failures**: they are trade-offs to review, not deployment blockers. Why it is built this way: [decision 0009](decisions/0009-well-architected-review.md).

| Pillar | Checks |
|---|---|
| Reliability | At least two session hosts; hosts in availability zones (and whether the region has any); zone-redundant profile storage; share soft delete; profile share backup; Azure Advisor reliability recommendations |
| Security | Defender for Cloud plans for servers, storage and Key Vault; Trusted Launch and encryption at host; storage TLS 1.2, HTTPS only and no shared keys; Key Vault purge protection, RBAC and private access; open Defender for Cloud recommendations on landing zone resources |
| Cost Optimization | A budget; a scaling plan enabled on the host pool; Advisor cost recommendations |
| Operational Excellence | Azure Monitor Agent on every session host; host pool diagnostics to Log Analytics; log retention of 90 days or more; Azure Policy compliance of the landing zone resource groups; Advisor recommendations |
| Performance Efficiency | Accelerated networking on the session hosts; Advisor recommendations |
| All | **PSRule for Azure** on the live resources, with the same rules and suppressions CI applies to the templates, so drift since deployment shows up. It installs `PSRule.Rules.Azure` on first use and takes a minute or two; `-SkipPSRule` leaves it out |

**Expected in dev.** `parameters/dev.bicepparam` keeps costs down on purpose: one host, locally redundant storage, no backup, Defender off, 30-day logs, no budget, and a region without zones by default. In dev and test those findings say *Expected in dev* and the scorecard counts them separately; in prod the same findings are plain warnings. `parameters/prod.bicepparam` fixes most of them; availability zones also need a region that has them.

**PSRule on live resources** also evaluates the subscription itself, so it can report settings the landing zone doesn't manage: Defender for Cloud security contacts and provisioning, PIM for privileged roles, a Service Health alert (the landing zone deploys one only when `AVD_ALERT_EMAIL` is set). These are real findings for a review; fix them in the subscription. Rules that can't read this design are suppressed with the reason in `.ps-rule/Suppressions.Rule.yaml` (NAT Gateway public IPs, encryption at host instead of Azure Disk Encryption). PSRule's export doesn't attach VM extensions, so `Azure.VM.AMA` can't see the agent; the review checks the agent itself and drops that finding for hosts where it is installed and Succeeded. Each finding shows the rule's reason.

**Limits.** Advisor and Policy evaluate on their own schedule (about once a day), so a landing zone deployed today can look cleaner than it is; run the review again the next day. Microsoft's [Well-Architected assessment](https://learn.microsoft.com/assessments/) for Azure Virtual Desktop is a questionnaire about your requirements (recovery targets, operations, support) that no script can answer; this review gives you the evidence for most of its questions.

## Deployment portal

Every script ends with a machine-readable line (`<<<AVDLZ-STATE {...} AVDLZ-STATE>>>`): the stage, whether it passed, the context for the next command, and each failure with a stable id. Paste the output into the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) and it tells you what to run next. The format is described in [`docs/portal/README.md`](portal/README.md).

If the portal gives the wrong advice or you are stuck, use **Report a problem** in the portal. It builds a GitHub issue from the output you pasted. Before anything leaves your browser, it removes email addresses, IDs, subscription and resource names, your name prefix and group names, and secrets. You review the report, tick that it contains nothing private, and submit it on GitHub. Issues are public.

## Exit codes

Preflight and demo return **0** when nothing failed and **1** otherwise, so you can use them in pipelines. Warnings don't fail the run. `-PassThru` on the preflight returns the result objects instead.

## Verify access: `Test-AvdUserConnection.ps1`

Confirms from the connection logs that a real sign-in reached the desktop ([decision 0014](decisions/0014-verify-access.md), [spec](verify-access-spec.md) §6.5). Open the desktop first, as yourself, then run it in Cloud Shell:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone }
Set-Location ~/avd-landing-zone; git checkout -q master; git pull -q --ff-only
./scripts/ops/Test-AvdUserConnection.ps1 -NamePrefix avdlz -Environment dev
```

- **What it reads:** `WVDConnections`, `WVDErrors` and `WVDCheckpoints` in the landing zone's Log Analytics workspace, for one user (`-UserPrincipalName`, default: you) in the last `-SinceMinutes` (60). The query is [`scripts/ops/kql/user-connection.kql`](../scripts/ops/kql/user-connection.kql), commented column by column. `-Demo` checks the demo host pool's desktop.
- **Waiting:** connection logs usually reach Log Analytics 3 to 10 minutes after the connection. The script checks every `-PollSeconds` (60) until `-TimeoutMinutes` (15); `0` checks once.
- **Results:** *Verified* when a connection reached Connected. *Failed* when AVD logged errors and nothing connected; the codes and messages are shown. *Not verified* when nothing is logged yet, a connection hasn't reached Connected, or the query couldn't run. Only *Verified* exits 0. A missing row is never a pass.
- **The time it shows** is connection setup (Started to Connected). It isn't AVD Insights' "time to connect", which includes logon, and it isn't the time to a usable desktop. A first connection to a stopped host includes the host starting (Start VM on Connect), so it isn't steady state.
- **Permissions:** read access to the workspace's data, for example Log Analytics Reader on the management resource group. Owner or Contributor on it also works. A 403 says which role to grant.

