---
name: sandbox-batch
description: Plan, price and hand over a sandbox test run or batch for the landing zone (docs/sandbox-runs.md, decision 0020). Use when the user wants something tested in a sandbox subscription, asks what a run would cost, wants test items queued or batched, asks where a batch stands, or a Cloud Shell run dropped part way.
---

# Sandbox batches: price it, hand it over, never approve it

You prepare; a person approves and runs. Nothing here deploys from this session: you have no Azure sign-in, and a run needs the person's go at an exact total.

## Hard rules
- **Never approve.** Don't type, suggest typing on the user's behalf, or write `approval.json`. The go is `go batch <id> $<total>`, typed by the person into `Approve-AvdSandboxBatch.ps1`. A bare "go", "yes" or "looks good" in chat approves nothing; say so if it comes up.
- **No cost without a written estimate.** Every item states its rate per hour, hours and an estimate note (the source of the prices and the date). Use `Get-AvdCostEstimate` figures (the preflight's estimate or `Start-AvdSpendRun.ps1 -EstimateOnly`); a cost line must match one retail meter, never a guess (decision 0010).
- **No private values in an item.** No GUIDs, emails, tenant domains, subscription or object IDs: the approved batch freezes its text, and `New-AvdSandboxBatch.ps1` refuses them. Steps read such values from variables at run time.
- **Nothing deletes automatically.** Teardown is the item's own step. When a close finds leftovers, the batch stops; the person clears them, then reruns `Stop-AvdSpendRun.ps1`.
- **Smallest sizes, tear down right after**, and keep anything that is the only copy (`keep` paths go to the run store before teardown; avd-second-brain decision 0016).

## 1. Write the items
One `sandbox-run/v1` JSON file per test (format in `docs/sandbox-runs.md`, "Queue items"). Pin `source` to a full 40-hex commit when you can. Give items that can share one deployment the same `deploymentKey`; set `hoursWhenSharing` for the extra hours each adds. Steps are bash, run from the item's checkout, and must be safe to run twice (resume reruns the interrupted step). Set `unattended` only when no step waits for a person. Add `record` for a recorded run, `keep` for output to keep.

## 2. Check offline before handing over
```bash
pwsh -c "Invoke-Pester -Path ./build/tests/SandboxRuns.Tests.ps1 -CI"
```
If you changed the scripts, run the `SandboxBatch` offline scenario too (`build/tests/OfflineScenarios.Tests.ps1`), and the analyzer.

## 3. Hand over
Give the person one self-contained block for Cloud Shell, which runs from either prompt:
```shell
pwsh -NoLogo -Command 'if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }; Set-Location ~/avd-landing-zone; git pull -q --ff-only; ./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath ~/clouddrive/queue -MonthlyCap 150 -RunCap 25'
```
The script prints `batch.md`: the groups, the total and the blocks to approve and run each group. Quote the total and the exact go phrase back to the person, with what each group deploys and for how long. Then stop and wait.

## 4. When a run stopped
Ask for the output of `./scripts/ops/Get-AvdSandboxBatchStatus.ps1`. It prints the next block: `-Resume` for a group Cloud Shell dropped, `-TeardownOnly` to stop and clean up, `-ContinueAfterStop` only after the reason an earlier group stopped the batch is dealt with. A spend run still open may be billing: say so first.

## 5. After
A finding from a real run (a step that failed for a reason tests didn't catch, an estimate far off) goes through the retro skill: a lesson and a guard.
