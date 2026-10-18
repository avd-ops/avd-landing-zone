# Red-team review: the Liquidware optional tier

- **Reviewed:** [liquidware-spec.md](liquidware-spec.md) draft of 2026-10-18 (decision 0016, Proposed). Two passes: the author's, then an independent reviewer that had only the spec and this repo's decisions.
- **Method:** follow a user's logon on a session host with the tier on (license check, INI read, FSLogix mount, Portability restore, FlexApp layering, CommandCTRL agent), then an admin's day (packaging, assignment, support session, upgrade), and ask at each step: which identity touches which storage, what fails if a component is down, who else manages the same thing, and what an attacker or a wrong agent could do with the new surface. Nothing here has run against a real tenant.
- **Status:** every finding is folded into the spec, which carries the finding IDs where the fix landed.

## Verdict

The tier fits as an **upgrade for customers who need portability, GPP replacement or legacy app layering**, not as a default. Three things would break this repo's posture if built as first sketched: machine-context storage access on Entra-joined hosts quietly needs storage keys (C1); the console is a new standing Windows server in a landing zone sold as having no management VM (C2); and CommandCTRL's remote control and shell are a write path into session hosts that bypasses the swarm's governance (C3). All three have fixes that keep the tier viable. The strategic question (S1) is whether greenfield Entra-only landing zones need the tier at all: mostly not, so its real home is customer environments with Nerdio.

| Severity | Count |
|---|---|
| Critical: a stated guarantee doesn't hold | 3 |
| High: wrong in a likely case | 6 |
| Medium: gaps and inconsistencies | 6 |
| Strategic | 2 |

## Critical

### C1. Machine-context access on Entra-joined hosts needs storage keys
**Where:** §5.1 storage, §6 rows 4–6.
**Scenario:** app attach mounts images with the session host's computer account, and ProfileUnity 6.9.5's LocalSystem startup option uses the machine account. On an Entra-joined host there is no machine Kerberos identity for Azure Files: Entra Kerberos issues tickets for users. Microsoft's app attach guidance for Entra-joined hosts therefore assigns Reader and Data Access to the AVD service principals and talks about access keys. A first sketch that put packages on the profiles account would have to enable shared-key access on the account that holds every user's profile, undoing the posture lesson 0028 just proved.
**Fix (folded, §5.1, §6, §7):** a separate packages account holds only app attach images; keys live in Key Vault and rotate; a template test fails if the profiles account enables shared-key access or if the packages account gets a profiles share. Machine-context ProfileUnity configuration is out until V8 shows a keyless path. V1 tests whether app attach works with Entra alone, so keys can be dropped.

### C2. A standing management server in a landing zone without one
**Where:** §5, README ("FSLogix without storage keys, domain joins or a management VM").
**Scenario:** the ProfileUnity console holds all user environment policy and a MongoDB database, listens on 8000 and 443, and in hybrid mode talks LDAP to domain controllers. Left with a public IP, a default MongoDB, or unpatched, it is the easiest way to push a malicious logon configuration to every host.
**Fix (folded, §5.1, §7):** private only, Bastion or JIT admin, Entra login, Update Manager, daily backup, 6.9.5 minimum (which refuses insecure MongoDB on upgrade), Swagger off unless §10 needs it and then only from `snet-mgmt`. The README line is updated by phase L1 to say the tier adds a console VM.

### C3. CommandCTRL remote control and shell bypass the swarm's governance
**Where:** §9, avd-swarm governance (plans, approvals, kill switch).
**Scenario:** a technician, or an agent given a CommandCTRL credential to "help", opens a shell on a session host and changes it. No plan, no approval, no event to the observers, and the kill switch doesn't stop it.
**Fix (folded, §7, §10.3):** remote control and shell off by default and per role; never for agents or automation identities; consent prompt stays on; audit log exported if possible (V11); the kill switch gains a step that disables CommandCTRL remote control and shell for the tenant.

## High

### H1. FSLogix and Portability manage the same files
**Where:** §4.1 P1.
**Scenario:** Portability restores `AppData\Local\…` at logon into a container FSLogix already roams; logoff writes both; one wins at random and logons grow. Liquidware's own known issues name Portability and Folder Redirection on all of `AppData\Local`.
**Fix (folded):** FSLogix owns the container; Portability captures only a named list; a template test rejects overlaps; detection `lw-portability-overlap`.

### H2. Sandbox Isolation on multi-session hosts
**Where:** §4.2.
**Scenario:** someone ticks Isolation for one app; Windows Sandbox needs nested virtualization, which not every portal VM size or security baseline allows; logons fail on some hosts only.
**Fix (folded):** isolation off in this tier; a separate decision checks sizes, Trusted Launch and the baseline first.

### H3. AI Insights sends host telemetry to an LLM
**Where:** §7, §9.
**Scenario:** a technician turns on AI Insights with a personal key; process names, paths and window titles from a multi-session host with many users go to a provider outside the customer's agreement.
**Fix (folded):** off by default; if on, only the project's own provider; tokenization checked in V10 first.

### H4. Packages lock in the vendor
**Where:** §4.2.
**Scenario:** a customer drops the Liquidware license; FlexApp packages stop working and every app has to be repackaged at once.
**Fix (folded, §4.2 ordering):** MSIX through native app attach (A2) is preferred whenever an app has an MSIX; FlexApp is for apps that don't convert. The package list records the fallback install method for each FlexApp app (phase L1).

### H5. Three systems can assign the same app
**Where:** §4.2, §8.
**Scenario:** Nerdio assigns FlexApp One, ProfileUnity assigns the FlexApp VHDX of the same app, and app attach assigns its MSIX. Users get two copies, or a version mismatch at logon.
**Fix (folded):** one assignment system per app; a preflight warning and detection `lw-double-assignment`; A3 preferred because it is one surface everything already reads.

### H6. Per-landing-zone settings leak into the generic image
**Where:** §5.2, image pipeline rule.
**Scenario:** the client is baked with `USERINI` and `LICSTR` of the dev landing zone; production hosts read dev configuration.
**Fix (folded):** only the binary may be in the image; settings come from the `Configure-ProfileUnity` Run Command.

## Medium

- **M1. Entra filters and Graph at logon.** Graph calls for Entra group filters hung logons before 6.9.5. Fix: version floor 6.9.5, detection `lw-version-floor`, and `lw-logon-regression` after any config change.
- **M2. MongoDB upgrades.** Consoles installed before 6.8.5 stay insecure after upgrade and 6.9.5 blocks them. Fix: fresh installs only at 6.9.5 or later; customer consoles follow Liquidware's migration guide before L2.
- **M3. ProfileDisks don't move from Windows 10 to 11.** Liquidware's known issue. Fix: P2 gated; migrations go through Portability (P1).
- **M4. 260-character paths.** Portability can't process them. Fix: the exclusion matrix excludes known deep paths; L1 adds an event-log query for skipped files.
- **M5. CommandCTRL data residency.** SaaS region and retention are unknown. Fix: V11 before install in any customer; a customer with residency rules decides.
- **M6. Auto shutdown and the console.** The repo's auto-shutdown runbook deallocates by schedule and budget. If hosts need the console to license or fetch configuration at logon, a stopped console breaks every logon. Fix: the console is excluded from auto shutdown until V7 shows logons survive without it.

## Strategic

### S1. Greenfield Entra-only landing zones gain least
Portability, GPP replacement and legacy layering matter most when a customer is leaving another VDI stack or AD. A greenfield Entra-only landing zone from this repo has no GPP and few legacy apps. **Fix (folded, §8, §13):** the tier is built so the same scripts run as Nerdio scripted actions in customer environments (L2), and the landing zone flag (L1) exists mainly so it can be tested end to end here.

### S2. Should this live in this repo?
A separate repo would keep this one small. But the tier reuses this repo's storage, Run Command, preflight and portal patterns, and its tests guard the profiles account. **Recommendation:** this repo, behind `AVD_LIQUIDWARE`, with the Nerdio script under `scripts/nerdio/`. Open question 1 for the owner.
