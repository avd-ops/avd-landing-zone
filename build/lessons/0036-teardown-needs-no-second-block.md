# 0036. A teardown that waits for a second block, run by hand, isn't part of the batch

- **Area:** Sandbox runs
- **Found in / fixed by:** a sandbox batch group (2026-10-22) / decision 0021

## What happened
A sandbox batch group stopped part way on a script error. The spend run stayed open, and the group was closed only after the operator ran a second block by hand, the same command with `-TeardownOnly`, as the runner's message told them to. Nothing tore it down on its own. Had the operator been offline, it would have kept billing until they came back.

## Why
Every step caught its own errors, and decision 0020's rule (every path that deployed anything goes through teardown and close) held for the paths the runner reached. Two kinds of stop never reached them:
- an error in the runner's own code between steps;
- the shell itself going away: Cloud Shell's idle timeout, a dropped browser, a closed tablet.

`-Resume` and `-TeardownOnly` were the safety net, and both needed a person to come back and run them.

## Fix
Decision 0021:
- the runner runs from the spend run's opening to its close inside `try`/`catch`/`finally`, and tears down on any stop it sees;
- a deadline teardown, armed in the run store's Automation account before the group claims anything, tears the group down when no shell is left to;
- the next group's block closes an earlier group whose runner is gone.

## Guard
- Offline scenario `SandboxDeadline`:
  - `crash`: the runner stops on an error, then tears down, closes and disarms;
  - `no-runbook` and `arm-fails`: refused before the claim;
  - `runbook-closed`, `runbook-dead` and `runbook-deallocate`: what the runbook does in each case;
  - `g3`: the next block closes the dead group.
- Pester `Deadline teardown (decision 0021)`.
- Template test: the role's four actions.

## Rule
Anything that bills must be torn down by something that doesn't depend on the operator's shell staying open. "Run this again with `-TeardownOnly`" is a fallback, never the plan.
