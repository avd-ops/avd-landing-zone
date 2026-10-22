# 0021. Teardown is part of the batch: a guaranteed path in the runner, and a deadline teardown in Azure that needs no shell

- **Status:** Proposed

## Context
Decision 0020 put sandbox batches in the package and made every path that deployed anything go through keep, teardown and the spend close. That held only while the runner held: the runner is a script in a Cloud Shell session, and two things stopped it without a teardown.

- **A script error outside a step.** Each step catches its own errors, but the code between steps (saving results, reading the next step, the records sync) didn't. An error there ended the script with the spend run open and the landing zone deployed.
- **The shell going away.** Cloud Shell ends an idle session after about 20 minutes, a tablet's browser drops it, and the operator may be offline for days. No `finally` block runs when the process is gone.

Both left the operator a second block to run by hand, `-TeardownOnly` (lesson 0036). The owner's rule is plainer than that: teardown is part of the batch, or a separate time-boxed process that runs regardless; nobody runs a separate teardown.

## Decision
- **The runner tears down on any stop it can see.** From the spend run opening to the close, the runner runs inside `try`/`catch`/`finally`. A script error or Ctrl+C after the spend run opened goes through keep, export, teardown and close before the script ends, and the group stops the batch.
- **A deadline teardown that needs no shell.** `Initialize-AvdRunStore.ps1` adds an Azure Automation account, `aa-avdlz-runs`, beside the run store in `avdlz-runs-rg`, with the runbook `scripts/automation/Invoke-AvdSandboxDeadline.ps1` pinned to a commit (never master, as deploy.sh pins the auto-shutdown runbook). Before a group claims anything, the runner links a one-time schedule to it at the group's deadline plus its teardown budget plus 30 minutes, so a live runner always finishes first. Arming fails before the claim, so a failure claims, deploys and spends nothing, and the same block runs again once it's fixed. A group that closes clean takes the schedule down.
- **What the deadline teardown does.** It reads the group's results from the run store; a group that closed clean needs nothing. Otherwise it finds the resource groups `rg-<prefix>-<env>-*` (the group's landing zone by its naming convention: a recorded group's own name, any other the defaults, as the health check reads them):
  - when the approved teardown passes `-DiscardLastCopy` (part of the approved text, so the person who typed the go already accepted it), it deletes them and waits until they are gone; Log Analytics workspaces go to their 14-day soft delete, recoverable;
  - otherwise it only deallocates their VMs: the compute meter stops and every disk, share and log stays for a person (avd-second-brain decision 0016 outranks the meter here).
  It writes `deadline-<group>.json` beside the results: what it found, deleted, deallocated and left. It never touches `avdlz-runs-rg`.
- **Least privilege for the identity.** A custom role on the subscription: read and delete resource groups, read and deallocate VMs, nothing else (deleting a resource group needs only the group's delete action). Storage Blob Data Contributor on the `records` container only. The landing zone's resource groups don't exist until it deploys, so the scope can't be narrower than the subscription; the runbook's own scope is the name prefix.
- **The next block closes what the deadline tore down.** A group's block first looks at the earlier groups of its batch. One that stopped part way and whose runner is gone (its last step older than its deadline and teardown budget) is torn down and closed, with teardown evidence, as part of that block. One that may still be running in another shell stops the block, which names the deadline teardown's time. Stop rules from decision 0020 still apply after that: a group that stopped the batch needs `-ContinueAfterStop`.
- **Opting out is explicit.** `-NoDeadlineTeardown` runs a group without one and says so. `-Local` records need it, since the runbook reads results from the run store; `New-AvdSandboxBatch.ps1 -Local` prints it in the blocks.

## Alternatives
- **Logic App with a "Delay until" action:** no per-region account limit, but the rule (closed clean? which groups? discard or keep?) would live in a workflow definition that the offline tests can't run. The runbook is PowerShell like the rest, tested in an offline scenario.
- **Azure Functions timer:** needs a storage account, an app and a deployment of code: more to set up and pay for than one runbook.
- **A CI schedule (GitHub Actions cron):** depends on a repo's secrets and a CI system, which decision 0020 keeps out of the package; scheduled workflows also drift by many minutes and run only on the default branch.
- **Background process in Cloud Shell:** dies with the session, which is the failure this decision is about.
- **Delete everything new since the spend run's baseline:** catches more, but would delete anything a person created by hand during the run. The name prefix is the narrower promise.

## Consequences
- A group whose shell dies stops billing within its deadline plus teardown budget plus 30 minutes, with no one at the keyboard. The approved estimate covers the hours to the deadline; the teardown budget and grace are the most it can run past them.
- The runbook doesn't export the AVD logs before deleting (the run recorder does that from Cloud Shell). The workspace's 14-day soft delete is the window to recover them.
- It removes Azure resources only. Entra device objects the hosts left are reported by the next health check, as before.
- Cost: an Automation account costs nothing while idle; each firing is a few minutes of the 500 free job minutes a month per subscription, shared with the landing zone's auto shutdown. Pay-as-you-go subscriptions allow two Automation accounts per region; `Initialize-AvdRunStore.ps1` warns when the run store's region already has two.
- The operator runs `Initialize-AvdRunStore.ps1` once more to add it. Until then, groups refuse to start without `-NoDeadlineTeardown`.
