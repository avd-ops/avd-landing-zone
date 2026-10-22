@AGENTS.md

# CLAUDE.md

Cloud-native Azure Virtual Desktop landing zone: Bicep at subscription scope (`bicep/`), a deploy script (`scripts/deploy/deploy.sh`), and PowerShell ops scripts for Azure Cloud Shell (`scripts/ops/`): pre-deployment and post-deployment preflight with `-Fix`, demo host pool, cleanup.

## Read first
- `build/lessons/README.md`: what real runs taught. **Read the lesson for the area you're changing.** The SessionStart hook prints the index.
- `build/decisions/README.md`: why things are the way they are.
- `docs/operations.md`, `docs/deploy.md`: what operators actually run.

## Validate before pushing
CI (`.github/workflows/validate.yml`) runs all of these; run the relevant ones locally first. In Claude Code on the web, the SessionStart hook installs the tools.

```bash
bicep lint bicep/main.bicep && bicep lint bicep/demo/main.bicep
AVD_USERS_GROUP_ID=00000000-0000-0000-0000-000000000001 AVD_ADMINS_GROUP_ID=00000000-0000-0000-0000-000000000002 \
AVD_SERVICE_PRINCIPAL_ID=00000000-0000-0000-0000-000000000003 AVD_LOCAL_ADMIN_PASSWORD='Placeholder-only-for-build-1!' \
  bicep build-params parameters/dev.bicepparam --stdout > /dev/null
pwsh -c "Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"
# plus the compatibility passes in validate.yml: build/analyzer/Portable.psd1 (scripts/ops) and WindowsPowerShell.psd1 (in-Azure scripts)
pwsh -c "Invoke-Pester -Path ./build/tests -CI"            # unit tests, offline scenarios, template guards
shellcheck scripts/deploy/deploy.sh .claude/hooks/session-start.sh .githooks/pre-commit build/snapshot-diff.sh
gitleaks git --redact .                              # secret scan, as the secret-scan workflow runs it
node --test "build/tests/portal/*.test.mjs"                # deployment portal engine
```

Without Pester, run an offline scenario directly: `pwsh -File build/tests/offline/PostDeployment.Scenario.ps1` and read its `RESULT` lines.

## Rules (each came from a real failure; see the lesson)
- **Real runs are the source of truth.** When one fails for a reason tests didn't catch: fix it, add a guard (Pester test, `build/tests/offline` scenario, template test or preflight check), and write a lesson. Use `.claude/skills/retro/SKILL.md`. (decision 0006)
- **Diagnose before guessing.** When an external API fails, the first change reports everything it returned: step, HTTP status, error code, body, relevant headers. (lesson 0012)
- **Prefer REST where a cmdlet reshapes or blocks.** Use `Invoke-AvdArm` / `Invoke-AvdGraph`; check cmdlet output shapes and parameter sets against the docs. (0005, 0006, 0014, decision 0002)
- **Anything slow prints a line before it starts; "Fixed" means done.** (0006)
- **Loops over remote calls must end on error or empty results.** (0008)
- **Emit items, not a single array object; assign before piping `Get-AvdCheckResult`.** (0009)
- **Never `| Out-Null` `Connect-MgGraph`; verify a Graph sign-in with a real request; identify the Azure user with `Get-AzADUser -SignedIn`.** (0007)
- **Host scripts (`scripts/ops/host`, `scripts/sessionhost`) run in Windows PowerShell 5.1.** No PowerShell 7-only syntax; capture error bodies from the response stream. (0011)
- **PSScriptAnalyzer:** approved verbs (`Get-` for functions that only build data), singular nouns. CI's analyzer is newer than most local ones. (0016)
- **AVM modules:** check nested defaults (zones, SKUs, locations) in the compiled template; test a region without zones. (0001)
- **Optional env vars in `.bicepparam`:** guard with `empty(...)`, because the default argument doesn't cover set-but-empty. (0004)
- **Never make operators remember secrets.** (0002)
- **Commands given to operators are self-contained Cloud Shell blocks:** clone or update, `Set-Location`, `Connect-MgGraph` when needed. Sessions are ephemeral and disconnect. (0015)
- **When the offline mock disagrees with a real run, fix the mock and add the case.** `build/tests/offline/AzMock.psm1` must not be more permissive than Azure: it omits empty properties the way ARM does. Offline tests provide every tool they touch. (0020, 0021)
- **Count ARM properties with `@($x | Where-Object { $_ }).Count`, never `@($x).Count`:** ARM omits empty properties and `@($null).Count` is 1. (0021)
- **The deployment portal (`site/portal`) reads the scripts' state line.** Changing a script's output, parameters or a check the portal recognizes means updating `portal-core.js` and its tests (`node --test "build/tests/portal/*.test.mjs"`). A real paste analyzed wrongly becomes a fixture. (decision 0007)
- **Portal issue reports are redacted in the browser (`site/portal/report.js`).** A new kind of private value in output means a pattern, a line in `fixtures/pii-sample.txt`, and a test. New GUIDs in `bicep/` or `scripts/` go into `PUBLIC_IDS`. Check a `portal-report` issue for anything the patterns missed before committing it as a fixture. (decision 0008)

- **Well-Architected findings (`-WellArchitected`) are warnings, never failures,** and each carries `waf-<check>` with `data.pillar`/`data.accepted`. A new check reads through REST, gets a mock response in `AzMock.psm1` and an assertion in the WellArchitected scenario. (decision 0009)

- **Sizing flows through `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT`, `AVD_PROFILE_QUOTA_GIB`** (parameter files with `empty()` guards, `deploy.sh` flags, preflight parameters, portal commands); the power settings the same way through `AVD_START_VM_ON_CONNECT` and `AVD_AUTO_SHUTDOWN_TIME` (the portal's Cost step). A cost line must match exactly one retail price meter, or be reported with the meters it saw; never guess a price. Session hosts default to memory-optimized E-series (`Standard_E4as_v5`) on Premium SSD; a change of size on an existing landing zone must be warned about, not applied silently. (decision 0010)

- **Target-state manifests (contract C14) are read, never trusted:** `scripts/ops/ConvertFrom-AvdTargetState.ps1` (pure logic in `AvdTargetState.psm1`) refuses whatever `contracts/target-state-capabilities.json` doesn't list and passes sizing to `deploy.sh` as **flags**, because `deploy.sh` overwrites the `AVD_*` sizing variables with its flags. A new sizing or power flag means a line in the reader and its test. The files in `contracts/` are byte-identical copies at the commits in `contracts/PINS.json`: C15 and C17 from avd-assess (which authors them, avd-second-brain decision 0021), C14 from avd-second-brain; update them together, never by hand.

- **Auto shutdown (`scripts/automation/Invoke-AvdPowerAction.ps1`) is an Automation runbook: Windows PowerShell 5.1, no modules, ARM REST with the managed identity's token.** Lock must survive the next sign-in (drain, scaling plan exclusion tag, Start VM on Connect off); a new action or call gets a mock path in `AzMock.psm1` and an assertion in the AutoShutdown scenario. New role GUIDs come from Microsoft's built-in role reference and go into `PUBLIC_IDS`. (decision 0011)

- **Never delete the last copy** (avd-second-brain decision 0016). A step that deletes data (logs, diagnostics, evidence, reports, backups, user data) first checks that a durable copy exists outside what it deletes, or the operator passes `-DiscardLastCopy`, which `-Force` never implies. Teardown separates disposable resources from evidence; old data moves to a colder tier, never deleted. Logs and teardown evidence go to one run store outside the deployment, kept by default (`-TeardownLogs Keep`; run recorder spec R9 is the reference). `Remove-AvdDemo.ps1 -IncludeLandingZone` and the image build's template delete need `-DiscardLastCopy` until those exports exist.

- **Never leave the meter running** (avd-second-brain decision 0017). Anything that bills by time is removed, stopped or on a schedule at the end of a run unless the operator opts in with an expiry or a reason; the demo hosts carry their own daily shutdown, and the preflight warns when a dev or test landing zone has no budget.

- **Sandbox runs are part of the package** (decision 0020, `docs/sandbox-runs.md`). Spend runs, batches, approvals and results live in the run store's `records` container and are written with conditional writes; the local folder is a cache and `-Local` says it is the only copy. A group runs once per approval, resumes after a Cloud Shell drop (`-Resume`, `-TeardownOnly`), and nothing deletes leftovers automatically. A person types the go (`go batch <id> $<total>`); a model never approves. The v1 batch hash is frozen (golden test in `SandboxRuns.Tests.ps1`), and a new ARM route for these scripts goes into `AzMock.psm1` under `$St.spend` with an assertion in the SandboxBatch scenario. Teardown is part of the batch (decision 0021, lesson 0036): the runner tears down on any error it sees, each group arms its deadline teardown (the run store's Automation account) before it claims anything, and the next group's block closes an earlier group whose runner is gone; never make a hand-run `-TeardownOnly` the plan. The deadline runbook (`scripts/automation/Invoke-AvdSandboxDeadline.ps1`) is Windows PowerShell 5.1 with no modules, deletes only `rg-<prefix>-<env>-*` and only when the approved teardown passes `-DiscardLastCopy`; its calls get routes in `AzMock.psm1` and assertions in the SandboxDeadline scenario.

- **Personal project, not for production, as is, not affiliated with the author's employer.** The MIT `LICENSE`, the README warning, the portal's notice and footer, and the one-line notice at the top of entry-point code stay in place; a new entry-point script or template gets the notice (`build/tests/portal/disclaimer.test.mjs`).

- **American English** in docs, script output, the portal and comments (a portal test fails on British spellings; recorded fixtures are exempt).

- **Stay in the AVD lane** (avd-second-brain decision 0012). This repo is native AVD, Azure, Entra and Microsoft 365 automation in Bicep and PowerShell. If an ask is in another project's lane ([docs/out-of-scope.md](docs/out-of-scope.md#another-projects-lane): any HCL and everything Nerdio go to nerdio-hcl, the Liquidware tier to avd-liquidware), say which project and repo own it, link it, and stop. Before researching a topic, read the owner's `llms.txt` (one file listing its knowledge base) and link what it already knows instead of re-learning it. CI fails on an HCL file (`lanes.yml`).

## Git and PRs
- Work on the designated branch; open PRs only when asked. The PR template asks for a Lessons section.
- **Knowledge capture and handoffs** ([AGENTS.md](AGENTS.md); avd-second-brain decisions 0013 and 0014): a PR that changes code carries `KB: <link>` to the lesson in avd-second-brain's KB, or the `no-kb` label and a `No KB entry: <reason>` line (`kb-capture` check, Stop hook). Before starting work, check this repo's open `handoff` issues (the SessionStart hook lists them).
- **Before resetting the branch to `origin/master`, check that no open PR still needs it:** `git merge-base --is-ancestor origin/<branch> origin/master` must succeed. Otherwise build on the branch. (0017)
