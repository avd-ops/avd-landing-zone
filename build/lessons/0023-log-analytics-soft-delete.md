# 0023. Deleting a resource group only soft-deletes its Log Analytics workspace

- **Area:** Cleanup, deployment
- **Found in / fixed by:** after #29 (redeploy of dev on 2026-09-30, the day after a cleanup)

## What happened
`Remove-AvdDemo.ps1 -IncludeLandingZone` removed the landing zone on 2026-09-29. The next day, the same `deploy.sh` command failed while creating the AVD Insights data collection rule:

```
InvalidOutputTable: Table for output stream 'Microsoft-Perf' is not available for destination 'law'.
Please ensure that the table exists in Log Analytics Workspace before creating or updating the rule.
```

The same error followed for `Microsoft-Event`. Running the same command again deployed fine.

## Why
Deleting a resource group soft-deletes its Log Analytics workspace for 14 days. Creating a workspace with the same name in the same resource group recovers the deleted one, and its tables come back a little later. Cloud Shell showed:

- `log-avdlz-dev` was **created 2026-09-28T21:21:34Z**, the first deployment's workspace;
- it was **modified 2026-09-30T14:23:28Z**, seconds into the new deployment;
- `Perf` and `Event` were `Succeeded` by the time of the rerun.

So the rule was written against a recovered workspace whose tables weren't there yet. The first deployment never hit this because its workspace was brand new.

## Fix
- **Cleanup:** before deleting the resource groups, it deletes the workspace permanently (`DELETE ...workspaces/<name>?api-version=2023-09-01&force=true`), so the next deployment creates a new one.
- **Portal:** it recognizes `InvalidOutputTable` and gives the same deploy command again, for landing zones cleaned up before this fix.

## Guard
- **PostDeployment scenario:** `remove-lz-workspace` checks that there is exactly one forced workspace delete, and that it comes before the management resource group is deleted.
- **Portal:** a test runs on the real, redacted output (`build/tests/portal/fixtures/real-deploy-dcr-tables.txt`).

## Rule
When cleanup deletes a resource group, check which of its resources Azure only soft-deletes, and whether a redeploy under the same name recovers them instead of creating them. Delete those permanently, or make the next deployment handle the recovered state. The Key Vault is the other case (lesson 0022).
