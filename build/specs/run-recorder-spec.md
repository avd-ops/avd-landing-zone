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

`deploy.sh` reads the same two variables. With neither set, the scripts behave exactly as today.

### 6.2 Events

One JSON object per line (JSONL), schema `build/specs/run-journal.schema.json` (added in phase 1), version `v: 1`:

| Event | Fields |
|---|---|
| `step.start` | `runId`, `step` (script and stage), `portalStep` (the step that printed the command, if any), `params` (names, non-secret values, `<set>` for secrets), `repoCommit`, `shell` (`pwsh`/`bash`), `cloudShell` (bool), `ts` |
| `check` | the check's `id`, `status`, `area`, and `data`: the same objects the state line carries |
| `api.error` | step, HTTP status, error code, body excerpt and correlation ID (lesson 0012). Private level only. |
| `step.end` | exit code, duration, the full state line |
| `operator.note` | free text from `Add-AvdRunNote "..."`, for "I did X by hand in the portal" |

`portalStep` against the actual `params` gives the **deviation** signal: when operators keep changing the command the portal gave them, the portal is wrong.

### 6.3 Where it is kept

| Store | When | Survives a reset | Cost |
|---|---|---|---|
| **Local** `~/clouddrive/avdlz-runs/<runId>/` | `AVDLZ_RECORD=on` and `clouddrive` is mounted | Yes | the operator's existing Cloud Shell share |
| **Local** `~/avdlz-runs/<runId>/` | `on`, ephemeral session | No: the resume point still works from Azure (§4) | none |
| **Azure** `runs/<runId>/` in a recorder storage account | `AVDLZ_RECORD=azure` | Yes, and readable from any device | cents (§9) |

The Azure store is created by `Start-AvdRunRecorder.ps1` (Bicep module `bicep/recorder/main.bicep`, its own template, not part of `main.bicep`):
- Its own resource group, `<prefix>-runs-rg`. It is a **standing store**: it outlives the landing zone's cleanup, holds the teardown evidence and the history of every recorded run, and is removed only on request (§9.2).
- One StorageV2 account, LRS, hot tier; shared key access off, minimum TLS 1.2, no public blob access; the operator gets Storage Blob Data Contributor on the account only. Entra auth from Cloud Shell, no keys or SAS anywhere (R2).
- Append blobs for the journal; block blobs for redacted transcripts and the report.
- A lifecycle rule deletes run folders after 90 days, so the store stays small without anyone pruning it.
- **No locked immutability.** A locked time-based retention policy makes the container and account undeletable until it expires (§12, F4), which breaks R6. Integrity comes from a SHA-256 manifest written at the end of the run and included in the report. Locked WORM retention is a §10 option, never a sandbox default.
- Tagged `avdlz-run: <runId>` and `avdlz-component: recorder`.

### 6.4 Transcripts (optional)

`AVDLZ_TRANSCRIPT=on` adds the raw console output:
- PowerShell: the scripts call `Start-Transcript` / `Stop-Transcript` around themselves into a temp file, then redact it at the private level before it is kept.
- `deploy.sh`: re-executes itself under `script -q` the same way.
- Native command output inside `pwsh` (for example `az` called from PowerShell) may not be fully captured by `Start-Transcript`; phase 1 checks this offline and in the first real run (§12, U3). The journal never depends on the transcript.

## 7. Azure-side evidence (read, not exported)

The recorder reads what Azure already keeps instead of exporting it by default:

| Source | How | Default | Why |
|---|---|---|---|
| **Activity Log**, for the run's window, the operator as caller, the landing zone's resource groups | ARM REST, at `Stop-AvdRunRecorder` time | On | Retained 90 days at no charge (§12, F1). Shows every control-plane write the run made, including ones a script didn't report |
| **Deployment operations** of each deployment in the run | ARM REST | On | The exact failed operation and its status message |
| **Entra audit log** entries for the groups and app registrations the scripts touch | Graph, with the operator's existing sign-in | On if the Graph sign-in is already there | App and group changes; access to audit logs through Graph may need a premium license (§12, U4), so a refusal is reported, not fatal |
| **Diagnostic setting** exporting the Activity Log to the recorder account | `-ExportActivityLog` | Off | Only for runs that need more than 90 days; removed by teardown |
| **Entra and Graph activity log export** | not built | Off | Tenant-wide, needs Security Administrator; Graph activity logs need Entra ID P1 or P2 (§12, F3). Out of the landing zone's footprint |

Everything read is redacted at the private level before it is stored and at the public level before it is shared.

## 8. From a run to fixes and shared knowledge

### 8.1 The run report

`Stop-AvdRunRecorder.ps1 -RunId <id>` (also offered by the portal at the end of a run, and after cleanup) produces `report.md` and `report.json`:

1. **Run summary:** steps in order, durations, outcomes, repo commit, region, sizing.
2. **Portal misses:** every pasted output the portal classified as `source: 'text'` or `'none'` (from the portal side, §8.3), every state `id` the portal has no branch for, and every deviation (§6.2).
3. **Failures:** each with its `id`, the API error (§6.2) and the matching Activity Log and deployment operation entries.
4. **Cost:** the run's estimate (from `Get-AvdCostEstimate` before the run) against the actual cost for the run's resource groups once Cost Management has it, which can take a day or more (§12, U5). Until then the report says *pending*, never a guess (R7).
5. **Teardown evidence:** a Resource Graph query, after cleanup, for anything tagged `avdlz-run: <runId>` or named by the landing zone's convention, with its result; the soft-deleted Key Vault and Log Analytics workspace states (lessons 0022, 0023); written to the recorder store, which stays (§9.2).
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
| Blob storage, LRS hot | under 50 MB per run, kept up to 90 days | under $0.01 per run per month |
| Write and list operations | about 2,000 per run (append blocks, transcripts, listing) | under $0.02 |
| Activity Log, deployment operations, Resource Graph reads | ARM and Resource Graph reads | $0 |
| Diagnostic setting export (`-ExportActivityLog`) | off by default | $0 |
| **Defender for Storage**, if the subscription has the plan on | billed per storage account per month, prorated | **must be checked first**: it could exceed everything else; the preflight reports the plan's state and the recorder refuses `azure` mode without `-AcceptDefenderCharge` while it is on |
| **Recorder total per run** | | **under $0.05**, excluding Defender |

Prices above are from Microsoft's sample price tables (§12, F5). The real estimate comes from the retail prices API through `Get-AvdCostEstimate`, with a line per recorder meter (R7), printed before the recorder deploys. `AVDLZ_RECORD=on` (local) costs nothing.

### 9.2 Teardown rule

1. The landing zone is torn down after every sandbox run, as today. The recorder keeps recording through the cleanup.
2. `Stop-AvdRunRecorder.ps1 -RunId <id>` writes the teardown evidence (§8.1, item 5) and the report to the recorder store and prints the public report link. The store stays: the cost line is filled in when Cost Management has it (a day or more), and the next run's resume and history read from it.
3. The recorder itself is removed only on request: `Stop-AvdRunRecorder.ps1 -Remove` first downloads every run folder to the current directory (`clouddrive` if mounted), confirms the download, then deletes `<prefix>-runs-rg` and confirms it is gone as its last line. Inputs are deleted last (lesson 0029): if the download fails, nothing is deleted.
4. Idle cost is a few MB of blobs, cents a month, plus Defender for Storage if the plan is on (§9.1). The monthly spend reconciliation lists the recorder as a standing item, so it is never a leftover.

## 10. Free and open source vs a possible paid, hosted feature

| Free, in this repo (MIT) | Possible paid, hosted later (not designed here) |
|---|---|
| The journal, transcripts and redaction | Run history across many runs, landing zones and tenants, with search and trends |
| `Get-AvdRunStatus.ps1` and the portal's resume action | Cross-device resume without pasting (a hosted service that reads the operator's store with their consent) |
| The local and the in-tenant Azure store | Compliance retention: locked WORM, evidence packs for a change board, signed manifests |
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
| **P3, Azure store** | `bicep/recorder/main.bicep`, `Start-`/`Stop-AvdRunRecorder.ps1`, the recorder's cost lines, teardown, AzMock paths and a scenario | $0 offline |
| **P4, first real run** | One sandbox run in the maintainer's personal subscription, smallest sizes, northcentralus: deploy, close the tab mid-deploy, resume, post-deployment, cleanup, recorder removal. Confirms U1 to U6 | Only after a written estimate and the owner's yes; teardown evidence and actual cost recorded |
| **P5, feedback** | Run report issue and label, retro skill entry, `docs/verified-runs.md`, field report path in the family KB | $0 |

## 14. Open questions for the owner

1. Should `AVDLZ_RECORD=on` (local) become the portal's default for everyone, or stay opt-in? Local recording costs nothing and nothing leaves the shell, but it writes files in the operator's `clouddrive`. The spec says opt-in.
2. *Changed 2026-10-20 after the owner asked why it was removed the same day:* the recorder is now a standing store, not removed with each run (§9.2). Confirm or revert.
3. Should the verified runs table live here or on avd-ops.dev, which already holds the family's user-facing docs?
