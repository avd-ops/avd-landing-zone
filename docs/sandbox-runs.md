# Sandbox runs from Cloud Shell

Test the landing zone (or anything else) in a sandbox subscription without leaving something billing and without spending more than you agreed to. Everything here runs from Azure Cloud Shell (PowerShell) with no GitHub Actions, no service principal and no secret: you are signed in, and the scripts use your session. Why it is part of the landing zone: [decision 0020](../build/decisions/0020-sandbox-runs-in-the-package.md).

Two levels:
- **A spend run** wraps one thing you do by hand: an estimate and a cap check before, a proof that it is all gone after.
- **A sandbox batch** queues several test items, groups the ones that can share a deployment, prices the batch, waits for a person's go at that exact total, then runs each group: spend run, deploy, tests, keep, teardown, close.

| Script | What it does |
|---|---|
| `Set-AvdSpendBudget.ps1` | Once per sandbox subscription: a standing monthly cost budget (`sandbox-spend`) that emails you at 50, 80 and 100% and on a 100% forecast, even when no landing zone is deployed. Supports `-WhatIf`. |
| `Start-AvdSpendRun.ps1` | Before a run: prices it (from the preflight's estimate, a region and size, or an amount you enter), checks it against your monthly and per-run caps and the month-to-date cost, refuses when it doesn't fit, and records a baseline of what exists. `-EstimateOnly` prices without opening a run. |
| `Stop-AvdSpendRun.ps1` | After teardown: compares the subscription with the baseline. Anything new is a leftover; the run stays open and the script exits 1 until it's gone (or named with `-Keep`). |
| `New-AvdSandboxBatch.ps1` | Builds a batch from the ready queue items: pins each source to a commit, groups by deployment key, prices the groups, applies the batch, run and monthly caps, and writes `batch.json` and `batch.md` (with the Cloud Shell blocks to approve and run it). |
| `Approve-AvdSandboxBatch.ps1` | A person types the go phrase, `go batch <id> $<total>`. It must name the batch and its exact total, and the approval is bound to the batch's hash: any later change voids it. |
| `Invoke-AvdSandboxBatch.ps1` | Runs one group of an approved batch. `-Resume` continues a group Cloud Shell dropped; `-TeardownOnly` is the safety net. |
| `Get-AvdSandboxBatchStatus.ps1` | Where every batch and group stands, which spend runs are still open, and the block to run next. Read-only. |

They share `AvdSpend.psm1` (estimates, the gate, teardown evidence, records) and `AvdSandboxBatch.psm1` (items, groups, the batch hash, approvals, resume), both pure functions tested offline (`build/tests/SandboxRuns.Tests.ps1`, the `SandboxBatch` offline scenario).

## Before the first run

```powershell
# Cloud Shell (PowerShell), in the sandbox subscription
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }
Set-Location ~/avd-landing-zone; git pull -q --ff-only
./scripts/ops/Initialize-AvdRunStore.ps1 -WhatIf          # where records and logs are kept; drop -WhatIf to create it
./scripts/ops/Set-AvdSpendBudget.ps1 -Amount 150 -Email you@contoso.com -WhatIf
```

Set your caps once per Cloud Shell session, or pass `-MonthlyCap` and `-RunCap` each time. With no cap set, every run is refused.

```powershell
$env:SPEND_MONTHLY_CAP = '150'; $env:SPEND_RUN_CAP = '25'; $env:SPEND_DEFAULT_REGION = 'northcentralus'
```

## Where records live

Cloud Shell's home folder is not a durable copy: an ephemeral session loses it, and `~/clouddrive` exists only when storage is mounted. So the records (spend runs, batches, approvals, group results) live in the run store's `records` container, set up by `Initialize-AvdRunStore.ps1` and outside every landing zone, so cleanup never removes it. Each script pulls the records into a local folder first (`~/clouddrive/avd-runs`, else `~/avd-runs`) and pushes what it changed with a conditional write: if another Cloud Shell wrote the same file first, the push stops with the file named instead of overwriting it. Nothing deletes a record.

`-Local` keeps records on this disk only, for a first try or a subscription with no run store. Every script that writes says so, and the close of a spend run marks its record as the only copy. A group that keeps private output refuses to run with `-Local`.

## One run, by hand

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }
Set-Location ~/avd-landing-zone; git pull -q --ff-only
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment *>&1 | Tee-Object ~/preflight.txt
./scripts/ops/Start-AvdSpendRun.ps1 -Sandbox lab -Purpose 'FSLogix retest' -Hours 3 -PreflightOutput ~/preflight.txt
```

Deploy, test and tear down as usual, then:

```powershell
Set-Location ~/avd-landing-zone
./scripts/ops/Stop-AvdSpendRun.ps1 -Sandbox lab
```

One run per sandbox is open at a time, so each run's cost and teardown stay separate. Cost Management settles in about three days; the estimate's error from earlier runs of the same kind (the median of actual over estimate) is applied to the cap check once three runs have settled.

## Batches

### Queue items

An item is one test you want run. Write it as a JSON file in a folder (no GitHub needed), or as an issue from a "Sandbox run" issue form labeled `sandbox-run` and `queue:ready` (`-Repo owner/repo`, with the GitHub CLI signed in).

```json
{
  "schema": "sandbox-run/v1",
  "number": 12,
  "purpose": "Profile share round trip",
  "source": "contoso/lab-tests@0123456789abcdef0123456789abcdef01234567",
  "tests": "The profile mounts and survives a sign-out",
  "kind": "avd",
  "sandbox": "lab",
  "region": "northcentralus",
  "shape": "dev landing zone, 1 x D2as_v5",
  "deploymentKey": "lz-dev-1xD2as",
  "ratePerHour": 0.43,
  "hours": 3,
  "hoursWhenSharing": 1,
  "estimateNote": "Retail prices, 2026-10-21",
  "unattended": false,
  "deploy": "./scripts/deploy/deploy.sh --env dev",
  "test": "pwsh -File ./tests/Profile.ps1",
  "teardown": "pwsh -File ./scripts/ops/Remove-AvdDemo.ps1 -IncludeLandingZone -Force -DiscardLastCopy",
  "evidence": "Spend record and test output"
}
```

- `source` is `owner/repo@<40-hex commit>` (needs nothing else), or `owner/repo#<PR>` or a short commit (needs the GitHub CLI, or `-PinsPath` offline). The batch pins every item to a full commit, so the approval covers exactly that code.
- Items with the same `deploymentKey` share one deployment: the item with the most hours leads (deploys and tears down), the others add their `hoursWhenSharing`.
- `deploy`, `test` and `teardown` are bash, run from the item's checkout. Steps must be safe to run twice (`-Resume` runs an interrupted step again).
- Optional: `regionReason` (required when `region` isn't `SPEND_DEFAULT_REGION`), `fixedCost`, `record` (a parameter file and flags for the run recorder, below), `keep` (paths to keep before teardown), `dependsOn` (items or PRs that must be merged first).
- No GUIDs, email addresses or tenant domains in an item: an approved batch freezes its text, and these are refused. Have the step read them from a variable at run time.

### Build, approve, run

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }
Set-Location ~/avd-landing-zone; git pull -q --ff-only
./scripts/ops/New-AvdSandboxBatch.ps1 -ItemsPath ~/clouddrive/queue -MonthlyCap 150 -RunCap 25
```

Read `batch.md` (the script prints it): the groups, their estimates, the pinned commits and one Cloud Shell block per step. Then the person who pays approves it, by typing the phrase when asked:

```powershell
Set-Location ~/avd-landing-zone
./scripts/ops/Approve-AvdSandboxBatch.ps1 -BatchId b20261021-1700
```

And runs each group in order, one block per group:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }
Set-Location ~/avd-landing-zone; git pull -q --ff-only
./scripts/ops/Invoke-AvdSandboxBatch.ps1 -BatchId b20261021-1700 -Group G1 -MonthlyCap 150 -RunCap 25
```

Exit 0: closed clean and every test passed. Exit 3: closed clean with a failed test or deploy; the next group may run. Exit 2: stop the batch (the spend run didn't open, the close found leftovers, the deadline passed, output couldn't be kept, or it refused to start); deal with the reason before the next group.

### When Cloud Shell drops

Cloud Shell ends a session after about 20 minutes without input, and a group can take hours. The group's results are written to the records before and after every step, so in a new session:

```powershell
if (-not (Test-Path ~/avd-landing-zone)) { git clone https://github.com/avd-ops/avd-landing-zone.git $HOME/avd-landing-zone }
Set-Location ~/avd-landing-zone; git pull -q --ff-only
./scripts/ops/Get-AvdSandboxBatchStatus.ps1
```

It prints the block to continue. `-Resume` skips the steps that finished and runs the interrupted one again. `-TeardownOnly` keeps, tears down and closes instead. A group never starts a second time on the same approval: running it again needs a new batch and a new go. Keep the session alive during long steps (type in it now and then), or run from the [operator jumpbox](operations.md#operator-jumpbox).

### Recorded groups and kept output

An item with `record` (for example `parameters/dev.bicepparam -NamePrefix lab1`) makes its group a recorded run ([run recorder spec](../build/specs/run-recorder-spec.md)): the recorder opens the run before anything is spent and refuses past the approved estimate plus 10%, every step writes to the run's journal, the AVD logs are exported before teardown deletes the workspace, and the run is closed after. The recorder is this checkout's own commit, pinned in the batch; `New-AvdSandboxBatch.ps1` refuses when `scripts/` has local changes. Set `AVD_PRIVATE_REPO` to copy the run to your private companion repo.

An item's `keep` paths are packed, copied to the run store (`runs/queue/<batch>/<group>/<item>/`), read back and compared by SHA-256 before teardown. A failed copy never holds up teardown, but it stops the batch.

## Running batches from your own CI

The scripts don't need Cloud Shell; they need a signed-in Az PowerShell session, bash and git. To run unattended groups from a CI system:
- Check out this repo at a pinned commit and call the same scripts; pass `-RequireUnattended` so a group that needs a person is refused.
- Sign in with a federated credential (OIDC), never a stored secret, with the least role that can deploy and tear down in the sandbox.
- Read the approval from storage the runner's own identity can't write (`-ApprovalPath`): for example a protected branch only an approval job can push to, after a reviewer approves a protected environment. An approval the runner could write itself is no approval. Record it with `Approve-AvdSandboxBatch.ps1 -Via environment`.
- Keep the records in the run store as above, so a Cloud Shell session sees what the runner did and can take over with `-Resume` or `-TeardownOnly`.

A model or an agent may build and price a batch. It never types the go.

## Limits

- Item steps are bash: Cloud Shell, Linux or macOS. Windows runs the PowerShell scripts but not the item steps.
- The estimate is retail list price, not your agreement's price; calibration closes part of the gap.
- Teardown evidence is a Resource Graph inventory diff: it sees resources and resource groups, not data written outside the subscription.
