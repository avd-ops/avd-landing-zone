# CLAUDE.md

Cloud-native Azure Virtual Desktop landing zone: Bicep at subscription scope (`bicep/`), a deploy script (`scripts/deploy/deploy.sh`), and PowerShell ops scripts for Azure Cloud Shell (`scripts/ops/`): pre-deployment and post-deployment preflight with `-Fix`, demo host pool, cleanup.

## Read first
- `docs/lessons/README.md`: what real runs taught. **Read the lesson for the area you're changing.** The SessionStart hook prints the index.
- `docs/decisions/README.md`: why things are the way they are.
- `docs/operations.md`, `docs/deploy.md`: what operators actually run.

## Validate before pushing
CI (`.github/workflows/validate.yml`) runs all of these; run the relevant ones locally first. In Claude Code on the web, the SessionStart hook installs the tools.

```bash
bicep lint bicep/main.bicep && bicep lint bicep/demo/main.bicep
AVD_USERS_GROUP_ID=00000000-0000-0000-0000-000000000001 AVD_ADMINS_GROUP_ID=00000000-0000-0000-0000-000000000002 \
AVD_SERVICE_PRINCIPAL_ID=00000000-0000-0000-0000-000000000003 AVD_LOCAL_ADMIN_PASSWORD='Placeholder-only-for-build-1!' \
  bicep build-params parameters/dev.bicepparam --stdout > /dev/null
pwsh -c "Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit"
pwsh -c "Invoke-Pester -Path ./tests -CI"            # unit tests, offline scenarios, template guards
shellcheck scripts/deploy/deploy.sh .claude/hooks/session-start.sh .githooks/pre-commit
gitleaks git --redact .                              # secret scan, as the secret-scan workflow runs it
node --test "tests/portal/*.test.mjs"                # deployment portal engine
```

Without Pester, run an offline scenario directly: `pwsh -File tests/offline/PostDeployment.Scenario.ps1` and read its `RESULT` lines.

## Rules (each came from a real failure; see the lesson)
- **Real runs are the source of truth.** When one fails for a reason tests didn't catch: fix it, add a guard (Pester test, `tests/offline` scenario, template test or preflight check), and write a lesson. Use `.claude/skills/retro/SKILL.md`. (decision 0006)
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
- **When the offline mock disagrees with a real run, fix the mock and add the case.** `tests/offline/AzMock.psm1` must not be more permissive than Azure: it omits empty properties the way ARM does. Offline tests provide every tool they touch. (0020, 0021)
- **Count ARM properties with `@($x | Where-Object { $_ }).Count`, never `@($x).Count`:** ARM omits empty properties and `@($null).Count` is 1. (0021)
- **The deployment portal (`docs/portal`) reads the scripts' state line.** Changing a script's output, parameters or a check the portal recognizes means updating `portal-core.js` and its tests (`node --test "tests/portal/*.test.mjs"`). A real paste analyzed wrongly becomes a fixture. (decision 0007)
- **Portal issue reports are redacted in the browser (`docs/portal/report.js`).** A new kind of private value in output means a pattern, a line in `fixtures/pii-sample.txt`, and a test. New GUIDs in `bicep/` or `scripts/` go into `PUBLIC_IDS`. Check a `portal-report` issue for anything the patterns missed before committing it as a fixture. (decision 0008)

- **Well-Architected findings (`-WellArchitected`) are warnings, never failures,** and each carries `waf-<check>` with `data.pillar`/`data.accepted`. A new check reads through REST, gets a mock response in `AzMock.psm1` and an assertion in the WellArchitected scenario. (decision 0009)

- **Sizing flows through `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT`, `AVD_PROFILE_QUOTA_GIB`** (parameter files with `empty()` guards, `deploy.sh` flags, preflight parameters, portal commands); the power settings the same way through `AVD_START_VM_ON_CONNECT` and `AVD_AUTO_SHUTDOWN_TIME` (the portal's Cost step). A cost line must match exactly one retail price meter, or be reported with the meters it saw; never guess a price. Session hosts default to memory-optimized E-series (`Standard_E4as_v5`) on Premium SSD; a change of size on an existing landing zone must be warned about, not applied silently. (decision 0010)

- **Auto shutdown (`scripts/automation/Invoke-AvdPowerAction.ps1`) is an Automation runbook: Windows PowerShell 5.1, no modules, ARM REST with the managed identity's token.** Lock must survive the next sign-in (drain, scaling plan exclusion tag, Start VM on Connect off); a new action or call gets a mock path in `AzMock.psm1` and an assertion in the AutoShutdown scenario. New role GUIDs come from Microsoft's built-in role reference and go into `PUBLIC_IDS`. (decision 0011)

- **Personal project, not for production, as is, not affiliated with the author's employer.** The MIT `LICENSE`, the README warning, the portal's notice and footer, and the one-line notice at the top of entry-point code stay in place; a new entry-point script or template gets the notice (`tests/portal/disclaimer.test.mjs`).

- **American English** in docs, script output, the portal and comments (a portal test fails on British spellings; recorded fixtures are exempt).

## Git and PRs
- Work on the designated branch; open PRs only when asked. The PR template asks for a Lessons section.
- **Before resetting the branch to `origin/master`, check that no open PR still needs it:** `git merge-base --is-ancestor origin/<branch> origin/master` must succeed. Otherwise build on the branch. (0017)
