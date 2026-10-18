# Spec: Liquidware ProfileUnity, FlexApp and CommandCTRL as an optional upgrade

- **Status:** Proposed (see [decision 0016](decisions/0016-liquidware-upgrade.md)). Red-teamed in [liquidware-redteam.md](liquidware-redteam.md); every finding is folded in below and tagged with its ID (C1, H2, …).
- **Date:** 2026-10-18
- **Scope:** an opt-in tier on top of what this repo deploys today, plus a delivery pattern for customer environments run by Nerdio Manager for Enterprise. Nothing changes in the default deployment. Nothing is built by this spec.

This is a personal project, not for production, provided as is. Nothing here has run against a real tenant. §12 lists every vendor fact this spec relies on, where it came from, and what is still unverified. Liquidware, ProfileUnity, FlexApp, FlexApp One, Stratusphere and CommandCTRL are trademarks of Liquidware; this repo is not affiliated with Liquidware or Nerdio.

## 1. Summary

The landing zone gives every user an FSLogix profile container on Azure Files with Entra Kerberos (proven end to end on 2026-10-18, lesson 0028). Apps come from the image, Intune or native app attach. That is the right default, and it stays the default.

Some customers need more than that, usually because they are leaving Citrix, Omnissa Horizon or Ivanti, or moving from Windows 10 to 11, or replacing Group Policy Preferences after going Entra-only. Liquidware's workspace stack covers those gaps, and it is the stack this spec adds as an **optional upgrade**:

| Product | What it adds over the default | Where it fits |
|---|---|---|
| **ProfileUnity** | Profile *portability* (settings move between OS versions and between FSLogix and other profile types), user environment management that replaces GPP on Entra-joined hosts (drives, printers, shortcuts, registry, ADMX), context filters, application restrictions with audit events | Logon and session, on the session host |
| **FlexApp** | App layering from VHDX or cloud packages: per user or group, click-to-layer, block caching, and since 6.8.7 **delivery through AVD app attach**. FlexApp One packages are self-contained and Nerdio can assign them. FlexApp Sandbox Isolation (6.9.5) runs an app in Windows Sandbox | App delivery, beside or instead of MSIX app attach |
| **CommandCTRL** | Real-time endpoint telemetry with DVR-style history, browser remote control with user consent, file and diagnostics collection, optional AI analysis with your own model provider. SaaS | Day-2 support for session hosts **and the devices users connect from** |
| *Stratusphere UX* | Assessment, sizing and long-term UX history | Before the project: the forensic sizing tier, specced separately (see §9.3). Named here only so the two don't overlap |

**The recommended shape** (§4): keep FSLogix as the profile container, add ProfileUnity for portability and user environment management, deliver FlexApp packages through AVD app attach, and add CommandCTRL where a support desk needs it. ProfileDisk replacing FSLogix is a later, gated option, not the default upgrade.

## 2. Goals and non-goals

### Goals
1. A documented, repeatable way to add ProfileUnity, FlexApp and CommandCTRL to a landing zone from this repo **or** to a customer's existing Nerdio-managed AVD environment, without changing the default deployment.
2. A clear rule for which product owns each job (profile container, settings, apps, support), so two products never manage the same thing (H1, H5).
3. Keep this repo's security posture: Entra ID only, private endpoints, no storage keys for profiles, no secrets operators must remember. Where a vendor or Microsoft requirement forces an exception, it is isolated, named and tested (C1).
4. Facts the second brain can read and actions the swarm can plan, with the same governance as everything else (§10).
5. Every cost estimated before any sandbox run (§11).

### Non-goals
- **Replacing FSLogix by default.** It is free with the license, built into the image, and proven here.
- **AD DS or Entra Domain Services.** Decision 0001 stands. A Liquidware feature that needs a domain is out of scope for this repo's landing zone (it may still be fine in a customer's hybrid environment, see §8).
- **Other vendors.** Only Microsoft, Nerdio and Liquidware paid products are in scope.
- **Liquidware licensing or commercial terms.** Quotes come from Liquidware or a partner.
- **Building anything now.** Phases in §13 each need Nick's go.

## 3. Principles

| # | Principle | Source |
|---|---|---|
| L1 | Default deployment unchanged: no new resources, parameters or deploy time unless `AVD_LIQUIDWARE` is set | verify-access V5, image pipeline |
| L2 | Entra ID only. If a path only works with a domain, the spec says so and that path is out (or customer-hybrid only) | decision 0001 |
| L3 | One owner per job: profile container, settings, app assignment, remote support | H1, H5 |
| L4 | Storage keys never touch the profiles account. Any key-based path gets its own read-only packages account, keys in Key Vault, rotated, never shown to an operator | README posture, lesson 0002, C1 |
| L5 | No new standing admin surface without private access, patching and backup. A management VM is a cost and a target | C2 |
| L6 | Remote control and remote shell are write paths: off by default, consent always, never available to agents | avd-swarm governance, C3 |
| L7 | A vendor claim is a hypothesis until a spike or the docs confirm it (§12) | lesson 0012, decision 0006 |
| L8 | No sandbox spend without an estimate; personal sandbox first, smallest SKU, shortest run, tear down at once | spend rule (2026-10-18) |

## 4. Which product owns what

### 4.1 Profile options

| Option | Container | Settings and migration | When |
|---|---|---|---|
| **P0. Default** | FSLogix | none | Greenfield, one OS version, no GPP to replace |
| **P1. Recommended upgrade** | FSLogix | ProfileUnity Portability for chosen settings; ProfileUnity user environment management | OS migrations (Win10 → 11, Server 2022 → 2025), moving users off Citrix UPM / Horizon DEM / Ivanti, GPP replacement on Entra-joined hosts |
| **P2. Gated** | ProfileUnity ProfileDisk | ProfileUnity Portability | Only if spike L0 proves ProfileDisk on Entra-only Azure Files *and* a customer needs something FSLogix can't do. Not offered until then (V4) |

**P1 exclusion rule (H1).** FSLogix owns the container; Portability may only capture a named list of settings paths. The same path is never captured by Portability *and* left in the container for roaming, and never all of `AppData\Local` (Liquidware's known issues list it as a cause of long logons and broken folder redirection). The spec ships a starting exclusion matrix in the build phase, tested by a template test that rejects overlaps.

### 4.2 App delivery options

| Option | Format | Assigned by | When |
|---|---|---|---|
| **A0. Image** | installed | image pipeline | Apps everyone needs |
| **A1. Intune** | Win32 / MSIX | Intune | Per-user apps that tolerate install time |
| **A2. Native app attach** | MSIX, Appx, App-V on CimFS or VHDX | AVD app attach (or Nerdio) | Apps that already have MSIX |
| **A3. FlexApp through app attach** (recommended FlexApp path) | FlexApp package | AVD app attach workflows (or Nerdio) | Apps that don't convert to MSIX: legacy installers, drivers-free LOB apps, App-V leftovers |
| **A4. FlexApp through ProfileUnity rules** | FlexApp VHDX or cloud package | ProfileUnity console filters | When per-user context filters (IP, client, time) matter more than one assignment system |
| **A5. FlexApp One through Nerdio** | FlexApp One | Nerdio | Customer environments where Nerdio already owns app assignment |

**One assignment system per app (H5).** An app is assigned in exactly one of A2–A5. The build phase adds a check to the post-deployment preflight that lists apps found in more than one system and warns. A3 is preferred over A4 because it keeps one assignment surface (the AVD control plane) that this repo, Nerdio and the second brain already read.

**Isolation (H2).** FlexApp Sandbox Isolation needs Windows Sandbox and, inside a VM, nested virtualization. It is **off** in this tier. Turning it on is a separate decision after checking it against Trusted Launch, the VM sizes the portal offers, and the image's security baseline.

### 4.3 Support and telemetry

| Job | Owner | Not |
|---|---|---|
| Alerts, health, AVD connection telemetry | Azure Monitor, AVD Insights (already deployed) | CommandCTRL |
| Real-time "what is this host doing right now", short history, remote assistance | CommandCTRL (optional) | Azure Monitor |
| Assessment, sizing, long-term UX baselines | Stratusphere UX (separate tier) | CommandCTRL history: turned off where Stratusphere collects (§9.3) |

## 5. Architecture

```
                         ┌─────────────────────── landing zone spoke (existing) ───────────────────────┐
 Admin (Bastion/JIT) ──► │ snet-mgmt (new, only with AVD_LIQUIDWARE)                                    │
                         │   ProfileUnity Management Console VM  (Windows Server 2025, MongoDB, :8000)  │
                         │      ├─ Entra sign-in for admins; Graph app for Entra group filters (V6)     │
                         │      └─ License Service :443  ◄── session hosts (LICSTR)                     │
                         │                                                                              │
                         │ snet-hosts (existing)  session hosts                                         │
                         │   FSLogix (unchanged) ──► profiles account (Entra Kerberos, no keys)         │
                         │   ProfileUnity client ──► config + portability share (user context, V2/V3)   │
                         │   FlexApp via app attach ──► packages account (read-only, PE, keys in KV) C1 │
                         │   CommandCTRL agent ──► 443 outbound to Liquidware SaaS (optional, V9)       │
                         └──────────────────────────────────────────────────────────────────────────────┘
   Packaging Console VM: on demand, separate RG, deallocated after packaging, never in the host subnet
```

### 5.1 New resources (only when `AVD_LIQUIDWARE=true`)

| Resource | Notes |
|---|---|
| `snet-mgmt` and its NSG | Inbound 8000 from Bastion and the admin range only; 443 from `snet-hosts` for licensing |
| ProfileUnity console VM | Smallest SKU that meets Liquidware's requirements (V5). Trusted Launch, encryption at host, no public IP, Entra login, Azure Backup, Update Manager. **Excluded from auto shutdown** until V7 says hosts can log on without it (M6) |
| Config and portability share | A second share on the **existing** profiles account if spike V2/V3 proves user-context Entra Kerberos access works; otherwise Azure Blob with Entra auth if supported (V3) |
| Packages storage account | Separate account, only for app attach images (MSIX and FlexApp). Shared-key access **on** because Microsoft requires it for app attach on Entra-joined hosts (§6). Private endpoint, no public network, keys in Key Vault, rotated by runbook. Never holds profiles |
| Key Vault secrets | Packages account keys; ProfileUnity console service credentials if any (V8) |
| Role assignments | Reader and Data Access on the packages account for the *Azure Virtual Desktop* and *Azure Virtual Desktop ARM Provider* service principals (Microsoft's documented requirement, which also grants the service access to all data in that account, which is why the account holds nothing else) |
| CommandCTRL | No Azure resources: agent via Intune or Run Command, outbound 443 |

### 5.2 Host configuration

Follows the image pipeline rule: **the image is generic, the landing zone configures it.**
- The ProfileUnity client binary may go in the image's optional customization folder; per-landing-zone settings never do (H6).
- A new managed Run Command, `Configure-ProfileUnity`, runs after `Configure-FSLogix` and before `Register-AvdAgent`: installs the standalone client if missing (`ACCEPTEULA=1 E=1 USERINI=… CLIENTXML=… LICSTR=…`), Windows PowerShell 5.1, no modules (CLAUDE.md host rule).
- In Nerdio environments the same script is a Nerdio scripted action (§8).
- Minimum version **6.9.5**: it fixes Entra filter Graph calls that hung logon, removes the WMI dependency from licensing, encrypts INI content by default, and blocks upgrades of insecure MongoDB installs (M1, M2).

## 6. Identity and storage, path by path

This is the part that decides whether the tier fits an Entra-only landing zone. Each path names the identity that touches storage and its status.

| # | Path | Identity | Entra-only status |
|---|---|---|---|
| 1 | FSLogix container | user, Entra Kerberos | **Proven** (lesson 0028) |
| 2 | ProfileUnity user INI read at logon | user | Expected to work on an Azure Files share with Entra Kerberos and share RBAC read. **Verify V2** |
| 3 | Portability files write at logoff | user | Same mechanism as 2, read/write. **Verify V3** |
| 4 | ProfileUnity client service and startup configuration (machine context) | LocalSystem (6.9.5) uses the *machine account*; older versions a domain service account | An Entra-joined machine account can't get an Entra Kerberos ticket for Azure Files. So machine-context configs must read from a cloud path with encrypted credentials (`AZCRED`), or not be used. **Verify V8**; until then, no startup (machine-context) configuration in this tier (C1) |
| 5 | FlexApp via AVD app attach | session host computer account | Microsoft: on Entra-joined hosts with Azure Files, app attach needs the RBAC above and "access keys or Microsoft Entra". **Packages account with keys, isolated** (C1). Verify the "or Microsoft Entra" half in V1, and drop keys if it works |
| 6 | FlexApp through ProfileUnity rules (A4) | user or client service | Depends on 2 and 4. Not offered until V1/V8 pass |
| 7 | ProfileDisk (P2) | client service | ProfileDisk doesn't support cloud providers (Liquidware docs). **Verify V4**; P2 stays gated |
| 8 | Console reading Entra groups for filters | console app identity via Graph | Needs an app registration with a Graph read permission. Which permission and whether it can be certificate or managed identity: **Verify V6**. Never a client secret an operator types (lesson 0002) |
| 9 | Console reading AD | LDAP to domain controllers | **Out**: no DCs in this repo (decision 0001). Customer-hybrid only |

**Fail closed.** If V1 fails (keys can't be avoided) the packages account still isolates them. If V2/V3 fail, the tier falls back to cloud paths with credentials in Key Vault, which is a second key-based account and a decision for Nick, not a silent change. If V8 fails, machine-context configuration stays out.

## 7. Security

- **Console VM (C2).** It is the only Windows server in the landing zone, holds the whole user environment policy and a MongoDB database, and in hybrid mode talks to domain controllers. So: no public IP, admin access only through Bastion or JIT, Entra login with the admins group, Defender for Servers if the customer has it, patched by Update Manager, backed up daily, MongoDB on Liquidware's secured defaults (6.9.5 blocks insecure ones). The Swagger API stays off unless the second brain integration (§10) is built, and then reachable only from `snet-mgmt`.
- **Packages account (C1).** Read-only data plane for hosts; write only from the packaging workflow; keys rotated monthly by the existing Automation account; a template test fails if the profiles account ever enables shared-key access or if the packages account ever holds a `profiles` share.
- **CommandCTRL (C3, H3).** Treated as a remote-access tool:
  - remote control and shell **off** by default; on per role, never for agents or automation identities;
  - end-user consent prompt kept on (it is the product's default);
  - AI Insights **off** by default. If turned on, it uses the project's own provider and credentials, and Liquidware's tokenization of user names, hosts, IPs, domains and paths is confirmed in V10 first;
  - its audit log is exported to Log Analytics if the product allows (V11);
  - the swarm's kill switch (avd-swarm `docs/governance.md`) gets a CommandCTRL step: disable the tenant's remote control and shell. Agents never hold CommandCTRL credentials.
- **Application Restrictions** (ProfileUnity) log to the Windows event log; the AMA data collection rule gains that channel so restrictions show up in Log Analytics.

## 8. Nerdio Manager customer environments

Most deliveries are into a customer's existing environment with Nerdio Manager for Enterprise. There, Nerdio owns host pools, images and (by the established boundary) FSLogix share creation. This tier adapts:

| Job | Greenfield (this repo) | Customer with Nerdio |
|---|---|---|
| Console | `AVD_LIQUIDWARE` deploys it | Customer's existing console if any; otherwise the same VM pattern deployed by the customer's IaC |
| Client install and settings | `Configure-ProfileUnity` Run Command | Nerdio scripted action running the same script |
| FlexApp One | not used | Nerdio assigns (A5) |
| FlexApp packages | app attach (A3) | app attach through Nerdio's app attach UI if supported (V12), else ProfileUnity rules (A4) |
| AD DS paths (§6 row 9, domain service account) | out | allowed if the customer is hybrid; documented as customer-owned |

The Nerdio scripted action and its parameters are a deliverable of phase L2. Whether Nerdio's Unified Application Management handles FlexApp packages directly is unverified (V12); if it does, it becomes the A5 owner for that customer.

## 9. CommandCTRL: where it fits

**Yes, there is a fit,** but as a support tool, not as monitoring and not as an actor.

1. **Session-host support.** Real-time process, logon and resource view on a multi-session host while a user is on the phone, plus DVR history for "it was slow at 10:05". Complements AVD Insights, which shows connection health but not what a process did.
2. **The devices users connect from.** Agents exist for Windows (including ARM), macOS, Linux, IGEL OS 12 and eLux, so one tool covers the session host *and* the thin client. This links to the clean-room thin-client spec, drafted outside this repo.
3. **Liquidware diagnostics in one place.** CommandCTRL 1.5 collects ProfileUnity and Stratusphere product diagnostics and arbitrary log files without a remote session, which shortens ProfileUnity support cases.
4. **Cheap to try.** The Community Edition is free for 5 machines with 24-hour history: enough for spike L0 at $0 license cost.

### 9.1 Not a fit
- **Alerting or SLOs:** Azure Monitor owns those (§4.3).
- **An action channel for the swarm:** its shell and remote control would bypass plans, approvals and the kill switch (C3).
- **Long-term history where Stratusphere runs:** turn off CommandCTRL history collection and use its Stratusphere History button instead (product feature in 1.5).

### 9.2 Multi-session caveats
- Sampling interval is configurable (10–60 s); start at 60 s on multi-session hosts and measure agent overhead in L0 (V9).
- Remote control on a multi-session host must target one user's session with that user's consent; confirm in V9 that it can't attach to another user's session.
- Data leaves the tenant for Liquidware's SaaS. Region and retention are unverified (V11); a customer with residency rules decides before install.

### 9.3 Stratusphere
Stratusphere is the assessment and sizing tier, placed in its own spec. This tier consumes its output (user counts, app inventory, logon times) to choose which apps become FlexApp packages and which settings Portability carries. Both products' history is never collected twice.

## 10. Second brain and swarm hooks

Rule (2026-10-18): avd-swarm and avd-second-brain stay connected; a change in one is integrated in the other. These hooks are **proposals**; each lands in both repos in the same phase, or not at all.

### 10.1 Facts the second brain reads (read-only)

| Fact | Source | Notes |
|---|---|---|
| `liquidware.version` per host | registry / file version via Run Command or Intune inventory | Floors in §5.2 |
| `liquidware.flexapp.assignments` | AVD app attach API (A3), ProfileUnity console API (A4), Nerdio (A5) | Feeds the one-assignment check (H5) |
| `liquidware.profileunity.config` | console REST API (Swagger, V13) or the deployed INI | Hash and timestamp, not content |
| `liquidware.restrictions.events` | Windows event log via AMA → Log Analytics | Counts per app per day |
| `liquidware.logon.phases` | ProfileUnity client log and Stratusphere | Logon time split, joins AVD Insights' logon data |
| `commandctrl.agent.present` | Intune or Run Command | No CommandCTRL telemetry is pulled into the brain until V11 settles data handling |

### 10.2 Detections (level 1, report only)
- `lw-version-floor`: a host runs ProfileUnity below 6.9.5;
- `lw-double-assignment`: an app is assigned in two systems (H5);
- `lw-portability-overlap`: Portability captures a path FSLogix also roams (H1);
- `lw-logon-regression`: ProfileUnity's share of logon time rises above baseline after a config or package change;
- `lw-packages-key-age`: packages account keys older than the rotation period;
- `lw-console-unreachable`: hosts report license or config fetch failures.

### 10.3 Swarm actions (plans approved through GitHub Environments)
- assign or swap a FlexApp package version in app attach (blue/green: new version to the QA pool first, as the image pipeline does);
- roll a ProfileUnity configuration (deploy INI) to the QA pool, then production;
- rotate packages account keys.

**Never** a swarm action: CommandCTRL remote control or shell, editing the console's database, changing Portability exclusions without a template test run, or enabling isolation.

## 11. Cost

Spend rule: Nick pays; estimate first, evidence after, teardown evidence, monthly reconciliation.

### 11.1 Ongoing (customer or landing zone)
- **Licenses:** ProfileUnity/FlexApp and CommandCTRL Commercial are quoted by Liquidware or a partner; not priced here.
- **Azure:** console VM (always on, M6), its disk and backup; packages account (Premium Files or Standard, by package count); Log Analytics ingestion for the restriction events. The preflight's price lookup prices these from retail meters when the tier is built (decision 0010: never guess a price). The retail price API wasn't reachable from the session that wrote this spec, so no number is given here.

### 11.2 Spike L0 (the owner's personal sandbox)
- **Licenses:** Liquidware trial (ProfileUnity/FlexApp) and CommandCTRL Community Edition: $0.
- **Azure, one run, northcentralus, target under 4 hours:** the existing dev landing zone's one session host (already sized), one console VM at the smallest supported SKU, a packages storage account with a few GiB, Bastion only if no other admin path exists (Bastion is the largest line; prefer Run Command for console setup).
- **Before the run:** price the list with the preflight's retail lookup, post the estimate, get Nick's go. **After:** teardown evidence (RG not found), spend evidence kept privately, outside this public repo.

## 12. Facts and what is still unverified

Checked 2026-10-18 from vendor pages. "Verify" items are gates for spike L0.

| # | Fact | Source | Status |
|---|---|---|---|
| F1 | ProfileUnity/FlexApp 6.9.5 GA (2026-05-26 notes, 2026-06-02 announcement): Sandbox Isolation, allow+deny app restrictions logged to the event log, .NET 10 console, single-file installer for Intune/SCCM, supports AVD and Windows 365 | Liquidware 6.9.5 release notes and blog | Checked |
| F2 | 6.9.5 fixes: Entra filter Graph calls no longer hang logon; App attach syncs FlexApp packages; app attach apps install with ProfileDisk or FSLogix; INI encrypted by default; insecure MongoDB blocks upgrade | 6.9.5 release notes | Checked |
| F3 | Isolation needs Windows Sandbox and nested virtualization in VMs | 6.9.5 release notes | Checked |
| F4 | FlexApp integrates with AVD app attach (announced 2024-11-01, 6.8.7) | Liquidware press release | Checked; formats and Entra-joined behavior not stated |
| F5 | Standalone client: EXE/MSI, args `USERINI`, `SYSINI`, `CLIENTXML`, `LICSTR`, `AZCRED`, `ISOLATE`; supports non-domain-joined endpoints; cloud paths S3, Azure, GCS | ProfileUnity 6.9.5 docs, standalone client installer | Checked; "Azure" means Blob per the cloud storage page; Entra-joined not named |
| F6 | Cloud storage: Portability and FlexApp on S3, Azure Blob, GCS; FlexDisk, ProfileDisk and Folder Redirection not on cloud storage | ProfileUnity 6.8.6 docs, using cloud storage | Checked (6.8.6 page); recheck for 6.9.5 |
| F7 | Console uses port 8000 (admin), 443 (licensing), 27017 (MongoDB cluster), LDAP to DCs, SMB to NETLOGON for the domain-based install | ProfileUnity 6.8.7 port requirements | Checked |
| F8 | 6.9.5 LocalSystem option for the startup service uses the machine account; non-domain images can't grant a domain service account "log on as a service" | Liquidware KB "Running ProfileUnity and FlexApps at boot using a Service Account" | Checked |
| F9 | App attach on Entra-joined hosts with Azure Files: Reader and Data Access for the AVD and AVD ARM Provider service principals; mounts use the computer account; "access keys or Microsoft Entra"; keep only app attach apps in that account, rotate keys | Microsoft Learn, app attach overview | Checked |
| F10 | CommandCTRL 1.5 GA 2026-07-08: AI Insights with your own provider (ChatGPT, Azure OpenAI, Grok, Claude), tokenization before data leaves the endpoint, browser remote control with consent prompt, Stratusphere history button, IGEL/eLux/ARM64 agents, ProfileUnity diagnostics collection; Community Edition 5 machines, 24 h DVR | Liquidware blog 2026-07-13 | Checked |
| F11 | Nerdio can assign FlexApp One packages to AVD | Nerdio blog (2022, updated 2026-01) | Checked; current UI and UAM support not confirmed |
| V1 | App attach of FlexApp packages on Entra-joined hosts works without storage keys (the "or Microsoft Entra" half of F9) | spike | **Unverified** |
| V2/V3 | ProfileUnity INI read and Portability write over Azure Files with Entra Kerberos in user context | spike | **Unverified** |
| V4 | ProfileDisk on Entra-only Azure Files | spike | **Unverified**; P2 gated on it |
| V5 | Console VM minimum size and OS for 6.9.5 | Liquidware install guide (6.9.5) | **Unverified** |
| V6 | Graph permission and credential type for Entra group filters (certificate or managed identity) | Liquidware docs or support | **Unverified** |
| V7 | Can hosts log on (cached license, cached INI) while the console is down? | spike | **Unverified**; decides auto shutdown for the console |
| V8 | `AZCRED` credential type (key, SAS, Entra) and whether machine context can use Entra | Liquidware docs or support | **Unverified** |
| V9 | CommandCTRL agent overhead on multi-session at 60 s sampling; remote control scoped to one user's session | spike | **Unverified** |
| V10 | AI Insights tokenization in practice (what leaves the endpoint) | spike with AI off, then on with the project's provider | **Unverified** |
| V11 | CommandCTRL SaaS region, retention, audit log export | Liquidware | **Unverified** |
| V12 | Nerdio app attach UI and UAM handling of FlexApp packages today | Nerdio docs | **Unverified** |
| V13 | Console REST API coverage for reading configs and assignments | console Swagger (off by default in 6.9.5) | **Unverified** |

## 13. Phases

| Phase | What | Gate |
|---|---|---|
| **L0. Spike** | Paper checks first (V5, V6, V8, V11, V12, V13 from docs or support), then one cost-estimated run in the personal sandbox for V1–V4, V7, V9, V10 | Nick's go on the estimate |
| **L1. Landing zone tier** | `AVD_LIQUIDWARE` flag, `bicep/modules/liquidware.bicep`, `Configure-ProfileUnity` Run Command, packages account with tests (C1), Portability exclusion matrix and test (H1), preflight checks (version floor, double assignment), portal step, docs and a lesson per real-run finding | L0 passes for the paths used |
| **L2. Nerdio delivery** | Scripted action, parameters, customer runbook, hybrid notes (§8) | L1 |
| **L3. CommandCTRL** | Intune/Run Command agent install, settings baseline (§7), Stratusphere overlap rule, kill-switch step in avd-swarm | L0 V9–V11 |
| **L4. Brain and swarm** | §10 facts, detections and plans, in avd-second-brain and avd-swarm together | L1, and the facts contract in avd-current-state if it carries Liquidware facts |

## 14. Open questions for Nick

1. **Where it lives (S2).** Proposed: spec and optional module in this repo; the Nerdio scripted action in this repo too, under `scripts/nerdio/`. Alternative: a separate `avd-liquidware` repo. Recommended: this repo.
2. **P2 (ProfileDisk) at all?** Recommended: keep it gated and don't spend spike time on it unless a customer asks.
3. **CommandCTRL scope:** session hosts only, or the thin-client devices too? Recommended: both, since cross-platform agents are its main edge.
4. **AI Insights:** keep off, or test with the project's own Claude credentials in L0? Recommended: off for L0; a later decision.
5. **Spike timing:** run L0 now, or after the Graph sign-in app and S1a spike finish? Recommended: paper checks now, sandbox run after those.
