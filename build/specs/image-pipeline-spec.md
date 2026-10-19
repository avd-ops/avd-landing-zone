# Spec: golden image pipeline and host rotation

- **Status:** Proposed (see [decision 0013](../decisions/0013-image-pipeline.md)); all red-team findings folded in; see [image-pipeline-redteam.md](image-pipeline-redteam.md)
- **Date:** 2026-10-04
- **Scope:** landing zones built from this repo. This is phase 0b of the [second brain spec](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md), built before its phase 1 (Q6).

This is a personal project, not for production, provided as is. Nothing in this spec has run against a real tenant yet; §11 lists what to verify at build time.

## 1. Summary

Session hosts are built from the marketplace image today (`MicrosoftWindowsDesktop/office-365/win11-24h2-avd-m365`, `version: latest`). Two hosts deployed a week apart can therefore differ, and nobody can say which build a host runs. Replacing hosts is a manual procedure in [deploy.md](../../docs/deploy.md#7-day-2-operations): a new `sessionHostNamePrefix`, drain, delete.

This spec adds:

1. **A golden image.** Azure Image Builder (AIB) builds it monthly from the marketplace image. It applies updates, the WDOT optimizations and a small set of generic customizations, validates the result inside the build VM, and publishes it as a version in an Azure Compute Gallery. Hosts don't update themselves; the image carries the patches (§5.6).
2. **A one-host QA pool in every landing zone.** It is a validation environment that gets AVD service and agent updates first, the canary for every new image, and the place for maintenance work (§6.2).
3. **Automated validation, then promotion by a person.** A new version is excluded from `latest` until it passes automated validation in `test`'s and then `prod`'s QA pools, with a 24-hour soak in each. Nobody has to run anything. A person then promotes it to a production pool, with the validation results and the QA users' real sign-ins in front of them.
4. **Host rotation.** A resumable script replaces hosts blue/green: it deploys new hosts from the promoted version, drains the old ones, waits for sessions to end, and removes the old VMs, their session host objects and their Entra ID and Intune device objects.

The rule that holds it together: **the image is generic, and the landing zone configures it.** Nothing tenant- or landing-zone-specific goes into the image: no share path, no registration token, no domain, no secrets. The same version serves dev, test, prod and any adopter. Per-landing-zone configuration stays in the managed Run Commands that already exist (`Configure-FSLogix`, `Register-AvdAgent`).

## 2. Goals and non-goals

### Goals

1. Every host's software is known: an image version traceable to a commit, a source image version and a build run.
2. A monthly image with current updates, built and validated without anyone at a keyboard, and promoted only by a person.
3. Hosts replaced without users losing work, from Cloud Shell, surviving a disconnect (lesson 0015).
4. The second brain's `replace-host` playbook and its detections can rely on a known image (second brain spec §8).

### Non-goals

- **App delivery.** App Attach, Intune apps and line-of-business installers stay a separate layer ([out-of-scope.md](../../docs/out-of-scope.md)). The pipeline has an optional customization folder for adopters, empty by default.
- **Multi-region replication for DR.** The gallery replicates to the landing zone's region only.
- **Personal host pools** and **brownfield images.** Same scope as the landing zone (decision 0001).
- **Forced log-offs by default.** Rotation waits for users unless the operator opts in (§6.5).
- **A shared community image.** The project doesn't publish images. Each adopter builds their own in their own subscription (§10, Q4).

## 3. Principles

| # | Principle | Source |
|---|---|---|
| I1 | The image is generic; configuration is applied per landing zone at host creation | decision 0001 (no post-deployment scripts on the host: configuration stays declarative in the template) |
| I2 | Build and validate automatically; a person promotes to a production pool | second brain spec P10 |
| I3 | Every script that reaches a build VM or a host is pinned: the commit for authenticity, SHA-256 for integrity in transit | red-team H6 |
| I4 | Validate with positive evidence: Available hosts, passing health checks, and a real sign-in, not "the build succeeded" | red-team H5, M9 |
| I5 | Anything slow prints a line before it starts; a long wait is a resumable phase, not a blocked Cloud Shell | lessons 0006, 0015 |
| I6 | Test a region without availability zones | lessons 0001, 0021 |
| I7 | Host and build scripts run in Windows PowerShell 5.1 | lesson 0011 |

## 4. Architecture

```
┌──── rg-<prefix>-images (shared by every environment) ───────────────────────────────────────┐
│ Azure Compute Gallery  gal<prefix>                                                          │
│   image definition  win11-avd-m365  (Windows, Generalized, V2, TrustedLaunch, accel. net.)  │
│   versions  YYYY.MMDD.N  (tags: commit, source image version, run; excludeFromLatest)       │
│ User-assigned identity  id-<prefix>-aib  (custom roles: gallery write, subnet join)         │
│ Per-build image template  it-<prefix>-<version>  (created, run, logs saved, deleted)        │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ distribute (replica in the landing zone's region; ZRS where zones exist, else LRS)
┌───────┴────── build network: the build environment's spoke (default: dev) ──────────────────┐
│ snet-image-build  10.100.2.128/27  build VM, egress through the NAT Gateway or hub firewall │
│ snet-image-aci    10.100.2.160/27  AIB isolated build container (delegated to ACI)          │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
        │ version ID
┌───────▼────── each landing zone ────────────────────────────────────────────────────────────┐
│ AVD_SESSION_HOST_IMAGE_ID → sessionHosts.bicep imageReference { id }                        │
│ sessionHostGeneration a|b → host names <prefix10><gen>-NNN, rotated blue/green              │
│ Run Commands (unchanged): Configure-FSLogix → Register-AvdAgent                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Resources

`bicep/images/main.bicep` is a new entry point at subscription scope, like `bicep/demo/main.bicep`, and carries the project notice (`build/tests/portal/disclaimer.test.mjs`). It deploys:

| Resource | Notes |
|---|---|
| `rg-<prefix>-images` | One per name prefix, shared by dev, test and prod, so every environment runs the same artifact |
| Azure Compute Gallery `gal<prefix>` | Gallery names allow letters, digits, underscores and periods: the prefix is normalized the way `sessionHostNamePrefix` is |
| Image definition `win11-avd-m365` | `osType: Windows`, `osState: Generalized`, `hyperVGeneration: V2`, features `SecurityType = TrustedLaunch` and `IsAcceleratedNetworkSupported = true`, because hosts are Trusted Launch with accelerated networking (`sessionHosts.bicep`). Publisher, offer and SKU: `avdlz`, `win11-avd-m365`, `24h2` |
| `id-<prefix>-aib` | User-assigned identity for AIB |
| Custom role "AVD LZ image distributor" | Read the gallery and the definition; write and read versions. Scoped to the images resource group |
| Custom role "AVD LZ image build network" | `virtualNetworks/read` and `subnets/join/action`. Scoped to the two build subnets |
| Contributor on the staging resource group | `rg-<prefix>-images-staging`, which AIB uses for the build VM, its disk and its logs. AIB requires this role there; nothing else lives in that group |

The two build subnets go into the **build environment's** spoke (`AVD_IMAGE_BUILD_ENVIRONMENT`, default `dev`). They are added by `network.bicep` when `deployImageBuildSubnets` is true. They reuse that spoke's egress, the NAT Gateway or the hub firewall, so the build VM has no public IP (decision 0001), and no second NAT Gateway is needed. In hub mode, the firewall must allow Windows Update, the Microsoft 365 CDN, Defender updates, the AIB service endpoints, and `github.com` and `codeload.github.com` for WDOT. The repository's own scripts are inlined into the template (§5.2), so nothing is fetched from it.

### 4.2 Image versions

- **Name (red-team M1):** `YYYY.MDD.N` with **no zero padding**, for example `2026.1004.1` for October 4 and `2027.104.1` for January 4. Gallery versions are three integers, so a padded `0104` is invalid or gets normalized. Month × 100 + day still sorts by date when compared **numerically**, and every script compares versions numerically, never as strings. A template test covers a January and an October date.
- **Tags on every version:**
  - `avdlz-commit`: the repo commit of the template and the scripts;
  - `avdlz-source-image`: the marketplace version AIB resolved from `latest`;
  - `avdlz-run`: the Actions run URL;
  - `avdlz-validation`: the automated validation stage, or the failed check (§6.3);
  - `avdlz-validated`: `false` until validation passes, then the date.
- **`excludeFromLatest: true`** at build. Promotion flips it, so nothing that asks for "latest" picks up an unvalidated build.
- **Replicas (red-team H8):** one replica in **every region an environment uses**. `parameters/images.bicepparam` lists them, taken from each environment's location (decision 0003).
  - Storage is chosen per region: `Standard_ZRS` where the region has availability zones, `Standard_LRS` where it doesn't. A template test compiles both cases (lesson 0001).
  - **Replica count (red-team M6):** one per 20 hosts created at once, at least 1. It's computed from the largest pool's `sessionHostCount` in that region, because rotation creates a whole pool's new generation at once (§6.5).
- **Subscriptions:** when environments sit in different subscriptions, the images deployment grants Reader on the gallery to each environment's deploy identity. The preflight's `-SessionHostImageId` check (§6.1) verifies, from that environment's identity, that it can read the version and that the version is replicated to that environment's region.
- **Retention (red-team H5):** the last three validated versions plus anything newer. An `endOfLifeDate` six months out is set at build. The build identity can't see any landing zone, so use is recorded on the version itself:
  - the rotation script, running with the landing zone's rights, sets `avdlz-in-use-<env>-<pool>=true` on a version when its Deploy phase succeeds, and clears that tag on the version it removes;
  - `image-build.yml` never deletes a version with any `avdlz-in-use-*` tag, and always keeps the newest validated version **not** in use, as the rollback target.

## 5. Build

### 5.1 Trigger

`.github/workflows/image-build.yml`:
- **Schedule:** monthly, about a week after Patch Tuesday, when updated marketplace images are usually out.

  The schedule is a daily cron on days 15–21, and the job exits unless it's Monday. In a cron expression where both day-of-month and day-of-week are restricted, either field matches, so `0 6 15-21 * 1` alone would run every day from the 15th to the 21st and every Monday.
- **`workflow_dispatch`** for out-of-band builds, such as a security fix.

**One build at a time (red-team M2).** `image-build.yml` and `image-validate.yml` each run in a concurrency group, `image-build` and `image-validate`, and never cancel a run in progress. One version validates at a time. When a newer version passes §5.4 while an older one is still in validation, the newer one **supersedes** it: the older version is tagged `avdlz-validation=superseded`, its QA pools roll to the newer version at the next stage, and it is never promoted.

The workflow uses OIDC to Azure through the `images` GitHub Environment. Its identity can deploy into the images resource group and run image templates there, and nothing else. Building doesn't change any landing zone: a new version is excluded from `latest`, and no host uses it until a person promotes it. So a scheduled build needs no approval.

### 5.2 Steps

0. **Sweep orphans (red-team M7).** Delete `it-<prefix>-*` image templates older than 24 hours, left by a run that died, after saving their customization logs to the run's artifacts. Report what was removed. Deleting a template removes its staging resources.
1. **Resolve and print:** the source image version that `latest` resolves to, the commit, and the new version name. If the source version and the commit both match the newest existing version, stop: nothing changed. The `force` input skips this check (§5.7).
2. **Inline the inputs (red-team C4, as built).** `build.bicep` inlines every customizer and the WDOT profile into the template at compile time (`loadTextContent`, `loadFileAsBase64`), from the commit being built. Adopters' repositories are private (second brain spec §9.1), and AIB never has to fetch from them, from GitHub or from a storage container.

   This replaced the private `image-build` container in the first version of this spec. It is simpler: no storage account, private endpoint or upload from a runner that can't reach one. Its authenticity is the same: the commit.
3. **Deploy a per-build image template** (`bicep/images/build.bicep`). Templates are immutable, so each build gets its own, named after its version:
   - **source:** the platform image, at the version resolved in step 1;
   - **`vmProfile`:** a pinned size from `images.bicepparam`, by default 4 vCPUs from a current D-series (`Standard_D4s_v5`), OS disk 127 GB (red-team M3). Before the run, the workflow checks the build family's regional vCPU quota and stops with the quota request if it's short (lessons 0013, 0024). `vnetConfig` with `subnetId` = `snet-image-build` and `containerInstanceSubnetId` = `snet-image-aci` (isolated build, no proxy VM);
   - **`customize`:** §5.3, each script **inline** from the commit (no `scriptUri`; a template test enforces it);
   - **`validate`:** §5.4, with `continueDistributeOnFailure: false`;
   - **`distribute`:** the gallery version from §4.2, with its tags;
   - **`buildTimeoutInMinutes`:** 360. A cumulative update for Windows 11 multi-session with Microsoft 365 Apps, then WDOT and two restarts, can exceed 4 hours.
4. **Run it.** Print a line before starting (lesson 0006), then poll `lastRunStatus` with a capped loop that ends on error (lesson 0008).
5. **Save the logs.** Copy AIB's `customization.log` from the staging storage into the run's artifacts, whatever the result. On a failure, report the step, status, error code and log tail (lesson 0012).
6. **Delete the template.** Deleting it also removes its staging resources.
7. **Open an issue** with the version, the source image version, the build-time validation results. Automated validation then starts on its own (§6.3).

### 5.3 Customizations

Each customization is a Windows PowerShell 5.1 script in `scripts/image/`, covered by PSScriptAnalyzer like every other script. Defaults:

| Order | Customization | Why |
|---|---|---|
| 1 | Windows Update (AIB's `WindowsUpdate` customizer; security and critical updates, no previews, no drivers), then restart | The month's patches in the image, not at first boot |
| 2 | `Disable-StorageSense.ps1` | Storage Sense can delete files inside FSLogix profiles; Microsoft's AVD guidance turns it off |
| 3 | `Enable-TimeZoneRedirection.ps1` | Sessions use the client's time zone |
| 3a | `Set-SessionTimeLimit.ps1`: disconnected sessions end after 8 hours (`imageDisconnectedSessionLimitHours`) | A forgotten session can't hold a rotation open indefinitely (§5.7) |
| 4 | `Disable-AutomaticUpdates.ps1`: Windows and Microsoft 365 Apps automatic updates off | The image is the source of patches (§5.6) |
| 5 | `Invoke-Wdot.ps1`: WDOT with the reviewed profile, then restart | VDI performance tuning (§5.5) |
| 6 | `Update-DefenderSignature.ps1` | Hosts start with current signatures |
| 7 | Adopter scripts from `scripts/image/custom/`, in name order; empty in this repo | Apps and settings that belong to the adopter |
| 8 | `Invoke-ImageCleanup.ps1`: DISM component cleanup, temp and update download folders | Smaller image, faster deployments |

Never in the image:
- the AVD agent and Boot Loader. `Register-AvdAgent` installs the current version at host creation, and it handles a preinstalled agent if an adopter adds one (Q1);
- FSLogix **configuration**. FSLogix itself ships in the marketplace image; `Configure-FSLogix` writes the share path per landing zone;
- domain or Entra ID joins, local accounts or passwords, registration tokens, tenant IDs;
- Appx package removal, unless opted in after a tested build (§5.5). Removing them for some users breaks sysprep.

AIB generalizes the VM (sysprep) after the last customizer, with its default deprovisioning command.

### 5.4 Build-time validation

`scripts/image/Test-GoldenImage.ps1` runs in the build VM as AIB's `validate` step. Any failure stops distribution. It checks:

- the OS build matches the expected release (24H2) and is at least the source image's build;
- FSLogix is installed (`frx.exe`), at or above a minimum version;
- Microsoft 365 Apps are installed with shared computer activation on;
- Storage Sense is off and time zone redirection is on;
- no AVD agent or Boot Loader is installed, unless the adopter opted in (Q1);
- no reboot is pending, and no update failed in this build;
- no local user account exists beyond the built-ins;
- Defender is enabled, with signatures less than 24 hours old;
- WDOT ran with the `avdlz` profile at the pinned version and reported success, and no protected service (§5.5) is Disabled;
- Windows and Microsoft 365 Apps automatic updates are off (§5.6).

It prints one `RESULT <check> <Pass|Fail> <detail>` line per check, the format of the offline scenarios, so the build issue can quote it.

**What it can't see (red-team M5).** AIB runs `validate` on the customized VM **before** generalizing it. A sysprep failure, and anything sysprep changes, isn't visible here. So:
- the build checks that generalization succeeded, from the AIB run status and the end of the customization log, and fails the build if it didn't;
- the QA host's first check (§6.3) is the first evidence from a generalized image, and the build issue says so.

### 5.5 WDOT optimizations

The pipeline runs the [Windows Desktop Optimization Tool](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool) (WDOT) on every build. WDOT is the Virtual Desktop Team's successor to VDOT, which gets no more updates. It tunes Windows for multi-session hosts: it removes or disables services, scheduled tasks and autologgers that a VDI host doesn't need, and sets default-user and network settings. All its settings are applied to the image once, never to running hosts.

**Pinned, not vendored (as built).** `scripts/image/wdot/wdot.lock.json` records WDOT's release (`v1.1`), its commit, and the **SHA-256 of every file the build runs**: `Windows_Optimization.ps1` and each `Functions/*.ps1`. `Invoke-Wdot.ps1` downloads the commit's archive and refuses to run when any file's hash differs, or when the archive holds a function file the lock doesn't list (WDOT loads every `Functions\*-WDOT*.ps1`).

Per-file hashes replace the archive hash and the private mirror of the first version of this spec (red-team M4). GitHub doesn't promise stable archive bytes, but the files are what runs, and their bytes are the commit's. A GitHub outage still stops a build, and the build reports it. A newer release reaches the image only through a PR that updates the lock file, which is a guardrail-style change reviewed like any other. A monthly check in `image-build.yml` opens an issue when a newer release exists.

**Our profile, reviewed in Git.** WDOT reads a configuration profile: JSON files in which each item's `OptimizationState` is `Apply` or `Skip`. The profile was generated once with WDOT's `New-WVDConfigurationFiles.ps1` and is kept in `scripts/image/wdot/profile/`. Every change to it is a diff someone can read. `Invoke-Wdot.ps1` copies it into WDOT's `Configurations` folder as `avdlz`, then runs:

```
Windows_Optimization.ps1 -ConfigProfile avdlz -AcceptEULA -Optimizations Services,ScheduledTasks,Autologgers,DefaultUserSettings
```

It doesn't pass `-Restart`; an AIB restart customizer follows instead.

| Category | Default | Why |
|---|---|---|
| Services, ScheduledTasks, Autologgers | Apply, with the protected list below and a few reviewed items kept `Skip` | The bulk of the CPU, memory and logon-time savings |
| DefaultUserSettings | Apply, except Edge update suppression, notification blocks, hidden tray icons and Copilot | Every new FSLogix profile starts from the default user. The exceptions conflict with §5.6 or with Teams and Outlook |
| LocalPolicy | **Not run yet** | 147 organization-level policy settings, not reviewed one by one |
| NetworkOptimizations | **Not run yet** | Besides SMB client settings, WDOT changes the network adapter's send buffer, which on Azure is the accelerated networking adapter. Not verified |
| DiskCleanup | **Never** | Found while building (as built): it deletes every `*.log`, `*.etl` and `*.evtx` on `C:` and empties `C:\Windows\Temp`, which is the build's own evidence, before `Test-GoldenImage.ps1` reads it. `Invoke-ImageCleanup.ps1` cleans narrowly instead |
| WindowsMediaPlayer | Skip | Little gain, and some line-of-business apps still use it |
| AppxPackages | **Skip** | Removing Appx packages is the classic sysprep breaker: a package installed for a user but not provisioned for all users fails generalization. It becomes opt-in, by a PR that adds `AppxPackages` to the lock's `optimizations` and reviews the profile, once one build has passed with it and a lesson is written |
| Advanced: Edge, RemoveLegacyIE, RemoveOneDrive | **Skip** | WDOT itself marks them aggressive. RemoveLegacyIE is irreversible, and OneDrive matters with FSLogix profiles |

**Protected items.** These must stay `Skip` in the profile, because the landing zone depends on them:
- `dmwappushservice`: Intune MDM push;
- `WinDefend` and the Defender services;
- `wuauserv` and `BITS`: Defender signature updates, the Intune management extension, and the agent download;
- `WSearch`: Start and Outlook search in multi-session;
- `W32Time`, `CryptSvc`, `Schedule`;
- `TermService`, `SessionEnv`, `UmRdpService`: the RDP stack;
- `LanmanWorkstation`: the SMB client FSLogix uses to reach the share;
- `KeyIso` and `VaultSvc`: credential isolation and Kerberos;
- `WinHttpAutoProxySvc` and `iphlpsvc`: required by Entra Kerberos, which sends its ticket requests through the KDC proxy (disabling WPAD by registry is fine; disabling the service is not);
- `TokenBroker`: Web Account Manager, used by Entra ID single sign-on and Microsoft 365 Apps;
- `AppXSvc` and `ClipSVC`: MSIX apps, such as the new Teams and the new Outlook;
- the Edge Update services (`edgeupdate`, `edgeupdatem`).

A list can still miss something, so the in-host function check (§6.3) also **exercises** what those services enable: an SMB connection to the share, a Kerberos ticket for the host, a Web Account Manager token request, and the launch of an MSIX app. That way a service missing from the list still fails validation.

A Pester test reads the profile and fails if any protected item is `Apply`. `Test-GoldenImage.ps1` confirms after the build that none of these services is Disabled. Two independent guards cover this, because a disabled `dmwappushservice` breaks Intune enrollment silently on every host.

**Order in the build:** Windows Update → restart → our settings (§5.3) → **WDOT** → restart → Defender signatures → adopter scripts → cleanup. WDOT runs after updates, so it tunes the patched system, and before the adopter's apps, so their own services aren't touched. The WDOT version and the profile's hash are tagged on the image version (`avdlz-wdot`).

### 5.6 Updates on hosts: off, by design

With a golden image, **hosts don't update the operating system or Office themselves.** The image is the single source of truth for patches: Microsoft's golden image guidance turns automatic updates off, so hosts don't reboot unplanned and don't drift to different patch levels ([golden image](https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-golden-image)). Patches arrive monthly through a new image and a rotation (§6). This applies to every pool, including the QA pool (§6.2), which must mirror production to be useful.

| Update | On hosts | How |
|---|---|---|
| Windows Update (quality and feature) | **Off** | `Disable-AutomaticUpdates.ps1` sets the policy `NoAutoUpdate = 1`. The `wuauserv` service stays available for Defender and Intune |
| Microsoft 365 Apps | **Off** | Office update policy `enableautomaticupdates = 0`; the image carries the month's build |
| Defender signatures | **On** | Security content, not software: it doesn't reboot and doesn't change the patch level |
| AVD agent and side-by-side stack | **On, scheduled** | The AVD service always updates the agent. The host pool's scheduled agent updates choose the window, and the QA pool gets new agents first (§6.2) |
| Microsoft Edge, WebView2 | **On** | Security-critical clients that update themselves. Recorded, not treated as drift |
| New Teams, OneDrive | **On** | Self-updating per user or per machine. Recorded, not treated as drift |
| Defender platform (engine and platform, not signatures) | **To verify** | It normally arrives through Windows Update and may stall with automatic updates off. The platform version is part of `image-age`'s evidence, and the image carries the current one |

**Intune can override this.** Windows Update rings are the platform's job ([out-of-scope.md](../../docs/out-of-scope.md)). If an update ring targets these devices, Intune's policy wins over the image's. The adopter excludes the AVD hosts' device group from update rings, or assigns them a ring with automatic updates off. The host readiness check reports the effective setting, from both the policy key and the Intune policy manager, as a warning when updates are on.

### 5.7 Patch latency (red-team H1)

With automatic updates off (§5.6), hosts have no patches except the image's, so the pipeline sets targets and has a fast path.

- **Targets:** production hosts patched within **14 days** of Patch Tuesday, and within **72 hours** of a critical out-of-band security release. The `patch-sla` detection (§7) measures the age of each host's patches against these targets. `image-age` fires at 35 days.
- **`force` input on `image-build.yml`:** it skips the "nothing changed" stop (§5.2 step 1). An out-of-band fix arrives through Windows Update even when the source image and the commit haven't changed.
- **Emergency mode** (`emergency: true`, for a build marked security):
  - soaks shorten to 2 hours each (§6.3);
  - the main pool's rotation defaults to `-LogOffAtDeadline`, with a 24-hour deadline and messages at the start, 4 hours before and 15 minutes before;
  - promotion still needs a person.
- **Disconnected sessions are time-limited** in the image (§5.3): 8 hours by default, as a generic policy. One forgotten session can't hold a rotation open indefinitely.

## 6. Promotion and rotation

### 6.1 Parameters

**One source of truth (red-team C2).** Which image and which generation a pool runs is recorded on **the host pool itself**, in two tags: `avdlz-image` (the gallery version ID, or empty for the marketplace image) and `avdlz-generation` (`''`, `a` or `b`). Only the rotation script writes them: at the end of its Deploy phase for the new hosts, and at the end of Remove. Everything else reads them.

- **`deploy.sh` and `deploy.yml` read both tags before every deployment, and pass them to the template.**
  - A routine deployment never changes a pool's image or generation, so it can't ask Azure to change an existing VM's image (which Azure rejects), and it can't recreate a removed generation.
  - Both refuse to deploy while `avdlz-rotation` is set on any pool (§6.5), except when the rotation script itself is deploying.
  - The first deployment of a landing zone, with no tags yet, takes `AVD_SESSION_HOST_IMAGE_ID` and `AVD_SESSION_HOST_GENERATION` as its starting values. After that, those two variables are inputs to the rotation script only.
- **The image ID is a gallery image version resource ID,** never `latest` or a definition ID, so nothing changes software silently (decision 0010's rule against silent changes). Empty means the marketplace image, so a landing zone without the pipeline behaves exactly as today. The parameter files guard it with `empty(...)` (lesson 0004).
- **Generations:** empty keeps today's names (`take(<base>, 11)-NNN`), so existing hosts aren't replaced. `a` or `b` gives `take(<base>, 10)<gen>-NNN`, still 15 characters at most. A template test checks that the default leaves names unchanged, and that each generation yields valid, distinct names.
- **`deploy.sh` gains `--image-id` and `--generation`,** for the first deployment and for the rotation script. The preflight gains `-SessionHostImageId`, which checks that the version exists, that it is replicated to the region and readable by this environment's identity (§4.2), and that its definition is Trusted Launch. The portal's commands carry these (decision 0007: `portal-core.js` and its tests change with them).
- **QA pool settings:** `AVD_QA_POOL` (default on) and `AVD_QA_GROUP_ID` (required when the QA pool is on, §6.2). The QA pool has its own `avdlz-image` and `avdlz-generation` tags, so it can run a newer version than the main pool. That is how validation works (§6.3).
- **Promotion records the target, not the current state:** it sets `avdlz-image-next` on the host pool and starts the rotation (§6.4). A routine deployment in between still uses `avdlz-image`.
- **An offline scenario** covers a routine redeploy before, during and after a rotation. None of them changes a VM's image or recreates a removed generation.

### 6.2 The QA pool: a one-host maintenance ring

Every landing zone gets a **QA pool**: a second pooled host pool with **one host**, built from the same image and size as production. It is the landing zone's maintenance ring, the place every change lands first:

- **AVD service and agent updates.** The QA pool is a **validation environment** (`validationEnvironment: true`), so the AVD service rolls out service and agent updates to it before the production pool ([validation environments](https://learn.microsoft.com/en-us/azure/virtual-desktop/terminology)).
  - Its scheduled agent update window is **Wednesday 02:00**, host local time, before production's Saturday 02:00 (`controlPlane.bicep`). A bad agent version shows up there first.
  - Today `validationEnvironment` is already on for dev and test pools but off in prod (`main.bicep`), so prod has no early warning. The QA pool gives prod one without making its main pool a validation pool.
- **New image versions.** Automated validation runs in each environment's QA pool (§6.3).
- **Maintenance work.** Admins test settings, apps and Run Commands on a host that matches production, without touching users.

| Setting | Value | Why |
|---|---|---|
| Resource group and template | `rg-<prefix>-<env>-qa`: the QA host pool, app group and host. The landing zone deployment creates the group, the host pool, the app group and its role assignments once. QA **hosts** come from their own template, `bicep/qa/main.bicep`, at the QA group's scope (red-team C1) | Automated validation's identity can deploy QA hosts without touching the landing zone, and can't create role assignments (§6.3) |
| Host pool | `vdpool-<prefix>-<env>-qa`, pooled, `validationEnvironment: true`, same RDP properties and session limit as production | Microsoft's guidance is that a validation environment should be as similar to production as possible |
| Host | 1, same size and image version as production; names `take(<base>, 9)q<gen>-NNN` | Mirrors production. It stays 15 characters at most and is distinct from production names |
| Updates | As §5.6: Windows and Microsoft 365 Apps automatic updates off, Defender signatures on, AVD agent on its earlier schedule | A QA host that patched itself would no longer test the image production runs |
| Users | A desktop app group in the **same workspace**, labeled "QA desktop", assigned to `AVD_QA_GROUP_ID`. That setting is **required**: a group of regular users, members of the AVD Users group, not admins. The preflight fails when it's empty or when the group holds an elevated share role (red-team H3) | Admins' elevated share rights would hide exactly the permission and Kerberos failures regular users hit. QA users see both desktops in the Windows App |
| Power | Start VM on Connect, and covered by the scheduled Stop (EX-0002), except during validation: then the host carries the Stop's exclusion tag and is kept running (§6.3). No scaling plan | One host, started when someone signs in; running whenever validation needs evidence (red-team C3) |
| Quota and cost | One more host's vCPUs. The preflight's quota check and price lines count it (decision 0010; lessons 0013, 0024) | No surprise at deployment |
| Opt-out | `AVD_QA_POOL = false`, guarded with `empty(...)` | Default on in every environment |

**A validation pool only helps if people use it.** Microsoft recommends that a couple of users sign in every day. So:
- the post-deployment preflight warns (`qa-pool-unused`) when `WVDConnections` shows no completed sign-in to the QA pool in two business days;
- once the second brain is running, that becomes a level 1 detection (§7).

### 6.3 Automated validation (the default)

Validation runs by itself. Nobody has to start it or sit through it: every build that passes §5.4 goes through the QA pools automatically, and a person gets involved only to promote a version to a production pool (§6.4). `AVD_IMAGE_VALIDATION = manual` turns the automation off; then a person runs each stage with `workflow_dispatch`.

**How it runs.**
- `image-build.yml` hands a successful build to `image-validate.yml` as a reusable workflow (`workflow_call`), in the same trusted run.
- From then on, `image-validate.yml` runs **hourly** on a schedule and moves each version one stage forward.
- A version's progress is a tag on the gallery version (`avdlz-validation`: the stage, the environment, and the soak end time), the same resumable pattern as rotation (§6.5). No job has to stay alive through a 24-hour soak, and a missed hour costs nothing.
- **Keeping the host up (red-team C3):** while a QA pool is in a stage, its host carries the scheduled Stop's exclusion tag (decision 0011's runbook honors it; verify for EX-0002, §11). The workflow starts the host if it finds it deallocated. The tag is removed when the stage ends, whether it passed or failed. The build issue shows the cost of the extra hours.
- **Stopping it:** `AVD_IMAGE_VALIDATION=manual` stops the automation, and the kill-switch workflow (second brain spec, EX-0004) sets it too. EX-0005 is otherwise unaffected by the kill switch (red-team H9).

| Stage | What happens | Passes when |
|---|---|---|
| **1 `test` QA** | Rotate `test`'s QA pool to the version (§6.5, `-HostPool qa`) | The checks below all pass |
| **2 `test` soak** | 24 hours (2 in emergency mode, §5.7). The host is kept running, and the checks run hourly | At least 20 of 24 runs had the host running, the failure rule below never tripped, and no detection fired for the QA pool |
| **3 `prod` QA** | Rotate `prod`'s QA pool to the version | The checks below all pass |
| **4 `prod` soak** | As stage 2. Organic sign-ins by QA users are collected | As stage 2. The version is tagged `avdlz-validated=<date>` and `excludeFromLatest` is set to `false`. The build issue gets the promotion command |

**The checks.** They are positive evidence (I4), and none of them needs a user's credentials:
- **Landing zone:** the post-deployment preflight comes back **Ready**. It runs read-only (`-SkipTenant -SkipNtfs`, never `-Fix`), with a defined check list, `-Profile ImageValidation` (red-team M8). Checks that need data-plane access or Graph, which the identity doesn't have, are reported as **skipped**, never failed. The in-host check covers what Reader can't see.
- **Host, from Azure:**
  - Available, accepting sessions, and every AVD session host health check passing;
  - running the expected image version;
  - its `Configure-FSLogix` and `Register-AvdAgent` run commands succeeded.

  These are the sign-in readiness checks of `Deploy-AvdDemo.ps1`, less the ones that need Microsoft Graph.
- **Host, from inside:** `scripts/ops/host/Test-SessionHostFunction.ps1` (Windows PowerShell 5.1) runs as a Run Command and checks:
  - the host is Entra ID joined and Intune enrolled (`dsregcmd /status` and the enrollment registry), because the validation identity has no Graph access (red-team H6). The Entra **device ID** and Intune enrollment ID are recorded as tags on the VM, for cleanup by ID (§6.5);
  - the RDP side-by-side listener is up and the agent reports a recent heartbeat;
  - FSLogix is configured with this landing zone's share, which resolves to a private IP and answers on TCP 445;
  - Microsoft 365 Apps shared computer activation is on;
  - automatic updates are off (§5.6);
  - every service protected from WDOT (§5.5) is running or set to start, and the functions they enable work: SMB to the share, a Kerberos ticket for the host, a Web Account Manager token request, an MSIX app launch (red-team H7);
  - the WDOT version and profile hash match the image's tags.

  It prints `RESULT` lines that the workflow quotes.
- **Posture:** open Defender for Cloud recommendations and guest configuration results for the QA host. These are warnings, not failures (decision 0009). They're listed for the person who promotes.

**What automation can't prove.** None of these checks signs in as a user. So a **real sign-in**, with its Entra Kerberos ticket and a mounted FSLogix profile, isn't covered. That's what QA users are for (§6.2):
- the soak collects **organic** sign-ins to the QA host from `WVDConnections`, and the FSLogix result from the host's event log;
- the promotion page shows how many completed sign-ins the version had, separately for members of the AVD Users group and for anyone else, and whether profiles attached;
- in small deployments, nobody may sign in to the QA desktop for days. So promotion itself collects the missing evidence (red-team S2, §6.4).

A synthetic sign-in could close the gap without a person. It is researched in build step 4 (Q8).

**What fails a version (red-team H2).** Checks are classified:
- **Image-attributable:** the host's AVD health checks, the in-host function checks, the image version. Only these can fail a version.
- **Landing-zone-wide:** the preflight and Service Health. When one of these fails, validation **pauses** and opens an issue. It resumes from the same stage when they clear. The image isn't blamed for the landing zone.

An image-attributable check fails the version when it fails **two runs in a row**, or in **more than 2 runs** of a soak. A single transient failure is reported, not fatal.

**On failure.**
1. The version is tagged `avdlz-validation=failed:<stage>:<check>`, and it is never promoted.
2. The QA pool rotates back to the previous validated version **automatically**. The QA pool exists to fail safely, and a failed canary mustn't leave QA users on a broken host.
3. An issue opens with every check's output, the step, status and error code (lesson 0012), and the customization log.
4. Once the cause is fixed, a person can retry a failed version **once** with `workflow_dispatch`, from the failed stage, without a new build. Otherwise the next build starts over from stage 1.

**Who can do what.** Automation reaches only the QA pools.
- Each QA pool lives in its own resource group, `rg-<prefix>-<env>-qa`, holding the QA host pool, its app group and its host.
- The `image-validate` identity, through OIDC and a GitHub Environment of the same name with no reviewers, deploys QA hosts with `bicep/qa/main.bicep` only (red-team C1). It has:
  - Contributor on the QA resource groups, which can't create role assignments;
  - subnet join on the session host subnet;
  - Reader and Log Analytics Reader for the checks.
- It can't touch a production pool, the hosts resource group, Key Vault or the budget. Promoting to a production pool stays with `image-promote.yml` and a person.
- The QA host's break-glass password is random and isn't stored, like the demo host's. **VM > Reset password** recovers access.
- Because this automation changes the QA pools without approval of each run, it is registered as pre-approved exception **EX-0005** in the second brain spec (§4.5.1), next to EX-0001 and EX-0002.
- The second brain's alert on Run Command writes allowlists this identity **on the QA resource groups only**. Anywhere else, a Run Command write by it still alerts (red-team H9).

### 6.4 Promotion

`image-promote.yml` (`workflow_dispatch`) takes the version and the target environment. It runs in that GitHub Environment, so `prod`'s required reviewers approve it, or in solo mode, the owner after the wait timer (second brain spec §9.3). It refuses a version without `avdlz-validated`, which means automated validation passed in both QA pools (§6.3). It shows the approver the checks, the posture warnings, and the organic sign-ins and profile attaches on the QA hosts. **One sign-in by the approver (red-team S2).** When the version has no completed sign-in by a member of the QA group on the target environment's QA host, promotion doesn't just ask for an acknowledgment, which would become a routine click.
1. It asks the approver to sign in to the "QA desktop" once, through the Windows App, with an account in the QA group: a regular user account, not an admin account (§6.2).
2. It waits up to 48 hours for that completed connection in `WVDConnections`, plus the FSLogix result from the host.
3. Then it continues.

So the person who approves is also the one real sign-in, with a real Entra Kerberos ticket and profile, that automation can't produce. Skipping the wait is still possible as an override with a recorded reason, for example in emergency mode (§5.7). Overrides are listed in the weekly digest, and the second brain counts them (`promotion-without-sign-in`, §7). It sets `avdlz-image-next` on the main pool and starts its rotation (§6.5). The pool's current image only changes when the rotation does (§6.1, red-team C2). It also lists stale QA device objects, with their IDs, for removal by a person with a Graph sign-in (§6.5).

Adopters without GitHub Actions run the same steps from Cloud Shell: the portal gives the commands.

### 6.5 Rotation

**Why a custom script (red-team S1).** Azure Virtual Desktop has a native **session host update**, used with a **session host configuration**. It replaces hosts with a new image or configuration under a management policy, and it overlaps most of this section. Published guidance at the time of writing says session host configuration doesn't support Microsoft Entra ID-joined hosts, which this landing zone uses exclusively (decision 0001), and that it applies to host pools created with it ([session host update](https://learn.microsoft.com/en-us/azure/virtual-desktop/session-host-update), [host pool management approaches](https://learn.microsoft.com/en-us/azure/virtual-desktop/host-pool-management-approaches)). This is to be verified at build (§11). Until that changes, rotation is the script below. The image build, validation, QA pools and promotion don't depend on the choice, so a move to the native feature would replace only this section. Decision 0013 records the revisit trigger.

`scripts/ops/Invoke-AvdHostRotation.ps1` runs in PowerShell 7 in Cloud Shell, calls ARM and Graph REST (`Invoke-AvdArm`, `Invoke-AvdGraph`), and ends with a state line (`stage: rotation`). Rotation is **resumable**: its state lives in a tag on the host pool (`avdlz-rotation`: from and to generation, version, phase, deadline, who started it), the same pattern as decision 0011's Lock. Running it again continues from the recorded phase, so a Cloud Shell disconnect costs nothing.

| Phase | What it does | Ends when |
|---|---|---|
| **Check** | Refuses if the host pool is `power-locked` (EX-0001). Checks vCPU quota for the new hosts: surge needs room for `sessionHostCount` more, and deployed hosts already count as used (lessons 0013, 0024); when it's short, prints the quota request. Checks the version (§6.1) | All checks pass |
| **Deploy** | Main pool: deploys the landing zone with the other generation and `avdlz-image-next`. QA pool: deploys `bicep/qa/main.bicep` (red-team C1). Existing hosts are untouched, because incremental deployment leaves VMs that aren't in the template. Records each new host's Entra device ID and Intune enrollment ID as VM tags, from the in-host check | Every new host is Available, passes the AVD health checks, and its run commands succeeded. Then `avdlz-image` and `avdlz-generation` are set to the new values, and the version gets its `avdlz-in-use-*` tag (§4.2) |
| **Drain** | Sets the old hosts to drain mode (no new sessions), saving each host's previous drain state. Sends users a message saying the host is being replaced and to sign out when convenient. Sets the deadline (default 72 hours) | Immediately; prints how many sessions remain |
| **Wait** | Each run reports the remaining sessions on old hosts. With `-LogOffAtDeadline`, once the deadline passes it sends a final message and logs remaining sessions off 15 minutes later. Without it, it only reports | No sessions remain on old hosts |
| **Remove** | Deletes the old session host objects from the host pool, then the old VMs (their disks and NICs go with them, `deleteOption: Delete`). With a Graph sign-in, also their Entra ID and Intune device objects, **by the IDs recorded at Deploy, never by name**: names are reused every other rotation (red-team H6). This is shared with `Remove-AvdDemo.ps1` as `Remove-AvdHostDevice`; never `| Out-Null` on `Connect-MgGraph` (lesson 0007). Without a Graph sign-in, it lists the IDs left to remove | Nothing of the old generation remains. The old version's `avdlz-in-use-*` tag is cleared, and so is the rotation tag |

Other rules:
- **QA pools always log off at a deadline:** 1 hour after Drain, with messages. QA users are told this is what the QA desktop is for, and an automated stage can't stall on a disconnected session (red-team H9). Production pools keep the opt-in default, except in emergency mode (§5.7).
- **The scaling plan keeps running.** It doesn't route new sessions to drained hosts, and it may deallocate empty old hosts early, which is harmless.
- **The break-glass password** (decision 0004) is new for the new hosts. Key Vault holds the latest password, as today.
- **Rollback:** before **Remove**, rotating back is the same script in reverse: undrain the old generation and drain the new one. After **Remove**, rolling back means rotating to the previous validated version (§4.2).
- **Large pools (red-team M6):** the Deploy phase creates new hosts in batches of 20 per replica, waiting for each batch to report Available before the next. That keeps within the gallery's replica throughput.
- **No surge capacity** (quota or cost): `-BatchSize` isn't in v1. The script stops at **Check** with the quota request, rather than shrinking capacity silently.

### 6.6 Teardown (red-team H4)

- `Remove-AvdDemo.ps1 -IncludeLandingZone` also removes the environment's QA resource group and the QA hosts' device objects, by ID (§6.5).
- A new switch, `-IncludeImages`, removes the images and staging resource groups and the gallery. It refuses while any landing zone's host runs a version from that gallery (`avdlz-in-use-*` tags, §4.2).
- Removing the **build** environment warns that builds will stop, and names the parameter that moves them (`AVD_IMAGE_BUILD_ENVIRONMENT`).
- New PostDeployment scenario cases cover each of these. A redeploy with the same name prefix after cleanup must not collide with leftovers (the pattern of lesson 0023).

## 7. Second brain integration

- **`replace-host`** (second brain spec §8, level 2, never EX-0003) deploys a single host from the environment's promoted version into the current generation, then removes the unhealthy one. It uses the same helpers as rotation.
- **Detections (level 1):**
  - `image-age`: the promoted version is older than 35 days;
  - `patch-sla`: a production host's patches are older than the targets in §5.7;
  - `image-mixed`: hosts in one host pool run different versions outside a rotation;
  - `rotation-stalled`: a rotation tag is older than its deadline plus 24 hours;
  - `validation-paused`: automated validation paused for a landing-zone-wide failure for more than 24 hours (§6.3);
  - `qa-pool-unused`: no completed sign-in to the QA pool in two business days (§6.2);
  - `promotion-without-sign-in`: a promotion overrode the approver's sign-in (§6.4). More than one in a quarter means the evidence is being skipped as a habit;
  - `qa-ahead-errors`: the QA pool runs a newer AVD agent or image than production and its error rate is above baseline. That is the early warning the QA pool exists for, raised before production's agent window;
  - `host-auto-updates-on`: a host reports automatic updates on, usually an Intune update ring overriding the image (§5.6).
- **Evidence:** the Tier 1 job records each host's image version. Baselines are split by version, so a regression after a rotation shows up as "this started with `2026.1004.1`".
- **Not autonomous.** Builds run on a schedule because they change no landing zone. Promotion and rotation are started by a person, as the second brain's human-in-the-loop rule requires.

## 8. Security

- **No secrets in the image** (§5.3). The build VM has no public IP and no inbound access. Its egress goes through the landing zone's NAT Gateway or the hub firewall.
- **Pinned scripts (I3, red-team C4):** every customizer is inlined into the template from the commit being built, so its content is the commit's and nothing is fetched from this repository. WDOT, the only download, is checked file by file against the lock (§5.5).
- **Least privilege:**
  - the AIB identity holds the two custom roles plus Contributor on the staging group only;
  - the build workflow's identity can only deploy and run templates in the images group;
  - the `image-validate` identity can change only the QA resource groups (§6.3);
  - promotion to a production pool needs the target environment's approval.
- **Traceability:** every version's tags name its commit, source image and run, and the run keeps the customization log.
- **Posture:** the QA host is covered by Defender for Cloud and guest configuration like any host. Findings on it are shown at promotion as warnings, not failures (decision 0009). A person decides, with the findings in front of them.
- **New GUIDs** (built-in role IDs, if any role is assigned by ID) go into `PUBLIC_IDS` (decision 0008).

## 9. Repository layout and guards

```
bicep/images/main.bicep          gallery, definition, identity, roles (entry point, carries the notice)
bicep/images/build.bicep         per-build image template
bicep/modules/network.bicep      + snet-image-build, snet-image-aci (deployImageBuildSubnets)
bicep/modules/sessionHosts.bicep + generation in names; imageReference by id
parameters/images.bicepparam     region, replica storage, retention, build environment
scripts/image/                   customizers and Test-GoldenImage.ps1 (Windows PowerShell 5.1)
scripts/image/custom/            adopter customizations (empty here)
scripts/image/wdot/              wdot.lock.json (version, URL, SHA-256) and profile/ (reviewed OptimizationState JSON)
bicep/modules/qaPool.bicep       QA resource group, host pool, app group in the workspace, role assignments
bicep/qa/main.bicep              QA host only, at the QA resource group's scope (automated validation and rotation)
scripts/ops/host/Test-SessionHostFunction.ps1   in-host checks for automated validation (5.1)
scripts/ops/Invoke-AvdHostRotation.ps1
.github/workflows/               image-build.yml, image-validate.yml (workflow_call and hourly), image-promote.yml
build/tests/offline/HostRotation.Scenario.ps1, ImageBuild.Scenario.ps1
```

Guards, added with the first slice, following decision 0006:

| Guard | Catches |
|---|---|
| Template test: parameter files compiled with `AVD_SESSION_HOST_IMAGE_ID` unset, empty and set | The empty-string trap (lesson 0004); the marketplace default holding |
| Template test: version names for a January and an October date are valid and compare in date order; replica count follows the largest pool's size | M1, M6 |
| Offline scenario `ImageBuild`, extra cases: an orphaned template is swept with its log saved; a build family short on quota stops before the run; a failed generalization fails the build; a newer version supersedes one in validation | M2, M3, M5, M7 |
| Offline scenario `ImageValidation`, extra case: a preflight check the identity can't run is reported skipped, not failed | M8 |
| Template test: names unchanged with the default generation; valid and distinct for `a` and `b`; at most 15 characters | Replacing existing hosts by accident; NetBIOS length |
| Template test: the definition is V2 with `TrustedLaunch` and accelerated networking; replica storage is ZRS in a zoned region and LRS in one without zones | Trusted Launch deployment failures; lesson 0001 |
| Template test: the build template has no `scriptUri` and no GitHub raw URL; every script in `scripts/image` is a build step; every WDOT profile file is inlined byte for byte | Unpinned scripts; fetches that fail for private forks (C4) |
| Template test: `bicep/qa/main.bicep` creates no role assignments and writes nothing outside the QA resource group | Automated validation reaching the landing zone (C1) |
| Offline scenario `Redeploy`: a routine deployment before, during and after a rotation uses the host pool's `avdlz-image` and `avdlz-generation` tags, refuses during a rotation, and never changes an existing VM's image or recreates a removed generation | C2 |
| Offline scenario `ImageValidation`, extra cases: the QA host deallocated by the scheduled Stop mid-soak (kept running, counted); one transient failure (reported, not fatal); a preflight failure (paused, resumed); retry from the failed stage | C3, H2 |
| Offline scenario `HostRotation`, extra cases: device cleanup by recorded ID with a same-name stale object present (only the old host's object is removed); in-use tags set at Deploy and cleared at Remove; QA log-off at 1 hour | H5, H6, H9 |
| PostDeployment scenario: `-IncludeLandingZone` removes the QA group; `-IncludeImages` refuses while a version is in use | H4 |
| Template test: a replica per environment region, with ZRS or LRS chosen per region; a Reader grant per environment identity when subscriptions differ | H8 |
| Pester: the WDOT profile keeps every protected item (§5.5, the extended list) `Skip`, AppxPackages and the advanced categories are off unless opted in, and the lock file has a SHA-256 | Silently broken Intune, Defender, search or RDP |
| Template test: the QA pool exists by default with `validationEnvironment: true`, one host, an earlier agent update window, and names distinct from production; it's absent with `AVD_QA_POOL=false`; the quota and price lines count its host | The maintenance ring's guarantees; decision 0010 |
| Offline scenario `ImageBuild`: a failed build reports the step, code and log tail; the poll loop ends on error | Lessons 0008, 0012 |
| Offline scenario `ImageValidation`: the four stages advance one per run; resume after a missed run; a failure at each stage rolls the QA pool back, tags the version and opens an issue; manual mode does nothing on its own | The state machine and its rollback |
| Template test: the `image-validate` identity's role assignments are scoped to the QA resource groups (plus subnet join and readers), never the hosts group or a production pool | Automation reaching production |
| Offline scenario `HostRotation`: each phase, resume after a disconnect at every phase, refusal while locked, a quota shortfall, `-LogOffAtDeadline` off and on, device cleanup without a Graph sign-in (a warning, not a failure) | Resumability and its edge cases. Mock paths added to `AzMock.psm1`, which omits empty properties like ARM does (lesson 0021) |
| Portal tests: `stage: rotation` and `image` state lines, and the commands with `--image-id` and `--generation` | Decision 0007 drift |
| PSScriptAnalyzer over `scripts/image/` in its 5.1-compatible settings | Lesson 0011 |
| Disclaimer test over the new entry points | The project notice |

## 10. Phases

| Step | Delivers | Exit criterion |
|---|---|---|
| **1 Gallery and build** | `bicep/images`, build subnets, `image-build.yml`, customizers including WDOT, `Test-GoldenImage.ps1` | A scheduled build produces a version with every validation `Pass`, in a region with zones and in one without |
| **2 Parameters and QA pool** | `AVD_SESSION_HOST_IMAGE_ID`, generations, the QA pool, `deploy.sh` flags, preflight check, portal | dev deploys from a gallery version, with a QA pool whose host reports automatic updates off; the default still deploys the marketplace image with unchanged production names |
| **3 Rotation** | `Invoke-AvdHostRotation.ps1`, device cleanup shared with `Remove-AvdDemo.ps1` | `test` rotates a → b → a, resumed after a deliberate disconnect, and a real sign-in lands on the new generation each time |
| **4 Automated validation and promotion** | `image-validate.yml`, `Test-SessionHostFunction.ps1`, `image-promote.yml` | A scheduled build validates through both QA pools with nobody running anything. One deliberately broken build fails, rolls the QA pool back and opens an issue. One emergency build reaches a promotion-ready state within 24 hours. One good version is promoted by a person, after the approver's own sign-in to the QA desktop, and rotated into `prod`'s main pool, with the post-deployment preflight Ready afterwards. A written answer to Q8 (synthetic sign-in), from what step 4 learned |

When step 4 passes, phase 0b is done, and the second brain's phase 1 can start.

## 11. Verify at build

Each of these is an assumption in the spec, to confirm against the docs and a real run before relying on it:

- AIB isolated builds with `containerInstanceSubnetId`: the subnet delegation and the network policies each subnet needs, and that no proxy VM or Private Link service is created.
- AIB builds for a Trusted Launch gallery definition from the `win11-24h2-avd-m365` source.
- The AIB PowerShell customizer's `sha256Checksum` field, and the `validate` phase's `continueDistributeOnFailure`.
- `Standard_ZRS` replica storage in the chosen regions.
- GitHub Actions cron semantics, where day-of-month and day-of-week combine as OR.
- Whether AIB source-image triggers could replace the schedule (Q2).
- WDOT at the pinned release: the parameter names, the profile layout, and which items its default profile applies. In particular, whether any protected item (§5.5) is `Apply` by default.
- That Defender signature updates keep working with `NoAutoUpdate = 1`, and the exact Microsoft 365 Apps update policy key.
- That decision 0011's runbook (EX-0002) finds the QA pool's host, which sits in a second host pool.
- How scheduled agent updates interact with a validation pool: whether the service still flights agents to it first inside its own window.
- How the Defender platform (engine) updates with automatic updates off (§5.6).
- That decision 0011's runbook honors the exclusion tag for the scheduled Stop (EX-0002) as well as the Lock (§6.3).
- AIB running long inline PowerShell customizers (the WDOT step carries the profile as base64) and the inline `validate` step (§5.2).
- WDOT's download from `github.com` through the build environment's egress, and AIB's customization log in the staging account's `packerlogs` container, read by the build identity with Storage Blob Data Reader (§5.2, `Start-AvdImageBuild.ps1`).
- Whether AIB's build account is enabled on the image after generalization (`Test-GoldenImage.ps1` allows the build's own account).
- That reading `dsregcmd /status` and the Intune enrollment registry from a Run Command gives the device and enrollment IDs (§6.3).
- Whether session host configuration and session host update support Microsoft Entra ID-joined hosts, and whether an existing host pool can adopt them (§6.5, S1). Check again at every new build phase, and before rotation work starts.
- The list of AVD session host health checks the ARM API returns, and that Contributor on the QA resource group plus subnet join is enough to register a host to the QA pool.

## 12. Open questions

- **Q1** Preinstall the AVD agent and Boot Loader in the image, for faster registration? Default **no**: `Register-AvdAgent` installs the current version, and it already handles a preinstalled agent if an adopter wants one.
- **Q2** Schedule or AIB source-image triggers? The schedule is the default until triggers are verified (§11).
- **Q3** When to move to the next Windows 11 release: a new image definition per release (`25h2`), run side by side through a canary.
- **Q4** Should the project publish a community gallery image for adopters? Recommended **no**: supply chain trust and cost would fall on one maintainer, and each adopter's own build is traceable to their own commit.
- **Q5** Should `-LogOffAtDeadline` be the default in `prod`? Recommended **no**: losing unsaved work is worse than a slower rotation.
- **Q6** Opt in to WDOT's AppxPackages removal once a build passes with it? Recommended **yes, after** one passing build and a lesson recording which packages it removed.
- **Q7** Keep the QA pool on by default in dev and test, whose main pools are already validation environments? Recommended **yes**: it's also each environment's image canary, and one host with Start VM on Connect and the nightly Stop costs little.
- **Q8** Add a **synthetic sign-in** to automated validation? It would need a dedicated test account and a Windows client signing in through the Windows App, with an MFA policy that suits automation. That puts a credential and a Conditional Access exception in the adopter's tenant. Third-party logon simulators exist ([eG Logon Simulator](https://www.eginnovations.com/blog/free-logon-simulator-for-avd-azure-virtual-desktop-now-available/)); Microsoft offers none. **Moved up (red-team S2):** research it in build step 4, because it would carry the evidence for small adopters. Until then, the approver's single sign-in at promotion (§6.4) is the evidence.
