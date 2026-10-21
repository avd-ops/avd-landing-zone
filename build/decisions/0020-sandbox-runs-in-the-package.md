# 0020. Sandbox runs (spend gate, batches, records) ship with the landing zone and run from Cloud Shell

- **Status:** Proposed

## Context
The landing zone already treats Azure Cloud Shell as its runtime: the operator scripts, the state line the portal reads, the run recorder and its run store (`build/specs/run-recorder-spec.md`). What it didn't have was the method used to test it safely: a cost estimate and a cap check before anything is deployed, a person's go at an exact total, one deployment shared by tests that can share it, and proof afterwards that nothing was left billing. That method was built and proven in a private operations repo, driven by GitHub Actions, and was only partly usable from Cloud Shell.

Three things argued for moving it here:
- It is how anyone testing this landing zone avoids surprise bills, and it depends on nothing private: Az PowerShell, Resource Graph, Cost Management and a storage account.
- The family's rules already assume it: never leave the meter running (avd-second-brain decision 0017) and never delete the last copy (decision 0016).
- An operator on a tablet has only Cloud Shell. A method that needs a CI runner, a protected environment and a repo's secrets leaves them out.

A red team of the move found the gaps that a Cloud Shell-first version must close: Cloud Shell ends idle sessions after about 20 minutes and its home folder is not a durable copy; two shells can write the same record; an approval a runner can write itself is no approval; a group restarted on the same approval spends its estimate twice; and the private repo's tests and comments named a real person and sandbox.

## Decision
- **The scripts live in `scripts/ops/`** with the other operator scripts and the same rules: pure functions in `AvdSpend.psm1` and `AvdSandboxBatch.psm1`, tested offline (`build/tests/SandboxRuns.Tests.ps1`, the `SandboxBatch` offline scenario with Resource Graph, Cost Management and budget routes in `AzMock.psm1`); the entry-point notice; American English; values in tests are contoso and neutral. Operator guide: `docs/sandbox-runs.md`.
- **Records live in the run store**, in a second container, `records`, beside `runs` (`bicep/recorder/store.bicep`; run recorder spec section 6.3). No lifecycle rule covers it and nothing deletes from it. The scripts work in a local folder that is a cache: pulled first, pushed with conditional writes (If-Match on the last ETag seen, If-None-Match for a new file), so a second writer gets a conflict with the file named instead of overwriting it. `-Local` keeps records on Cloud Shell's disk only, says so at every write, and marks a closed run's record as the only copy.
- **Each group runs once per approval.** Results are written before and after every step. `-Resume` replays the steps that finished and runs the interrupted one again; `-TeardownOnly` keeps, tears down and closes. The first write of a group's results is the claim: conditional on the file being new in the store, so a second shell starting the same group stops before spending. A group doesn't start while an earlier group of the batch stopped part way or stopped the batch (until `-ContinueAfterStop`).
- **A person approves, by typing.** `Approve-AvdSandboxBatch.ps1` asks for `go batch <id> $<total>`, checks it against the batch and binds the approval to the batch's SHA-256 hash; any change voids it. The v1 hash and canonical form are frozen (a golden test). A model or agent may build and price a batch, never approve it. An unattended runner reads its approval from storage its own identity can't write (`-ApprovalPath`), and refuses groups that need a person (`-RequireUnattended`).
- **Recorded groups use this checkout's own commit as the run recorder**, pinned in the batch, so the approval covers it; building a batch refuses when `scripts/` has local changes.
- **Nothing deletes automatically.** Leftovers stop the batch and keep the spend run open until a person clears them; a later run in that sandbox is refused until then.
- **Not in the package:** reconciling the monthly bill, and any one CI system's wiring. A CI system that runs batches calls these scripts at a pinned commit (`docs/sandbox-runs.md`, "Running batches from your own CI").
- **Blocks that run from either shell.** The generated batch page and the status script print one line per step, `pwsh -NoLogo -Command '...'`, which runs the same from Cloud Shell's PowerShell or Bash prompt.

## Consequences
- Anyone can test the landing zone in their own subscription with a cost gate and teardown evidence, from a browser.
- The landing zone stays self-contained: nothing here needs the brain, the swarm or a private repo. Item steps are bash, so the batch runner needs Cloud Shell, Linux or macOS.
- The run store becomes the first thing to set up for batches that keep output or record runs; a batch on `-Local` records is for a first try.
- Two copies of the method exist until the earlier CI wiring switches to these scripts; batches already approved there finish on the old path first.
- Estimates are retail list prices; calibration from settled runs closes part of the gap, and the gate checks the calibrated figure once three runs have settled.
