# Spec: backup, recovery and disaster recovery

- **Status:** Proposed, partly built (offline only, nothing has run against a real tenant, no spend): the recovery region setting, the preflight's Recovery checks and the vaulted tier's key access setting (sections 4.1 and 6.1). The rest is planned in the landing zone itself.
- **Date:** 2026-10-20
- **Scope:** what a landing zone deployed by this repo needs to come back after a loss (a deleted resource, a bad change, a lost subscription or a region outage), using the same plumbing as the run recorder: run folders, hash manifests, verified copies, the private companion repo and the copy hook. The default landing zone deployment does not change: everything here is opt-in, except one check that reports what is and isn't protected.
- **Same-tenant recovery lives here** (the owner, 2026-10-20). Any region and any subscription the operator can deploy to inside their own tenant is in scope for this repo. Recovery into a separate tenant, another cloud, and recovery run on a schedule without an operator are outside it; anything that offers them builds on these scripts and their run records instead of repeating them.
- **Builds on:** the run recorder spec (`build/specs/run-recorder-spec.md`, draft PR #72: R9, sections 6.3, 6.5, 9.2, 9.3 and 9.3a), avd-second-brain decisions 0016 (never delete the last copy) and 0017 (never leave the meter running), draft PR #37, and contract C17 `avd-run-record/v1` (avd-second-brain draft PR #36).

This is a personal project, not for production, provided as is. Section 12 lists every fact this spec relies on, where it was checked, and what is still unverified.

## 1. Summary

Microsoft's own page says it plainly: Azure Virtual Desktop has no native disaster recovery features; you build it from other Azure services (F1). Microsoft runs the control plane and fails it over itself (F2). Everything else is the operator's: session hosts, profiles, applications, user data and identities (F1).

The landing zone already has some of it: the Bicep in git rebuilds every resource, the profile share has a daily Azure Backup, the Key Vault has soft delete and purge protection, and the image pipeline publishes to a Compute Gallery. What it lacks is the part that turns those pieces into recovery:

1. **A list of what must survive, and where its copy is.** Each protected item is either *rebuilt* from code or *restored* from a copy, and the spec says which (section 3).
2. **Recovery tiers** with a target recovery point (RPO) and recovery time (RTO) and a monthly cost, so an operator chooses with numbers (section 4).
3. **A read-only status check** that says, for each item, when its last good copy was made and whether the tier's RPO is met (section 6).
4. **A configuration snapshot**: the runtime settings that aren't in the Bicep, exported into a run folder and copied to the private companion repo with the recorder's own `-CopyTo` (section 7).
5. **Recovery tests** an operator runs by hand: restore into a new place, check it, measure the real RPO and RTO, tear it down under the family conventions (section 8).
6. **A monthly verify routine** that re-reads every copy against its manifest (section 9).

Every recovery action is a run: it writes a C17 run record with a new use case, `recovery` (section 10), so backups, copies, tests and restores are resumed, costed and torn down the same way as a landing zone run.

## 2. Goals and non-goals

### Goals
1. An operator can answer "if this subscription were gone tomorrow, what would I lose, and how long would it take to come back?" with one read-only command.
2. Every item has a known copy outside what a teardown or a mistaken delete would remove (decision 0016), or the status check says it doesn't.
3. Recovery is proven by a test the operator runs, with measured RPO and RTO in the run record, not assumed from a feature's description.
4. The basic tiers use only free GitHub features and Azure features in the operator's own subscription. Nothing here needs another product.

### Non-goals
- **Backing up Microsoft-managed components.** The AVD control plane, Entra ID itself and Microsoft 365 data are Microsoft's (F2, F10). OneDrive and SharePoint resilience is out of scope, as it is in Microsoft's multiregion guide (F3).
- **Copying secrets anywhere.** Secrets are regenerated on recovery, never exported (section 3.3).
- **Active-active host pools.** Microsoft describes them as complex and costly (F4); they are listed in section 4 for completeness only.
- **Copies beyond this repo's targets.** Copies outside the operator's own tenant and their companion repo go through the copy hook to an archive the operator chooses (run recorder section 9.2 step 4); this spec only defines what it hands to the hook.

## 3. What to protect

### 3.1 The inventory

| # | Item | What it holds | Data or disposable (0016) | How it comes back | Copy today | Copy this spec adds |
|---|---|---|---|---|---|---|
| P1 | **Infrastructure as code**: `bicep/`, parameter files, scripts | Every resource definition | Disposable once in git | Redeploy from a pinned commit | git (GitHub) | The run record names the commit and parameters (no secrets) of every deployment, so a rebuild uses the same ones |
| P2 | **Runtime configuration not in the Bicep**: app group assignments, host pool properties changed in the portal, scaling plan schedules, drain mode, RBAC added by hand, diagnostic settings | How the estate is actually set | Data | Re-applied from a snapshot after redeploy | None | Configuration snapshot (section 7) |
| P3 | **FSLogix profile containers** (`profiles` share) | Users' profiles | Data, personal | Restored from backup | Azure Backup, snapshot tier, daily, 30 days (`bicep/modules/backup.bicep`) | Optional vaulted tier (R1); optional Cloud Cache to a second share (R2); export before teardown (section 11) |
| P4 | **Golden images** (Compute Gallery versions) | The built OS and apps | Data until rebuilt and tested | Replica in the recovery region, or rebuild from the image template in git | Gallery, source region only | Second-region replica (R1); the image record in the run folder |
| P5 | **Key Vault**: break-glass local admin password, any certificates | Secrets | Disposable by design: regenerated | New vault, new secret, hosts updated | Soft delete and purge protection | None by design (section 3.3) |
| P6 | **Identity configuration**: the AVD user and admin groups, the operator app (avd-opsbot) registration, Conditional Access policies that target AVD | Who may sign in, and how | Data | Restore from soft delete within 30 days, or re-create from the snapshot | Entra soft delete (30 days, some object types only) | AVD-scoped identity snapshot in the configuration snapshot (section 7.2) |
| P7 | **Diagnostics**: Log Analytics AVD tables, Activity Log | What happened | Data | Not restored; kept for evidence | Workspace retention | Already covered: the run recorder exports them to the run folder before cleanup (run recorder 8.1 item 6) |
| P8 | **Run store and companion repo** | Run records, teardown proof, costs, config snapshots, private notes | Data | Re-read from the other copy | The run store and the companion repo copy each other (run recorder 9.2, 9.3) | Monthly verify (section 9); `-CopyTo local` archive of the companion repo |
| P9 | **Knowledge base** (avd-second-brain `docs/knowledge/`) and other public repos | Shared knowledge | Data, public | Clone from GitHub; forks | git (GitHub) and every clone | None needed; the companion repo's README notes how to mirror it |

### 3.2 Not protected here
- Session host VMs in a pooled host pool: they are disposable and rebuilt from P1 and P4 (F5). Personal host pools are not in this landing zone's design; if one is added, Microsoft's guidance is Azure Site Recovery per VM (F6), which is a later decision.
- MSIX or App Attach packages: not deployed by this landing zone today. When they are, Microsoft recommends one storage account per region with each package copied to both (F7).

### 3.3 Secrets are regenerated, never copied
A Key Vault backup can only be restored to a vault in the same subscription and the same Azure geography (F8), so it doesn't help when the subscription is the thing lost, and copying a secret anywhere else breaks the rule that secrets never leave their vault. Recovery therefore creates a new vault and generates new values the same way `deploy.sh` does today, writes them only to the new vault, and records in the run record that each secret was *regenerated*, never its value. The break-glass password changes on recovery; nobody has to remember the old one.

## 4. Recovery tiers

The numbers in the RPO and RTO columns are Microsoft's estimates where Microsoft gives one (F4), and this spec's assumptions otherwise. Microsoft says to treat them as estimates and validate them by testing (F4); section 8 does that. The tier is chosen per landing zone with `-RecoveryTier R0|R1|R2` on the status check and recorded as a tag; it changes nothing by itself.

| Tier | What it is | RPO | RTO | What it adds over the one before | Uses |
|---|---|---|---|---|---|
| **R0 Rebuild** (today) | Redeploy from git in the same region; profiles from the daily snapshot backup; configuration from the latest snapshot | Up to 24 hours (daily backup) | Hours: a full deployment, a host build and a profile restore (to be measured, section 8) | Configuration snapshot, status check, recovery test | Git, Azure Backup snapshot tier |
| **R1 Restore anywhere** | R0, plus copies that survive the source share and the source region: vaulted backup (an offsite copy in the Backup vault), its geo-redundant option with Cross Region Restore, and a gallery replica in the recovery region | Up to 24 hours (one vaulted copy a day, F9) | Hours, in the recovery region | Vaulted backup, cross-region restore, second-region image replica | Azure Backup vault tier, Compute Gallery replication |
| **R2 Warm standby** (active-passive) | R1, plus a second host pool in the recovery region with hosts deallocated, and FSLogix Cloud Cache writing profiles to a second share there | Seconds to minutes (Cloud Cache lag, F4) | 15 to 60 minutes (Microsoft's estimate, F4) | Standby host pool, second profile share, Cloud Cache, failover procedure | Cloud Cache, application group reassignment |
| R3 Active-active | Both regions serve users | Seconds to minutes | Near zero | Not specified here (non-goal) | |

Rules across tiers:
- **Microsoft doesn't guarantee capacity** for deallocated hosts or a new deployment in the recovery region; only running resources or an on-demand capacity reservation do, and reservations don't (F11). R1 and R2 report this as a warning on every status check, never as met.
- **Availability zones are not disaster recovery** (F12). The landing zone's zonal hosts and ZRS share are high availability; they don't move an item up a tier.
- **Standby is a meter left running** (decision 0017). R2's second share and the hosts' disks bill every day. R2 needs `-KeepRunning <reason>` once, recorded on the standby's tags, and appears in every still-billing list as a standing resource with its daily cost. Without it, R2 isn't deployed.
- **Deallocated hosts must start every 90 days** for a few hours to refresh the token that connects them to the control plane (F13). R2's status check fails a host that hasn't started in 80 days; the start is a scheduled job with its own shutdown, so the meter stops again.

### 4.1 The recovery region and the landing zone's own guardrail
The project's sandbox allowed resource groups only in northcentralus, and the cause was the landing zone itself: its allowed-locations guardrail (`bicep/modules/governance.bicep`) defaulted to `[location]`. Cross-region restore, a gallery replica in a second region and a standby region all need another one. Built:

- `main.bicep` has `recoveryLocation` (empty by default), read from `AVD_RECOVERY_LOCATION` by the dev, test and prod parameter files with the `empty()` guard (lesson 0004). `allowedLocations` defaults to `location` plus `recoveryLocation` when it is set, so the default deployment is unchanged and setting the variable and deploying again opens exactly one more region. A template test guards both.
- The preflight's Recovery section checks the region against every allowed-locations assignment that applies (section 6.1), so a management group's policy that also blocks it is named rather than discovered mid-restore.

For the sandbox: `export AVD_RECOVERY_LOCATION=southcentralus` (northcentralus's pair) before the next deployment. That changes a policy assignment in the owner's subscription, so it waits for the owner's go like any other run.

## 5. Principles

| # | Principle | Source |
|---|---|---|
| D1 | Opt-in; the default deployment is unchanged, except a read-only status check | R1 of the run recorder spec |
| D2 | Restore into a new place, never over the only copy. Overwriting the original location is a delete of what is there, so it needs a verified copy of the current state first, or `-DiscardLastCopy` (0016) | decision 0016 |
| D3 | A copy counts only when it has been read back and matched against a hash manifest, or, for a service backup, when a restore from it has been tested within the tier's test interval | 0016 rule 3; run recorder R9 |
| D4 | Secrets are regenerated on recovery, never copied | section 3.3; CLAUDE.md "never make operators remember secrets" |
| D5 | Every recovery action is a C17 run with use case `recovery`, with a cost estimate first and teardown evidence after | run recorder 6.5, 9.1, 9.3a; decision 0017 |
| D6 | Azure is the source of truth for what is protected: the status check reads backup jobs, recovery points, gallery replication and vault settings from ARM, and the run records add history | run recorder R4 |
| D7 | Every new state the status check reports gets an `id`, a branch in `portal-core.js`, a Node test and an offline scenario; any portal screen for it goes through the design review the family uses for UI | decision 0007 |
| D8 | Nothing in this spec deletes a recovery point, a snapshot or a configuration snapshot except a person through the conventions in section 11 | decision 0016 |

## 6. Status check: `Get-AvdRecoveryStatus.ps1`

Read-only, like `Get-AvdRunStatus.ps1`, and safe to run any time from Cloud Shell. Pure checks in `AvdLandingZone.psm1` (prefix `Get-AvdRecovery...` for functions that only build data), tested offline against `AzMock.psm1`.

For each item in section 3.1 it prints one result with an `id`:

| id | Check | Fails when |
|---|---|---|
| `dr-iac` | The landing zone's last deployment names a commit that exists on the remote | Deployed from an uncommitted or unpushed tree |
| `dr-config` | Age of the newest configuration snapshot with a verified copy | Older than the tier's RPO, or no verified copy |
| `dr-profile-backup` | Last successful backup job and newest recovery point for the profile share | Older than 26 hours, or the last job failed |
| `dr-profile-backup-access` | Whether the profile storage account allows what Azure Backup needs to back up and restore it | Snapshot tier: key access off and public network access not disabled (F19). Vaulted tier: key access off (F14). Same verdict as the preflight's `profile-backup-access` (section 6.1) |
| `dr-profile-offsite` (R1+) | A vaulted recovery point exists and the vault's redundancy and Cross Region Restore match the tier | Snapshot tier only, or Cross Region Restore off |
| `dr-image` | Each gallery image version in use has a replica in the recovery region, or a buildable template at the same commit | No replica (R1+), or template not in git |
| `dr-keyvault` | Soft delete and purge protection on, and the secrets the landing zone needs are listed by name | Either off |
| `dr-identity` | The AVD groups and the operator app exist, and the snapshot's copy of them is within RPO | Missing, or no snapshot |
| `dr-standby` (R2) | Standby hosts started within 80 days, Cloud Cache order correct in each region (local share first, F15), `-KeepRunning` reason present | Any of these |
| `dr-capacity` (R1+) | Quota for the host family in the recovery region | Always at least a warning: quota isn't capacity (F11) |
| `dr-tested` | Date and result of the last recovery test for the tier | None in 90 days |

The last line is a state line the portal can read (`STATE: recovery tier=R0 met=6/9 ...`), and `-AsJson` prints the same results for the run record. A check that can't read something (no permission, API error) reports the full error per lesson 0012, and counts as not met.

### 6.1 Built: the preflight's Recovery section
Some of this belongs in the preflight an operator already runs, so it is there now, as warnings (recovery is optional and never blocks a deployment or a sign-in). Pure functions in `AvdLandingZone.psm1`, unit tests, and offline scenario steps in `PreDeployment` and `PostDeployment`:

| id | Stage | Check | Pure function |
|---|---|---|---|
| `recovery-region-policy` | Both | The recovery region (`-RecoveryLocation` or `AVD_RECOVERY_LOCATION`) is allowed by every enforced allowed-locations assignment at the subscription, inherited ones included. Before deployment, the landing zone's own guardrail counts as allowing it when this deployment adds it. Says whether to deploy again (own guardrail) or ask the assignment's owner (anyone else's) | `Get-AvdLocationPolicyVerdict` |
| `recovery-quota` | Both | vCPU quota in the recovery region for the host size; quota is not capacity (F11), and the remediation says so | |
| `profile-backup-access` | After | F14 and F19 against the account's `allowSharedKeyAccess` and `publicNetworkAccess` | `Get-AvdProfileBackupVerdict` |
| `profile-backup` | After | Protection state, health, last backup status and age (over 26 hours warns), from the vault's protected items. A failed last backup on an account without key access points at `UserErrorStorageKeyBasedAuthenticationNotPermitted` | `Get-AvdProfileBackupVerdict` |

`Get-AvdRecoveryStatus.ps1` maps the same verdicts to `dr-profile-backup` and `dr-profile-backup-access` instead of repeating them. The Well-Architected `profile-backup` check now fails an item whose last backup wasn't healthy, and `storage-hardening` accepts key access when the vault's policy is vaulted (it has `vaultRetentionPolicy`). None of these ids are portal states yet; they show as warnings with their id.

## 7. The configuration snapshot: `Export-AvdConfiguration.ps1`

### 7.1 What it captures
Everything that recovery would otherwise have to reconstruct by hand, read through ARM REST (`Invoke-AvdArm`) and, for identity, AVD-scoped Graph reads through the operator app (`Invoke-AvdGraph`):

- Host pools, application groups, workspaces, applications, scaling plans and their schedules, session host drain state, host pool RDP properties.
- Role assignments at the landing zone's resource groups and the application groups, by principal object ID and role.
- Diagnostic settings, budgets, alerts, auto shutdown schedules and the run store's tags.
- The deployment's parameters as deployed (secret parameters are recorded as *present*, never their value).
- The difference against what the Bicep at the deployed commit would produce, so drift shows up as a finding before it matters.

### 7.2 Identity, scoped to AVD
- The AVD user and admin groups (properties and member object IDs), the operator app's registration (permissions, redirect URIs; no credentials, and it has none), and the Conditional Access policies whose conditions name the AVD apps or these groups, as JSON.
- Microsoft's guidance is to keep configuration such as Conditional Access policies as version-controlled JSON and redeploy the last known-good version, because only some Entra objects are soft deleted and the rest are gone on delete (F10). That's what this snapshot is.
- Tenant-wide settings are out of scope: only objects the landing zone created or its groups target.

### 7.3 Where it goes
The snapshot is a run (section 10): it writes `config/` into a run folder in the run store, with the manifest, and `Stop-AvdRunRecorder.ps1 -CopyTo github` copies it to the companion repo's `runs` branch like any run (run recorder 9.2 step 4, 9.3). Snapshots are small JSON, far under the 50 MiB limit. The companion repo also keeps `config/latest/` on the `runs` branch, so a recovery reads one path. The snapshot is private-level: it holds object IDs and names; it never goes to a public repo or issue.

A daily run is a few ARM and Graph reads and one commit. The operator schedules it, or runs it before any change; the status check only reports its age.

## 8. Recovery tests

A tier is only met when it has been tested (D3). `Start-AvdRecoveryTest.ps1` runs one test, by hand, in the operator's own subscription, as a recorded run with an estimate first (run recorder 9.1 and 13a rules: printed estimate, cap, the operator's go).

| Test | What it does | Proves | Measures |
|---|---|---|---|
| **T-profile** | Restores the profile share from the newest recovery point to a new share in a new storage account, mounts it from a test host and opens one test user's container | Profiles come back | Real RPO (age of the recovery point), restore time |
| **T-config** | Deploys the landing zone to a new prefix from the snapshot's commit and parameters, then re-applies the configuration snapshot and diffs the result against the snapshot | P1 and P2 rebuild the estate | Deploy and apply time; every difference |
| **T-image** | Creates one host from the recovery-region replica (R1) or the source gallery (R0) and registers it | Images come back | Time to a registered host |
| **T-signin** | Signs in a test user to the restored pool and loads the restored profile (`Test-AvdUserConnection.ps1`) | End to end | RTO from start of test to a working session |
| **T-failover** (R2) | Microsoft's test pattern: a test group gets the standby pool's application groups, is removed from the primary's, signs in, and fails back (F16) | The failover procedure | Time to first session in the standby region |

Rules:
- **Never Site Recovery test failover for session hosts.** Microsoft warns that it creates a duplicate VM that registers with the control plane and conflicts with the original (F6). Not used.
- **Tests restore into new names**, never over the source (D2), and with test users only. Real users' data is never opened by a test.
- **Teardown under the conventions:** the test's resources are run resources (0017), removed at the end with evidence; the restored share is a copy, so deleting it doesn't delete a last copy, and the run record says so.
- The run record's `extensions.recovery` holds the measured RPO and RTO; the status check's `dr-tested` reads them. The verified runs table (run recorder 8.5) gets one line per test outcome, public-level.

## 9. Monthly verify routine: `Test-AvdRecoveryCopies.ps1`

Copies rot silently: a commit that was never pushed, a release asset deleted by hand, a backup policy that stopped. Once a month (the operator schedules it; it runs in seconds):

1. **Companion repo:** for every run folder on the `runs` branch and every `run-<id>` release, re-read the files through the API and compare them with the manifest's SHA-256. A mismatch is a finding, never a repair.
2. **Run store:** list every run folder and compare it with the companion repo; a folder with no verified copy is listed with its size (this is what `-TeardownLogs` would need to ask about).
3. **Service backups:** last job result and newest recovery point per protected item; vault soft delete and immutability state.
4. **Gallery:** replication state of each version in use, per region.
5. **Configuration:** run a snapshot and diff it against `config/latest/`; drift is reported, not applied.
6. **Status:** run section 6 and write all of the above as one `recovery` run with `kind: verify`.

Nothing in the routine deletes, overwrites or "fixes" a copy. It reports, and a person decides.

## 10. The run record: use case `recovery` (contract C17)

Recovery actions write `avd-run-record/v1` like every run, with a new line in avd-second-brain's `contracts/run-use-cases.json`:

```json
{ "id": "recovery", "producer": "avd-landing-zone", "status": "proposed", "covers": "configuration snapshots, backup checks, recovery tests, verify routine and restores", "spec": "build/specs/recovery-spec.md" }
```

Fields it adds under `extensions.recovery` (additive within v1; the schema for them goes to the brain's `contracts/schemas/` when this is built):

| Field | Meaning |
|---|---|
| `kind` | `snapshot`, `verify`, `test`, `restore` |
| `tier` | `R0`, `R1`, `R2` |
| `items` | Per item from section 3.1: `id` (P1 to P9), source, copy location, recovery point time, `verified` (hash or tested), `secretsRegenerated` names only |
| `measured` | `rpoMinutes`, `rtoMinutes`, per step durations |
| `targets` | The tier's RPO and RTO, for comparison |

Journal events are named `x.recovery.<name>`: `x.recovery.restore.start`, `x.recovery.restore.done`, `x.recovery.diff`, `x.recovery.signin`. `cost.json` works unchanged: the estimate before a test, actuals after (run recorder 9.3a).

A copy of a recovery run's files to anywhere beyond the companion repo uses the copy hook as it is (run recorder 9.2 step 4): the `request.json` carries the files' class from the run record (`config`, `profile`, `image`, `run-record`), and the receipt's `verifiedBy` is what the status check shows as the copy location.

## 11. Teardown and the family conventions

| Situation | Behavior |
|---|---|
| Landing zone cleanup with profile backup on | Today `Remove-AvdDemo.ps1` stops protection and deletes the recovery points. Under decision 0016 those recovery points may be the last copy of the profiles. Cleanup refuses unless a profile export exists in the run folder with a verified copy, a receipt from the copy hook covers it, or the operator passes `-DiscardLastCopy` (draft PR #73 adds the switch). |
| Profile export before cleanup | `Stop-AvdRunRecorder.ps1 -BeforeCleanup` gains a step: copy each container from the share into the run folder (`profiles/`, VHDX as-is, user pseudonym in the manifest, never the UPN). Usually over 2 GiB, so these stay in the run store under `-TeardownLogs` (default `Keep`) and the run record lists them as *kept in Azure only* unless a hook receipt covers them. Test users only in the sandbox. |
| Configuration snapshots | Never deleted by any script. They're small and live in git on the `runs` branch. |
| R2 standby | Removed with the landing zone unless `-KeepRunning` is set on it; its second share is profile data, so the same rule as the first share applies. |
| Recovery test resources | Run resources: removed at the end of the test, with evidence. A restored share is a copy and is removed without `-DiscardLastCopy`, after the run record confirms the source still exists. |
| Retention | Recovery points expire by the backup policy, which is retention, not a teardown. The status check warns when the policy's retention is shorter than the tier's test interval, because a point that expires untested proves nothing. |

## 12. Facts checked, and what is not

Checked on 2026-10-20 against Microsoft Learn and the Azure retail prices API.

| # | Fact | Source |
|---|---|---|
| F1 | AVD has no native DR features; session hosts, profiles, apps, user data and identities are customer-managed | *Azure Virtual Desktop business continuity and disaster recovery concepts* (learn.microsoft.com/azure/virtual-desktop/disaster-recovery-concepts) |
| F2 | Microsoft manages the control plane and fails it over; no customer redundancy needed. Regional host pools (preview) keep metadata in one region; geographical and regional objects don't interoperate during preview | *Multiregion BCDR for Azure Virtual Desktop* (learn.microsoft.com/azure/architecture/example-scenario/azure-virtual-desktop/azure-virtual-desktop-multi-region-bcdr), control plane section |
| F3 | The multiregion guide doesn't cover OneDrive; Microsoft points to SharePoint and OneDrive resiliency in Microsoft 365 | Same, scope limitations |
| F4 | RPO and RTO estimates: active-active near-zero RTO; active-passive with Cloud Cache RPO seconds to minutes, RTO 15 to 60 minutes; personal with Site Recovery RPO 5 to 15 minutes. "Treat these examples as estimates... Validate them through DR testing" | Same, goals and scope; model comparison |
| F5 | Pooled host pool VMs are stateless; profiles live in external storage | Same, host pool types |
| F6 | Personal host pools: Site Recovery per VM. Don't use Site Recovery test failover for session hosts: the duplicate registers with the control plane and conflicts. Site Recovery doesn't keep VM extensions | Same, failover and failback, personal host pool |
| F7 | MSIX packages: one storage account per region, ZRS at least in the primary, packages copied to both | Same, MSIX storage account options |
| F8 | Key Vault backups restore only to a vault in the same subscription and geography; they can't be decrypted outside Azure | *Azure Key Vault backup and restore* (learn.microsoft.com/azure/key-vault/general/backup); *Reliability in Azure Key Vault* |
| F9 | Vaulted backup for Azure Files is an offsite copy in the vault, supports SSD (premium) shares, is available in North Central US with Cross Region Restore, and transfers only the last scheduled snapshot of each day | *Support matrix for Azure Files backup* (learn.microsoft.com/azure/backup/azure-file-share-support-matrix) |
| F10 | Only users, Microsoft 365 groups, cloud security groups, app registrations, service principals, administrative units, Conditional Access policies and named locations are soft deleted (30 days); everything else is hard deleted. Keep configurations as version-controlled JSON and redeploy the last known-good one | *Recover from deletions* and *Plan for tenant recoverability* (learn.microsoft.com/entra/architecture) |
| F11 | Deallocated hosts, on-demand deployment and Site Recovery don't guarantee capacity in the recovery region; only allocated resources or on-demand capacity reservations do; Azure reservations don't | Multiregion BCDR guide, capacity considerations |
| F12 | Availability zones are high availability, not a DR solution for region-wide disasters | Same, goals and scope |
| F13 | Each session host must start for a few hours at least every 90 days to refresh its control plane token | Same, autoscaling and cost optimization |
| F14 | Azure Files backup uses key-based access; the source account must allow storage account key access for backup and restore, even when identity-based access is configured | *Support matrix for Azure Files backup*; *Frequently asked questions about backing up Azure Files* |
| F15 | Cloud Cache: list the local share first in each region; Cloud Cache is asynchronous and I/O intensive; users must not hold sessions in both pools (profile lock) | Multiregion BCDR guide, FSLogix; *Business continuity and disaster recovery options for FSLogix* (learn.microsoft.com/fslogix/concepts-container-recovery-business-continuity) |
| F16 | Test failover pattern for pooled active-passive: a test group (GRP-TEST) assigned to the standby pool's application groups; full failover reassigns all application groups | Multiregion BCDR guide, pooled host pool scenario |
| F17 | Share snapshots stay with the share; a permanently deleted share loses its snapshot-tier recovery points | *Secure your Azure Files*; Azure Files backup troubleshooting (UserErrorRestoreAFSInDeleteState) |
| F18 | Retail prices, northcentralus, read 2026-10-20 (section 13): Azure Files protected instance $5/month; Azure Files Vaulted protected instance $12/month; Vaulted data stored LRS $0.0492, ZRS $0.0576, GRS $0.0912 per GB-month; Premium ZRS Files provisioned $0.20 and snapshots $0.17 per GB-month; Standard HDD LRS snapshots $0.05 per GB-month; P10 disk $19.71/month; E4as v5 Windows $0.41/hour; inter-region transfer $0.02/GB | Azure retail prices API (prices.azure.com) |
| F19 | Azure Files backup prerequisites: the storage account either permits access with account keys or has public network access disabled. A backup refused for lack of key access fails with `UserErrorStorageKeyBasedAuthenticationNotPermitted` | *Back up Azure Files*, prerequisites (learn.microsoft.com/azure/backup/backup-azure-files); *Troubleshoot problems while backing up Azure Files* |

Unverified, to check before building or in the first test:

| # | Open fact | How it gets checked |
|---|---|---|
| U1 | **Whether the landing zone's snapshot-tier profile backup works with key access off.** Two Microsoft pages differ: F19 accepts key access off when public network access is disabled (the landing zone disables it), and the support matrix (F14) asks for key access on the vaulted tier. Decided (section 14): key access stays off for the snapshot tier and turns on only with `profileBackupTier = 'Vaulted'`. Still unverified: a real snapshot-tier backup job with keys off | The post-deployment preflight's `profile-backup` reads the last backup status on the first real landing zone; T-profile in the sandbox |
| U2 | Whether the Azure Files protected instance price depends on share size bands | Azure Backup pricing page and the estimator's meter match at estimate time (R7) |
| U3 | How gallery replica storage is billed (provisioned or used size) for a 127 GiB image | Compute Gallery pricing docs; first R1 test's actuals |
| U4 | Restore time for a share of the sandbox's size, from snapshot and from vault tier | T-profile measures it |
| U5 | Which AVD properties the ARM export misses (for example, per-host settings) | T-config's diff |
| U6 | Whether a VHDX can be copied from the Entra Kerberos-only share to the run store from Cloud Shell, or needs a host-side copy (the share is private and SMB-only, decision 0005) | Offline design check, then the first profile export |

## 13. Cost

Monthly, northcentralus, retail list prices from F18. Example sandbox: 2 hosts, a 100 GiB provisioned profile share holding 50 GB of profiles, one 127 GiB image. The real estimate comes from `Get-AvdCostEstimate` with one retail meter per line before anything is deployed (decision 0010); these rows are here to compare tiers, not to quote.

| Tier | Added items | Monthly, on top of the landing zone |
|---|---|---|
| **R0** | Snapshot backup: 1 protected share ($5.00) plus snapshot data, assume 10 GB changed ($1.70); configuration snapshots in git ($0) | **about $7** (the landing zone pays most of this today) |
| **R1** | R0, plus vaulted backup: 1 protected share ($12.00) and 50 GB GRS for Cross Region Restore ($4.56); gallery replica in the recovery region, 127 GiB as snapshot storage (about $6.35, U3) plus one transfer per image version (127 GB at $0.02, about $2.54) | **about $30** |
| **R2** | R1, plus a second 100 GiB Premium ZRS share for Cloud Cache ($20.00), 2 deallocated standby hosts' P10 OS disks ($39.42), a scheduled start every 80 days (2 hosts for 3 hours at $0.41, about $2.50 per start), Cloud Cache local disk on each primary host (size per F15; U3-style check) | **about $95**, before the Cloud Cache disks and recovery-region price differences |
| **Recovery test** | One T-profile plus T-config plus T-signin in the sandbox: a new landing zone prefix for about 3 hours (2 hosts at $0.41/hour, share, networking), restore operations | **about $3 to $5 per test**, under the run recorder's $5 printed-estimate rule; estimate printed first, the operator's go required |

Defender for Storage, if on, bills per storage account per month (run recorder 9.1): T-profile's new storage account is a new charge, and the status check reports the plan's state before a test.

## 14. Open questions for the owner

1. **U1, profile backup and shared keys.** Decided 2026-10-20: key access on only with the vaulted tier. `main.bicep` has `profileBackupTier` (`Snapshot` by default, or `Vaulted`) and passes `enableProfileBackup && profileBackupTier == 'Vaulted'` to the storage module's `allowSharedKeyAccess`. SMB stays Kerberos-only and the account private-endpoint only, so a key can't mount the share; it would still work against the storage REST API from inside the network. A template test guards it.
2. **Sandbox region policy.** Decided 2026-10-20: fix it in the landing zone (section 4.1) and check it in the preflight (section 6.1). Setting the sandbox's recovery region is a deployment, so it waits for the owner's go.
3. **Default tier.** Recommend R0 for the sandbox and demo, with R1 documented; R2 only on request.
4. **Restoring into another subscription in the same tenant**, with Azure Backup's own cross-subscription restore. Decided 2026-10-20: in scope here (same-tenant recovery, Scope above).
5. **Test interval.** Every 90 days per tier (recommended), or only before a release?

## 15. Phases

| Phase | What | Cost |
|---|---|---|
| **P0** | This spec | $0 |
| **P1, offline** | `Get-AvdRecoveryStatus.ps1` and its pure checks, mocks in `AzMock.psm1`, an offline scenario, the portal's state branch and tests; the `recovery` use case and its schema (paired avd-second-brain PR) | $0 |
| **P2, offline** | `Export-AvdConfiguration.ps1`, the AVD-scoped identity snapshot, the drift diff; `Test-AvdRecoveryCopies.ps1` against a fake GitHub API | $0 |
| **P3, first real status check** | Read-only against the sandbox's landing zone: answers U1 | $0 (reads) |
| **P4, first recovery test** | T-profile, T-config, T-signin in the sandbox, same region | Printed estimate, the owner's go |
| **P5** | R1 pieces: the vaulted tier in `backup.bicep` (reads `profileBackupTier`; key access is already wired), gallery replica | Same |
| **P6** | R2 standby and T-failover, only on request | Same |
