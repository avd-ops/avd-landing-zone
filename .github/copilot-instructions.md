# Review instructions for this repository

Opinionated Azure Virtual Desktop landing zone: Bicep at subscription scope (`bicep/`), `scripts/deploy/deploy.sh`, PowerShell ops scripts for Azure Cloud Shell (`scripts/ops/`), and a static deployment portal (`docs/portal/`). Personal project, not for production. Full rules: `CLAUDE.md`; lessons: `docs/lessons/`; decisions: `docs/decisions/`.

You are an advisory reviewer. Never approve, and never say a change is safe to merge. Report only what the diff introduces. Mark each finding **Important** (a bug or a broken rule below) or **Nit**, and say what fails, when, and the fix.

## Check every PR for

1. **Host scripts run in Windows PowerShell 5.1.** No PowerShell 7-only syntax (`??`, `?.`, ternary, `-Parallel`, `ConvertFrom-Json -AsHashtable`) in `scripts/sessionhost/`, `scripts/ops/host/`, `scripts/image/` or `scripts/automation/`. (lesson 0011)
2. **Optional env vars in `.bicepparam` need an `empty(...)` guard.** The `readEnvironmentVariable` default doesn't cover set-but-empty. (0004)
3. **Count ARM properties with `@($x | Where-Object { $_ }).Count`**, never `@($x).Count`: ARM omits empty properties and `@($null).Count` is 1. (0021)
4. **Loops over remote calls must end on an error, an empty page, or a page limit.** (0008)
5. **Emit items, not one array object.** Assign before piping `Get-AvdCheckResult`. (0009)
6. **Never `| Out-Null` `Connect-MgGraph`.** Verify a Graph sign-in with a real request. Identify the Azure user with `Get-AzADUser -SignedIn`. (0007)
7. **Diagnose first:** when an external API call fails, report the step, HTTP status, error code and body. (0012)
8. **Prefer REST (`Invoke-AvdArm`, `Invoke-AvdGraph`) where a cmdlet reshapes output or blocks.** (decision 0002)
9. **Anything slow prints a line before it starts.** "Fixed" means done. (0006)
10. **Portal contract:** a change to a script's output, parameters or a check the portal recognizes needs the matching change in `docs/portal/portal-core.js`, its tests and the state-line schema in `docs/portal/README.md`. Pasted output is never sent anywhere. The page's only network calls are the timed probes. (decision 0007)
11. **New GUIDs in `bicep/` or `scripts/` go into `PUBLIC_IDS` in `docs/portal/report.js`.** A new kind of private value in output needs a redaction pattern and a test. (decision 0008)
12. **The offline mock (`tests/offline/AzMock.psm1`) must not be more permissive than Azure.** A new call gets a mock path and a scenario assertion. (0020, 0021)
13. **A fix for a real-run failure needs a guard** (a test, an offline scenario or a check) **and a lesson.** (decision 0006)
14. **Commands given to operators are self-contained Cloud Shell blocks**: clone or update, `Set-Location`, then the command. (0015)
15. **Never make operators remember secrets.** No secrets in the repo, parameter files, logs or output. (0002)
16. **AVM modules:** check nested defaults (zones, SKUs, locations) and pinned versions. (0001)
17. **Well-Architected findings are warnings, never failures.** (decision 0009) **A cost line matches one retail price meter, or it's reported with the meters it saw; never guess a price.** (decision 0010)
18. **The default deployment must not change** in time, resources or required parameters unless the PR says so. Optional features stay behind a flag that is off by default.
19. **Guardrails:** say plainly whether a change to guardrails in the operations brain spec §9.2 (avd-second-brain `docs/operations-spec.md`) or `docs/image-pipeline-spec.md` raises or lowers capability.
20. **American English** in docs, script output, the portal and comments (recorded fixtures excepted). New entry-point scripts and templates keep the one-line "personal project, not for production" notice.
