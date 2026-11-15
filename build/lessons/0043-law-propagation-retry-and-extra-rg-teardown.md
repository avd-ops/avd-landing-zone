# 0043. A new Log Analytics workspace can outpace Insights DCR/alert validation, and -Fix KV recovery can recreate extra rg-<prefix>-<env>-* groups

- **Area:** deploy.sh, Cleanup
- **Found in / fixed by:** sandbox batch `b20261115-1945` G1 (run `43756405365`, `nickprignano/avd-sandbox#88`)

## What happened
1. `deploy.sh` failed in `avdlz-monitoring` 80 seconds into a fresh `centralus` deployment with six `BadRequest: The workspace could not be found` errors (from `scheduledQueryAlerts`) and `dcr-avd-insights`: `InvalidOutputTable` (`Microsoft-Perf` and `Microsoft-Event` not available for destination `law`), even though no soft-deleted `log-avdlz-dev` existed in `centralus`.
2. During preflight `-Fix`, `Test-AvdDeletedKeyVault` recovered `kvavdlzdevlwu7pdh` into `rg-avdlz-dev-liquidware`. When deploy failed and `Remove-AvdDemo.ps1 -IncludeLandingZone -DiscardLastCopy -Force` ran, it removed only the seven standard landing-zone groups (`portal`, `jumpbox`, `hosts`, `avd`, `storage`, `management`, `network`), leaving `rg-avdlz-dev-liquidware` and `kvavdlzdevlwu7pdh` behind (`Stop-AvdSpendRun.ps1` flagged `Leftovers: 2`).

## Why
1. `Microsoft.OperationalInsights/workspaces` returns `Succeeded` on ARM before the Log Analytics backend finishes registering the workspace and its default `Perf`/`Event` tables for `Microsoft.Insights` validation (`scheduledQueryRules` and `dataCollectionRules`). Bicep `dependsOn` (`workspace`) is already present in `bicep/modules/monitoring.bicep`, so retrying the idempotent subscription deployment after a short wait is required.
2. `Test-AvdDeletedKeyVault -Fix` recovers every soft-deleted vault matching `kv<prefix><env>*` in the target region into its original resource group, which can include non-core tier groups such as `rg-<prefix>-<env>-liquidware`. `Remove-AvdDemo.ps1 -IncludeLandingZone` only iterated over its fixed list of seven resource groups.

## Fix
- `scripts/deploy/deploy.sh`: capture `arm deployment sub create` output with `tee` and retry up to 2 times (30s wait, configurable via `AVD_DEPLOY_RETRY_WAIT`) when it fails with `InvalidOutputTable` or `The workspace could not be found`.
- `scripts/ops/Remove-AvdDemo.ps1`: under `-IncludeLandingZone`, after deleting the seven standard resource groups, also delete any remaining `rg-<prefix>-<env>-*` resource groups (e.g. `rg-<prefix>-<env>-liquidware`).

## Guard
- `build/tests/offline/Deploy.Scenario.ps1` (`law-retry`) + `build/tests/OfflineScenarios.Tests.ps1`: simulates a transient `The workspace could not be found` + `InvalidOutputTable` failure on the first `az deployment sub create` and verifies `deploy.sh` retries and exits `0`.
- `build/tests/offline/PostDeployment.Scenario.ps1` (`remove-lz`) + `build/tests/OfflineScenarios.Tests.ps1`: seeds `rg-avdlz-dev-liquidware` before `Remove-AvdDemo.ps1 -IncludeLandingZone` and verifies `remainingRgs=0`.

## Rule
Retry transient Log Analytics propagation failures (`InvalidOutputTable` / `The workspace could not be found`) in `deploy.sh`, and tear down all `rg-<prefix>-<env>-*` groups (including `-Fix`-recovered tier groups) under `Remove-AvdDemo.ps1 -IncludeLandingZone`.
