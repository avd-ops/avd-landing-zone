# Spec: run recorder and resume point

- **Status:** Proposed. Spec only: nothing here is built, and nothing has run against a real tenant.
- **Date:** 2026-10-20
- **Scope:** the ops scripts, `deploy.sh` and the deployment portal. The default landing zone deployment does not change: the recorder is opt-in and deploys nothing unless the operator turns on the Azure store (§6).

This is a personal project, not for production, provided as is. §12 lists every fact this spec relies on, how it was checked, and what is still unverified.

## 1. Summary

Real runs are the source of truth (decision 0006), but most of what a real run teaches is lost. The operator pastes the last output into the portal, the portal suggests the next command, and the session ends. Nobody keeps what was run, what the portal suggested against what the operator actually ran, how long each step took, which output the portal didn't recognize, or what the run cost. When Cloud Shell resets mid-run, the operator also loses their place.

This spec adds three things that share one record:

1. **A run journal.** Each script, when recording is on, appends structured events to a journal: the step, the parameters (names and non-secret values), the portal step that suggested it, every check result, the state line, the exit code and the duration. An optional transcript adds the raw console output. Secrets are removed before anything is written; tenant identifiers are removed again before anything is shared (§5).
2. **A resume point.** A new read-only script, `Get-AvdRunStatus.ps1`, answers "where did I leave off?" from Azure itself (deployment history and the landing zone's resource groups) plus the journal when there is one, and prints a state line. The portal reads it and shows the next step, on any device. This works with no recorder at all; the journal only makes it more exact (§4).
3. **A path from a run to fixes.** At the end of a run, `Stop-AvdRunRecorder.ps1` builds a run report: steps, durations, failures by `id`, unrecognized output, portal deviations, teardown evidence and cost. The operator reviews a redacted copy and files it as a GitHub issue, as the portal's **Report a problem** does today (decision 0008). Maintainers turn each finding into a fixture, a scenario, a test or a lesson; recurring outcomes become a public **verified runs** table and field reports in the family KB (§8).

Everything above is free and open source. §10 lists what could later be a hosted, paid feature.

## 2. Goals and non-goals

### Goals
1. After a real run, the maintainer has a redacted, structured record of what happened, without the operator copying anything by hand.
2. An operator whose Cloud Shell reset, or who switched from a laptop to an iPad, gets back to the right step with one self-contained command.
3. Every portal miss (output it didn't recognize, or advice the operator didn't follow) is counted and can become a fixture.
4. Other operators can see which paths were verified recently, in which region, with which outcome.
5. A sandbox run with the recorder costs cents, and its own resources are removed with evidence.

### Non-goals
- **A tamper-proof audit trail.** The Azure Activity Log is already that for the control plane (§12, F1). The journal is a debugging and learning aid. Compliance-grade retention is a possible paid feature (§10), not a default.
- **Recording keystrokes or forcing transcripts.** Cloud Shell has no command logging of its own (§12, F6). The recorder is opt-in and records only the landing zone's scripts.
- **Sending anything anywhere automatically.** No telemetry. A report leaves the operator's tenant only when they file it.
- **Replacing the spend process.** The recorder reports cost and teardown evidence for the run; budgets and reconciliation stay where they are.

## 3. Principles

| # | Principle | Source |
|---|---|---|
| R1 | Opt-in, and the default deployment is unchanged | decision 0001 scope; verify-access spec V5 |
| R2 | Secrets never reach the journal; tenant identifiers never leave the tenant unredacted | CLAUDE.md "never make operators remember secrets"; decision 0008 |
| R3 | One redaction implementation: the portal's `report.js`, run in Node in Cloud Shell, never a second copy in PowerShell | decision 0008; drift risk |
| R4 | Azure is the source of truth for where a run is; the journal adds detail, never overrides it | lesson 0015 (disconnects); decision 0007 |
| R5 | Every new state the portal recognizes gets an `id`, a branch in `portal-core.js`, a Node test and an offline scenario | decision 0007, CLAUDE.md |
| R6 | Every resource the recorder creates is removed by the recorder, with evidence, before the run is called done | spend rule; lesson 0029 (delete inputs last) |
| R7 | Cost lines match exactly one retail price meter, or say which meters were seen | decision 0010 |
| R8 | Fail closed: if redaction can't run, nothing is uploaded or shared | verify-access spec V1 |
| R9 | Never delete the last copy. Nothing in this spec deletes run data, logs or evidence unless a second copy exists and has been checked against the manifest's hashes. Old data moves to a cheaper tier instead of being deleted. The one exception is a person who opted in to deleting a run's logs at teardown and confirms deleting files with no second copy (§9.2) | the owner, 2026-10-20; lesson 0029 |

## 4. The resume point (works without the recorder)

### 4.1 What a reset loses, and what survives

| Lost on a Cloud Shell reset | Survives |
|---|---|
| The shell, its variables, the Graph sign-in, files outside `clouddrive` (and everything in an ephemeral session) | The ARM deployment, which keeps running after a disconnect; the subscription's deployment history; the resource groups; the portal's own browser storage on the same device |

The portal already keeps the operator's step and settings in the browser (`avdlz.portal.*` keys). That covers a reset on the same device, but not a second device, a cleared browser, or the case where the operator doesn't know whether the deployment finished.

### 4.2 `Get-AvdRunStatus.ps1`

A new read-only entry point in `scripts/ops/` (with the notice at the top). It reads, in this order, through `Invoke-AvdArm`:

1. **Deployment history** at subscription scope, filtered to this landing zone's deployment names (the name `deploy.sh` prints in its `started` state line): the newest deployment's provisioning state (`Running`, `Succeeded`, `Failed`, `Canceled`), start time, duration, and for `Failed`, the error code and the failed operations.
2. **Resource groups** named by the landing zone's convention, and whether each exists.
3. **The demo and image resources** the other steps create, by the same names the cleanup script uses.
4. **The journal**, if recording was on and the store is reachable (§6): the last step recorded and its outcome.
5. **The power lock tag** (`avdlz-power-lock`, LZ-3), because a redeploy refuses while it is set.

It then infers the last completed stage with a pure function, `Get-AvdRunPosition` in `AvdLandingZone.psm1` (offline-tested with fixtures that omit empty properties, lesson 0021), and prints the usual state line:

```text
<<<AVDLZ-STATE {"v":1,"stage":"resume","status":"ready","context":{"lastStage":"deploy","lastStatus":"running","deploymentName":"...","nextStage":"postdeploy","runId":"..."}, ...} AVDLZ-STATE>>>
```

Rules for the inference, each a Pester case:
- A deployment `Running` wins over everything: next step is "wait and check again", with the same command, never a second deploy.
- The journal can only add detail to a stage Azure confirms. If the journal says `postdeploy` passed but the resource groups are gone, Azure wins and the result says why.
- No landing zone found and no journal: `nextStage: predeploy`.
- Anything it cannot classify is `status: unknown`, with what it saw, never a guess.

### 4.3 In the portal

- A **"Where did I leave off?"** action on every step shows one self-contained Cloud Shell block (clone or update, `Set-Location`, run `Get-AvdRunStatus.ps1`), per lesson 0015.
- Pasting its output moves the portal to `nextStage`, with a line saying what it based that on ("Azure shows the deployment still running, started 12 minutes ago").
- Every command block the portal prints already ends with the state line; a short hint under each block says "If Cloud Shell resets, run *Where did I leave off?*".
- Stage `resume` is added to `Get-AvdPortalState`'s `ValidateSet`, `portal-core.js`, `STAGE_LABEL`, the schema in `site/portal/README.md`, and their tests (R5).

UI work follows the frontend design pass with the avd-ops design system, and is tested in a real browser with Playwright (webapp-testing), not only with Node tests.

## 5. Redaction: two levels, one implementation

| Level | Removes | Where it applies |
|---|---|---|
| **Private** | Secrets only: tokens, keys, passwords, SAS signatures, device codes, connection strings | Everything written to the journal or a transcript, in the operator's own tenant |
| **Public** | Everything `report.js` removes today (decision 0008): emails and UPNs, the operator's domains, tenant and subscription names, IDs other than `PUBLIC_IDS`, globally unique resource names, public IPs, home-folder user names, the name prefix and group names, operator-added terms | Anything that leaves the tenant: the run report issue, a fixture, a lesson, a KB entry |

- Both levels run through `site/portal/report.js` in Node, which Cloud Shell has (§12, F7). A small wrapper, `scripts/ops/redact.mjs`, exposes `--level private|public` and reads the known values (prefix, groups) from the script's context. `report.js` gains a `level` option; the private level is its secret patterns only.
- **Structured first.** Journal events are written from known fields, not scraped output, so most of a journal never contains a secret to begin with. Parameters marked `[SecureString]`, or named like a secret, are logged as `<set>` / `<unset>`.
- **Fail closed (R8).** If `node` or `redact.mjs` is missing or exits non-zero, the transcript stays on local disk only, the journal records `redaction: unavailable`, and nothing is uploaded.
- **Tests:** every portal fixture also runs through `redact.mjs`, and the existing check that redaction doesn't change the portal's analysis covers the new `level` option. A new `fixtures/pii-sample.txt` line for each new kind of value the journal can carry (for example a device code), per CLAUDE.md.

## 6. The run journal

### 6.1 Turning it on

```powershell
# Portal "Record this run" toggle adds these two lines to every command block it prints.
$env:AVDLZ_RECORD = 'on'          # or 'azure' to also keep it in the tenant (6.3)
$env:AVDLZ_RUN_ID = 'run-20261020-1652-k3p9'   # generated once by the portal for the whole run
```

`deploy.sh` reads the same two variables (not built yet). With neither set, the scripts behave exactly as today. The portal can add `$env:AVDLZ_PORTAL_STEP = '<step>'` so `step.start` records which step printed the command.

**Built in phase 1 (PowerShell):** `Write-AvdJournalEvent` in `AvdLandingZone.psm1`. Every script that calls `Initialize-AvdAzContext` writes `step.start` with its own parameters, `Add-AvdCheckResult` writes `check`, `Invoke-AvdArm` writes `api.error` before it throws, and `Write-AvdPortalState` writes `step.end`. Run `Add-AvdRunNote "..."` after importing the module to add a note. A bad mode or run ID turns the journal off with one warning, and a journal that can't be written warns once: neither ever stops the run. `azure` mode writes the local journal for now; the upload comes with the run store (phase 3).

### 6.2 Events

One JSON object per line (JSONL), schema [`contracts/schemas/run-journal.schema.json`](../../contracts/schemas/run-journal.schema.json) (avd-second-brain contract C17, vendored; see §6.5), version `v: 1`:

| Event | Fields |
|---|---|
| `step.start` | `runId`, `step` (script and stage), `portalStep` (the step that printed the command, if any), `params` (names, non-secret values, `<set>` for secrets and for any name containing password, secret, token, credential, sas or key), `repoCommit`, `shell` (`pwsh`/`bash`), `cloudShell` (bool), `ts` |
| `check` | the check's `id`, `status`, `area`, and `data`: the same objects the state line carries |
| `api.error` | step, HTTP status, error code, body excerpt and correlation ID (lesson 0012). Private level only. |
| `step.end` | duration and the full state line (the state's status stands in for the exit code) |
| `operator.note` | free text from `Add-AvdRunNote "..."`, for "I did X by hand in the portal" |

`portalStep` against the actual `params` gives the **deviation** signal: when operators keep changing the command the portal gave them, the portal is wrong.

### 6.3 Where it is kept

| Store | When | Survives a reset | Cost |
|---|---|---|---|
| **Local** `~/clouddrive/avdlz-runs/<runId>/` | `AVDLZ_RECORD=on` and `clouddrive` is mounted | Yes | the operator's existing Cloud Shell share |
| **Local** `~/avdlz-runs/<runId>/` | `on`, ephemeral session | No: the resume point still works from Azure (§4) | none |
| **Azure** `runs/<runId>/` in a recorder storage account | `AVDLZ_RECORD=azure` | Yes, and readable from any device | cents (§9) |

The Azure store is **durable log storage for the sandbox**, set up once per subscription by `Initialize-AvdRunStore.ps1` (Bicep `bicep/recorder/main.bicep`, its own template, not part of `main.bicep`) and reused by every run. `Start-AvdRunRecorder.ps1` only opens a run folder in it:
- Its own resource group, `avdlz-runs-rg`, independent of any landing zone's name prefix. It outlives every landing zone's cleanup, holds the teardown evidence and the history of every recorded run, and is removed only on request (§9.2).
- One StorageV2 account, LRS, hot tier; shared key access off, minimum TLS 1.2, no public blob access; the operator gets Storage Blob Data Contributor on the account only. Entra auth from Cloud Shell, no keys or SAS anywhere (R2).
- Append blobs for the journal; block blobs for redacted transcripts and the report.
- A lifecycle rule moves run folders to the cool tier after 30 days and the cold tier after 90 days. It **never deletes** (R9).
- Blob soft delete and container soft delete (14 days) cover a mistaken delete. Versioning stays off because the journal is append-only.
- **No locked immutability.** A locked time-based retention policy makes the container and account undeletable until it expires (§12, F4), which breaks R6. Integrity comes from a SHA-256 manifest written at the end of the run and included in the report. Locked WORM retention is a §10 option, never a sandbox default.
- Tagged `avdlz-run: <runId>` and `avdlz-component: recorder`.

### 6.4 Transcripts (optional)

`AVDLZ_TRANSCRIPT=on` adds the raw console output:
- PowerShell: the scripts call `Start-Transcript` / `Stop-Transcript` around themselves into a temp file, then redact it at the private level before it is kept.
- `deploy.sh`: re-executes itself under `script -q` the same way.
- Native command output inside `pwsh` (for example `az` called from PowerShell) may not be fully captured by `Start-Transcript`; phase 1 checks this offline and in the first real run (§12, U3). The journal never depends on the transcript.

### 6.5 One schema for every kind of run (contract C17)

*Added 2026-10-20 at the owner's request, before rollout.* The run folder's files follow avd-second-brain's contract C17, `avd-run-record/v1`, so the same record works for the landing zone today and for other use cases later (image builds, the Liquidware tier, the Stratusphere instrument, avd-swarm plans) without a new format each time. The brain's `contracts/schemas/` is the authority; this repo keeps byte-identical copies in `contracts/`, pinned in `contracts/PINS.json`.

- `run.json`: the run ID, its use case (`landing-zone` here), the producing repo and commit, steps, region, status, the manifest of every file with its hashes and verified copies (§9.2), and how teardown ended.
- `journal.jsonl`: the events in §6.2.
- `cost.json`: expected and actual cost (§9.3a), as `avd-run-cost/v1`.
- **Room to grow:** a new use case is a line in `contracts/run-use-cases.json`; it adds fields only under `extensions.<useCase>` and journal events only named `x.<useCase>.<name>`. Within v1 every change is additive and readers ignore what they don't know; a breaking change is v2, and readers accept both for a release.
- A Pester test checks that what `Write-AvdJournalEvent` writes passes the vendored schema.

## 7. Azure-side evidence (read, not exported)

The recorder reads what Azure already keeps instead of exporting it by default:

| Source | How | Default | Why |
|---|---|---|---|
| **Activity Log**, for the run's window, the operator as caller, the landing zone's resource groups | ARM REST, at `Stop-AvdRunRecorder` time | On | Retained 90 days at no charge (§12, F1). Shows every control-plane write the run made, including ones a script didn't report |
| **Deployment operations** of each deployment in the run | ARM REST | On | The exact failed operation and its status message |
| **Entra audit log** entries for the groups and app registrations the scripts touch | Graph, with the operator's existing sign-in | On if the Graph sign-in is already there | App and group changes; access to audit logs through Graph may need a premium license (§12, U4), so a refusal is reported, not fatal |
| **Diagnostic setting** exporting the subscription's Activity Log to the run store | created by `Initialize-AvdRunStore.ps1` | On for the sandbox store; `-NoActivityLogExport` turns it off | Durable control-plane history past Azure's 90 days, including changes made outside the scripts (portal clicks); costs only the blobs it writes. Removed with the store |
| **Entra and Graph activity log export** | not built | Off | Tenant-wide, needs Security Administrator; Graph activity logs need Entra ID P1 or P2 (§12, F3). Out of the landing zone's footprint |

Everything read is redacted at the private level before it is stored and at the public level before it is shared.

## 8. From a run to fixes and shared knowledge

### 8.1 The run report

`Stop-AvdRunRecorder.ps1 -RunId <id>` (also offered by the portal at the end of a run, and after cleanup) produces `report.md` and `report.json`:

1. **Run summary:** steps in order, durations, outcomes, repo commit, region, sizing.
2. **Portal misses:** every pasted output the portal classified as `source: 'text'` or `'none'` (from the portal side, §8.3), every state `id` the portal has no branch for, and every deviation (§6.2).
3. **Failures:** each with its `id`, the API error (§6.2) and the matching Activity Log and deployment operation entries.
4. **Cost:** the run's estimate against its actual cost, from the run's `cost.json` (§9.3a). Until Cost Management has the actual, which can take a day or more (§12, U5), the report says *pending*, never a guess (R7).
5. **Teardown evidence:** a Resource Graph query, after cleanup, for anything tagged `avdlz-run: <runId>` or named by the landing zone's convention, with its result; the soft-deleted Key Vault and Log Analytics workspace states (lessons 0022, 0023); written to the recorder store, which stays (§9.2).
6. **The landing zone's own logs, before cleanup deletes them:** the Log Analytics workspace goes with the landing zone, and it holds the only copy of the run's AVD diagnostics (`WVDConnections`, `WVDErrors`, `WVDCheckpoints`, `WVDAgentHealthStatus`) and its host logs. `Stop-AvdRunRecorder.ps1 -BeforeCleanup` exports those tables for the run's window as JSON into the run folder, checks row counts, and adds them to the manifest. The portal's cleanup step runs it first when recording is on. Cleanup itself is unchanged (R1). Only the order of the portal's steps changes.
6. **Manifest:** SHA-256 of every journal and transcript file.

### 8.2 Filing it

- `Stop-AvdRunRecorder.ps1 -Share` runs the public redaction, writes `report.public.md`, and prints a GitHub `issues/new` link with the report filled in (cut in the middle to fit, as decision 0008 does). The operator reviews it, ticks that it holds nothing private, and submits it with their own account.
- The issue is marked `<!-- avdlz-run-report v1 -->`; the existing `portal-report.yml` workflow is extended to label it `run-report`.

### 8.3 What the portal adds

When recording is on, the portal also keeps a small local log of its own: each pasted output's classification (`state`/`text`/`none`), the step it showed and the command it printed, by hash. It never leaves the browser except as part of a report the operator files, after the same public redaction. The **Report a problem** flow offers to attach it.

### 8.4 Triage: the retro routine, fed by reports

The retro skill (`.claude/skills/retro/SKILL.md`) gains a "from a run report" entry:

| Report finding | Becomes |
|---|---|
| Output the portal didn't recognize | A fixture in `build/tests/portal/` (redacted reports can become fixtures as-is, decision 0008) and a branch in `portal-core.js` |
| A deviation seen in two or more runs | A portal command change, or a parameter default change, with a drift test |
| A failure with a new API error | An `AzMock.psm1` path, an offline scenario, a lesson (decision 0006) |
| A step much slower than its estimate | A "prints a line before it starts" check (lesson 0006) or a timeout in the docs |
| Cost differing from the estimate | A meter fix in `Get-AvdCostEstimate`, or an excluded-charge line (decision 0010) |
| Nothing new | A row in the verified runs table (§8.5) |

### 8.5 Feedback for other operators

- **Verified runs table** (`docs/verified-runs.md`, generated from accepted run reports): date, repo commit or release, region, host size, path (deploy, demo, verify access, cleanup), outcome, and a link to the issue. An operator can see that "the demo in a region without zones last passed on this commit".
- **Family KB:** each lesson links into avd-second-brain's topic pages as today. A run report that confirms or contradicts a KB page becomes a field report through the existing `kb-feedback` issue form (`worked`, `broke`, `outdated`, `missing`), so the KB records what held up in real runs. The run journal is not a cross-repo contract: no other repo reads it. If the brain or avd-swarm ever reads journals, that becomes a contract in avd-second-brain's `contracts/schemas/` first, and the two repos change together.
- **Nothing tenant-specific** goes into the table, a lesson, a fixture or a KB entry: public redaction plus a maintainer's review, as decision 0008 requires.

## 9. Cost and teardown

### 9.1 Estimate (before any run)

The sandbox run is the landing zone's normal cost plus the recorder's. The recorder's part, with `AVDLZ_RECORD=azure`:

| Item | Assumption | Estimate |
|---|---|---|
| Blob storage, LRS, hot then cool and cold | under 50 MB per run, kept indefinitely | under $0.01 per run per month, falling as it tiers down |
| Write and list operations | about 2,000 per run (append blocks, transcripts, listing) | under $0.02 |
| Activity Log, deployment operations, Resource Graph reads | ARM and Resource Graph reads | $0 |
| Activity Log export to the store | a sandbox's control-plane writes, a few MB a month | storage only, cents a month |
| **Defender for Storage**, if the subscription has the plan on | billed per storage account per month, prorated | **must be checked first**: it could exceed everything else; the preflight reports the plan's state and the recorder refuses `azure` mode without `-AcceptDefenderCharge` while it is on |
| **Recorder total per run** | | **under $0.05**, excluding Defender |

Prices above are from Microsoft's sample price tables (§12, F5). The real estimate comes from the retail prices API through `Get-AvdCostEstimate`, with a line per recorder meter (R7), printed before the recorder deploys. `AVDLZ_RECORD=on` (local) costs nothing.

### 9.2 Teardown rule

**One place for every log.** Everything a run produces goes into that run's folder in the run store, `runs/<runId>/`, which is also where the teardown proof is written. That covers the journal, transcripts, the Activity Log and deployment operations, the landing zone's exported Log Analytics tables (§8.1, item 6), the report, the manifest, any large files, and the teardown evidence (§8.1, item 5). There is no second container and no log kept anywhere else. The run store (`avdlz-runs-rg`) isn't part of any landing zone, so a landing zone's cleanup can't touch it unless the operator opts in.

1. **Before cleanup:** `Stop-AvdRunRecorder.ps1 -BeforeCleanup` exports the landing zone's logs into the run folder (§8.1, item 6). The portal's cleanup step runs it first when recording is on.
2. **Cleanup:** the landing zone is torn down as today. The recorder keeps recording through it and writes the teardown evidence into the run folder.
3. **The run's logs at teardown: opt in or out.** One preference decides whether a run's folder is deleted along with the landing zone teardown:
   - `Keep` (the default, opt out): the run folder stays, and teardown only prints its size and monthly cost.
   - `Ask`: teardown lists the folder's contents and asks each time.
   - `Delete` (opt in): the run folder goes with the teardown, but only after a verified copy exists (step 4). Anything with no copy (files over the free GitHub limits) is listed, and deleting it needs the operator to type the run ID. That is the one place a person can choose to delete a last copy (R9).

   The preference is set once with `-TeardownLogs Keep|Ask|Delete` on `Initialize-AvdRunStore.ps1` (stored as a tag on the store), and a single teardown can override it with the same parameter on `Remove-AvdDemo.ps1 -IncludeLandingZone`.
4. **Copies before anything is deleted.** `Stop-AvdRunRecorder.ps1 -CopyTo <destination>` copies a run folder, re-reads the copy, and checks every file against the manifest. It can run after every run, without deleting anything, so each run has a second copy off Azure from day one. Supported destinations: another storage account; the operator's own machine (`-CopyTo local`, an archive and its hashes to download, because Cloud Shell's disk doesn't count); or a private GitHub repository:
   - `-CopyTo github` (or `github:<owner>/<repo>` to name another) copies to the operator's private companion repo (§9.3): it commits the run folder to an orphan `runs` branch (one commit per run, like a ledger branch), then reads the files back through the API and compares hashes. Sign-in is the GitHub CLI's device flow in Cloud Shell (`gh auth login`), so no token is stored or typed. The script refuses a public repository: these records are private-level, with secrets removed but tenant names and IDs still in them. Public repositories and issues only ever get the public-level report (section 8.2).
   - **The free tier stops at what GitHub gives for free** (limits checked 2026-10-20, §12 F8). Every file is gzip-compressed first, and the manifest records both hashes. Under 50 MiB compressed, it's committed to the `runs` branch: GitHub warns above 50 MiB and blocks files over 100 MiB. From 50 MiB to 2 GiB, it's uploaded as an asset of a release named after the run (`run-<runId>`). Each asset must be under 2 GiB, a release has no total size or bandwidth limit, and the script downloads the asset again and checks its hash. Files of 2 GiB or more aren't copied or split. They stay in the run folder, their hash is in the manifest, and the commit lists them as *kept in Azure only*. Splitting large files, and verified copies to a second subscription, aren't part of the free tier (§10).
   - **Your own archive:** `-CopyTo hook` sends the manifest to your own archive. It runs the executable named in `AVD_COPY_HOOK` with the path to a `request.json` (class, files, sizes, SHA-256, origin) and reads back a `receipt.json` (each file's SHA-256 as read back from the destination, the destination URI, `verifiedBy`). It deletes nothing unless every hash matches. Without `AVD_COPY_HOOK` it refuses and lists the free targets above. When a receipt covers a file with no other copy, teardown shows "verified copy at <verifiedBy>", and the `-TeardownLogs` preference stays the operator's. The request and receipt schemas go into avd-second-brain's `contracts/schemas/` when this is built, because they cross a repo boundary.
   - Git LFS isn't used: its free allowance is 10 GiB of storage and bandwidth a month, and it adds nothing release assets lack.
   - A normal sandbox run should come to well under 50 MiB in total. The larger tiers are for long transcripts and log exports from a landing zone that ran for weeks.
5. **Removing the whole run store** is a separate request: `Stop-AvdRunRecorder.ps1 -Remove`. It applies step 3's rules to every run folder (copies verified first, typed confirmation for anything with no copy). Only then does it remove the Activity Log diagnostic setting, delete `avdlz-runs-rg`, and confirm it's gone as its last line. Any mismatch and nothing is deleted. Inputs are deleted last (lesson 0029).
6. Idle cost is a few MB of blobs, cents a month, plus Defender for Storage if the plan is on (§9.1). The monthly spend reconciliation lists the run store as a standing item, so it's never a leftover.

### 9.3 The private companion repo

*Decided 2026-10-20 by the owner.* Run records go to a **separate private GitHub repository that each operator creates and owns**, not to any of the project's repositories and not to a paid product. The project's own sandbox uses one too, set up the same way as anyone else's.

- **Named by a variable, not a product.** `AVD_PRIVATE_REPO=<owner>/<repo>` names it; the scripts never assume a name. Without it, `-CopyTo github` refuses and says how to set it. The scripts check that the repository is private before every write and refuse a public one.
- **One repo for everything private in the family.** Besides run records, it is the place for anything from the open-source tools that must stay private for the person using them, such as avd-second-brain material that holds their own estate's names (its estate vault and private notes). The open-source repos stay free of that data; the companion repo is where it goes.
- **Layout:**

  | Where | What | Written by |
  |---|---|---|
  | branch `runs` (orphan) | `runs/<runId>/`: one commit per run, the private-level run folder and its manifest | `Stop-AvdRunRecorder.ps1 -CopyTo github` |
  | branch `runs`, `runs/costs.csv` | one row per run: expected against latest actual cost (§9.3a) | the same, and `-UpdateCost` |
  | releases `run-<runId>` | files from 50 MiB to 2 GiB of that run | the same |
  | default branch, `brain/` | private second-brain material, laid out by avd-second-brain | avd-second-brain's tools (not built here) |
  | default branch, `README.md` | what the repo is, and that it must stay private | created once by the operator |

- **Free.** A private repository on a free GitHub account is enough; nothing here needs a paid plan or a hosted service. Large-file splitting and second-subscription copies stay outside the free tier (§10).
- **Set up once:** create the private repository in GitHub, then in Cloud Shell sign in with `gh auth login` (device code) and set `AVD_PRIVATE_REPO`. `Initialize-AvdRunStore.ps1` checks it can see the repo and that it is private, and records the name as a tag on the run store so a new Cloud Shell session finds it again.


### 9.3a Expected and actual cost, kept with the run

*Added 2026-10-20 at the owner's request.* Every recorded run keeps its own cost record, `runs/<runId>/cost.json`, next to its logs and teardown proof, and it travels with them to the companion repo (§9.3).

- **Expected,** written before anything is deployed: each line of the printed estimate (`Get-AvdCostEstimate` and the recorder's own meters, §9.1) with the retail meter it matched, unit price, currency, quantity and hours, when the prices were read, the cap, and the go/no-go rule's result (§13a). A line that matched no meter, or several, is kept as such (R7), never filled in with a guess.
- **Actual,** read from Cost Management's query API for the run's resource groups and the run store over the run's window, by day and by meter. `Stop-AvdRunRecorder.ps1` writes the first reading at the end of the run, marked `settled: false`. `Stop-AvdRunRecorder.ps1 -UpdateCost <runId>` reads it again later, and after 72 hours with no change marks it `settled: true`. Each reading is appended with the time it was taken, so the record shows how the figure moved and nothing is overwritten.
- **Compared:** total and per-line difference, any meter that appeared in the actuals but not in the estimate (the most useful finding: a cost the estimate doesn't know about), and anything still billing after teardown.
- **In the companion repo:** each update is a new commit on the `runs` branch, and `runs/costs.csv` keeps one row per run (run ID, date, region, sizing, cap, expected, latest actual, settled), so the history of expected against actual can be read at a glance and reconciled against the card statement.
- **Shared:** the public report carries only the totals, the per-meter differences and the region and sizes (no subscription or resource names), so a gap between estimate and actual becomes a fix to `Get-AvdCostEstimate` that every operator gets.
- **Permissions:** reading actuals needs Cost Management Reader (or Reader) on the subscription; without it the record says *actual unavailable: no access* rather than failing the run.

## 10. Free and open source vs a possible paid, hosted feature

| Free, in this repo (MIT) | Possible paid, hosted later (not designed here) |
|---|---|
| The journal, transcripts and redaction | Run history across many runs, landing zones and tenants, with search and trends |
| `Get-AvdRunStatus.ps1` and the portal's resume action | Cross-device resume without pasting (a hosted service that reads the operator's store with their consent) |
| The local and the in-tenant Azure store | Compliance retention: locked WORM, evidence packs for a change board, signed manifests |
| Copies within free GitHub features: commits under 50 MiB, release assets under 2 GiB | Large files beyond those limits: splitting into verified parts, and verified copies to a second subscription |
| Run reports filed as GitHub issues | Opt-in, anonymized failure analytics across adopters ("this error hits 30% of first deployments in this region") |
| The verified runs table and KB field reports | Automated triage that drafts the fixture, scenario and lesson PR from a report for a person to approve |
| | Team views: who ran what, when, with approvals |

The free tier stays complete for one operator: nothing in it depends on a hosted service. Anything hosted would read only what an operator chose to send, after public redaction.

## 11. Failure modes

| Failure | Behavior |
|---|---|
| Cloud Shell resets during `deploy.sh` | The ARM deployment continues; `Get-AvdRunStatus.ps1` reports `running` and the next command |
| `node` missing, or redaction fails | Nothing uploaded; local transcript kept, journal says `redaction: unavailable` (R8) |
| Recorder account unreachable (network, RBAC) | Journal falls back to local, the script prints one warning and continues: recording never fails a deployment step |
| Cleanup removed the landing zone; the recorder remains | Expected: `Get-AvdRunStatus.ps1` reports it as the standing store, not a leftover |
| A report contains a value the patterns missed | Same as decision 0008: the reporter's review, the maintainer's check before committing a fixture, a new pattern and `pii-sample.txt` line |
| Two runs share a run ID | The portal generates IDs with a random suffix; `Start-AvdRunRecorder` refuses an existing `runs/<runId>/` |

## 12. Facts verified, and what is not

Checked against Microsoft Learn on 2026-10-20.

| # | Fact | Source |
|---|---|---|
| F1 | The Activity Log records control-plane writes, keeps them 90 days with no charge, and has no ingestion charge in Log Analytics | Microsoft Learn, *Activity log in Azure Monitor* |
| F2 | Entra audit and sign-in logs are available on Entra ID Free; Graph activity logs need P1 or P2; Security Administrator is the least-privileged role for Entra diagnostic settings | Microsoft Learn, *Microsoft Entra licensing* and *How to access activity logs* |
| F3 | Graph activity logs need Entra ID P1 or P2 and a diagnostic setting to a workspace, storage account or event hub | Microsoft Learn, *Access Microsoft Graph activity logs* |
| F4 | A locked time-based retention policy can't be removed or shortened; the account can't be deleted while a container holds a blob under a locked policy; unlocked policies don't protect from deletion | Microsoft Learn, *Container-level WORM policies*, *Version-level WORM policies* |
| F5 | Blob prices used in §9.1 are Microsoft's sample prices, not a quote | Microsoft Learn, *Estimate the cost of using Azure Blob Storage* |
| F6 | Cloud Shell sessions end after 20 minutes without interaction; files persist only in `clouddrive` and the `$HOME` image when a storage account is mounted; ephemeral sessions keep nothing | Microsoft Learn, *Cloud Shell FAQ*, *Persist files in Azure Cloud Shell* |
| F7 | Cloud Shell includes Node.js and PowerShell 7.4 | Microsoft Learn, *Features and tools for Azure Cloud Shell* |
| F8 | GitHub warns on files over 50 MiB and blocks files over 100 MiB; a release asset must be under 2 GiB, with up to 1,000 assets and no total size or bandwidth limit per release; one push is limited to 2 GiB; Git LFS on Free includes 10 GiB of storage and 10 GiB of bandwidth a month | GitHub Docs, *About large files on GitHub*, *About releases*, *Troubleshooting the 2 GiB push limit*, *Product usage included with each plan* |

Unverified, to confirm in phase 1 (offline) or the first real run:

| # | Open fact | How it gets checked |
|---|---|---|
| U1 | The exact filter for "this landing zone's deployments" in subscription deployment history | Read `deploy.sh`'s deployment name; offline scenario; first real run |
| U2 | That a subscription-scope deployment keeps running after the Cloud Shell session ends (believed true; ARM runs it server-side) | First real run: close the tab during `deploy.sh`, then run `Get-AvdRunStatus.ps1` |
| U3 | How much native command output `Start-Transcript` captures in Cloud Shell's PowerShell 7.4 | Offline in a container, then the first real run |
| U4 | Whether reading `auditLogs/directoryAudits` through Graph works on an Entra ID Free tenant | First real run; a refusal is reported, not fatal |
| U5 | How long Cost Management takes to show a same-day run's cost in the maintainer's subscription | First real run; the report says *pending* until then |
| U6 | Whether Defender for Storage is on in the sandbox subscription | Preflight reads the plan before the recorder deploys |

## 13. Phases

| Phase | What | Cost |
|---|---|---|
| **P1, offline** | `Get-AvdRunPosition` and `Get-AvdRunStatus.ps1` with fixtures and an offline scenario; stage `resume` in the state line and `portal-core.js` with Node tests; `redact.mjs` and the `level` option with fixture tests; journal writer and schema; local store only | $0 |
| **P2, portal** | "Where did I leave off?" and "Record this run" in the portal, after a frontend design pass with the avd-ops design system; Playwright tests in a real browser; the portal's local classification log | $0 |
| **P3, Azure store** | `bicep/recorder/main.bicep`, `Start-`/`Stop-AvdRunRecorder.ps1`, the recorder's cost lines and `cost.json` (§9.3a), teardown, AzMock paths and a scenario | $0 offline |
| **P4, first real run** | One sandbox run in the maintainer's personal subscription, smallest sizes, northcentralus: deploy, close the tab mid-deploy, resume, post-deployment, cleanup, recorder removal. Confirms U1 to U6 | Only after a written estimate and the owner's yes; teardown evidence and actual cost recorded |
| **P5, feedback** | Run report issue and label, retro skill entry, `docs/verified-runs.md`, field report path in the family KB | $0 |

## 13a. Sandbox test plan (phase 4)

Everything in this spec is built offline first, then tested and audited in one real run in the maintainer's personal sandbox subscription (northcentralus, smallest sizes). **No real run and no spend until the owner says go on the written estimate below.** The family-wide plan for the same conventions (one run folder, `-TeardownLogs`, never deleting the last copy) is written separately and refers back to this section.

### What the run must prove

| # | Requirement | How the run proves it | Evidence kept in the run folder |
|---|---|---|---|
| T1 | Resume after a Cloud Shell reset (§4) | Close the Cloud Shell tab during `deploy.sh`, open a new session, run `Get-AvdRunStatus.ps1`: it reports `running` and the deployment name. Run it again after the deployment: `postdeploy`. Then do it from a second device | Both state lines; the portal's analysis of each (screenshots) |
| T2 | ARM keeps running after the shell ends (U2) | Same as T1: the deployment record shows `Succeeded` without the shell | Deployment record and duration |
| T3 | The journal and redaction (§5, §6) | Record the whole run with `AVDLZ_RECORD=azure`; check no secret appears (grep for the device code, SAS and token patterns); check the public report has no tenant name, IDs or domains | Journal, transcripts, the redaction check output |
| T4 | Transcript coverage (U3) | Compare the transcript with the console for one `az` call inside PowerShell | The diff |
| T5 | Activity Log and Entra reads (§7, U4) | `Stop-AvdRunRecorder` reads the run's Activity Log and the Entra audit entries; a Free-tier refusal is reported, not fatal | The exported entries or the refusal |
| T6 | Logs exported before cleanup (§8.1 item 6) | Export the AVD tables, check row counts, then run cleanup | Exported tables and counts |
| T7 | Teardown proof (§8.1 item 5) | After cleanup, the Resource Graph query finds nothing tagged with the run or named by the landing zone | Query and result |
| T8 | One run folder, `-TeardownLogs` (§9.2) | Run teardown once with `Keep` (folder stays), once with `Ask` (lists and asks), and once with `Delete` on a throwaway test folder (refuses without a verified copy, then deletes after one) | Each prompt and outcome |
| T9 | Verified copies (§9.2 step 4, §9.3) | `-CopyTo github` to the companion repo named by `AVD_PRIVATE_REPO`: commit, read back, hashes match; a planted mismatch blocks deletion; a public repo is refused | Receipts and the refusal |
| T10 | Cost (§9.1, §9.3a, U5, U6) | Defender for Storage plan read first; `cost.json` written before deploy with every estimate line; first actual at the end of the run, `-UpdateCost` until settled; `costs.csv` row in the companion repo | `cost.json` with expected, each actual reading and the comparison |

### What gets created

The landing zone at its smallest supported settings (one session host, the smallest size the preflight accepts in the region, auto shutdown on) plus the demo, and the run store (`avdlz-runs-rg`: one StorageV2 LRS account and the Activity Log diagnostic setting). The landing zone and demo are removed at the end. The run store stays, as decided (§9.2).

### Cost estimate and cap

- **Run store:** under $0.05 for the run, then cents a month (§9.1), plus Defender for Storage if the plan is on, which the preflight reports before anything is deployed.
- **Landing zone and demo:** priced by `Get-AvdCostEstimate` for the chosen size and the hours of the run, printed before the go (R7: no price is guessed here). For scale only: an earlier sandbox demo with one session host cost $0.97 for about eight hours, not counting the landing zone itself.
- **Target:** one sitting of about three hours, from deploy to teardown.
- **Cap:** $10 for the run (accepted by the owner 2026-10-20), enforced by the sandbox budget. If the run goes past six hours, teardown starts.
- **Margin:** the only measured figure is the earlier demo's $0.97 for about eight hours, so a three-hour run should come in at a few dollars. That is a scale, not an estimate: the go/no-go rule is that the printed estimate, including Defender for Storage if it is on, must be **$5 or less** (half the cap). Above that, the run doesn't start, and the plan says which line is high and whether a lower setting would bring it under. If the printed estimate turns out to be under $2, the plan proposes lowering the cap to match, because a tighter budget alert catches a leftover sooner.
- Expected and actual cost are kept in the run's `cost.json` and the companion repo's `costs.csv` (§9.3a); the actual is read again until it settles (up to 3 days).

### Hand steps for the owner

1. Read the printed estimate and say go (or not).
2. In Cloud Shell: run the commands the portal gives, in order. Sign in to Microsoft Graph once (`Connect-AvdLandingZone.ps1`) and to GitHub once (`gh auth login`, device code). Both are device-code sign-ins: no secrets are typed or stored.
3. Close the Cloud Shell tab when the portal says so during the deployment (T1), and reopen it from a second device.
4. Create a private companion repository for run records (§9.3) and set `AVD_PRIVATE_REPO` to it.
5. Approve the teardown prompts (T8).
6. Nothing else: the scripts write the evidence into the run folder, and the run report is filed as a redacted issue for review.

## 14. Open questions for the owner

1. Should `AVDLZ_RECORD=on` (local) become the portal's default for everyone, or stay opt-in? Local recording costs nothing and nothing leaves the shell, but it writes files in the operator's `clouddrive`. The spec says opt-in.
2. *Decided 2026-10-20 by the owner:* the sandbox keeps durable log storage. The run store is set up once per subscription and is not removed with each run (§6.3, §9.2).
3. Should the verified runs table live here or on avd-ops.dev, which already holds the family's user-facing docs?
4. *Decided 2026-10-20 by the owner:* run records go to a separate, operator-owned private companion repository named by `AVD_PRIVATE_REPO`, which can also hold private second-brain material (§9.3).
5. *Decided 2026-10-20 by the owner:* $10 cap for the phase 4 run, with the printed estimate required to be $5 or less (§13a).
