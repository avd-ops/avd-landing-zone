# 0007. The deployment portal reads a state line from the scripts, in the browser only

- **Status:** Accepted

## Context
Operators run each step in Azure Cloud Shell and need to know what to run next. The output was written for people: its layout changes as checks are added, and a terminal copy can reflow it. It also contains tenant details (UPNs, IDs, resource names). Real runs showed that the problems between steps are predictable: fix mode, quota, the wrong folder in a new session, a disconnect mid-deployment, a Graph sign-in, a known ARM error.

## Decision
- **State line:** every script ends with one machine-readable line, `<<<AVDLZ-STATE {json} AVDLZ-STATE>>>` (schema in [`site/portal/README.md`](../../site/portal/README.md)). Checks the portal must recognize carry a stable `id` and structured `data`. `deploy.sh` prints `started` before deploying, so output cut off by a disconnect still identifies the deployment.
- **Portal:** a static page with the engine in `site/portal/portal-core.js`. It turns the last state line into the next self-contained Cloud Shell block. It falls back to recognizing older output and errors that stop a script before it can report.
- **Privacy:** pasted output is analyzed in the browser and never sent anywhere.

## Consequences
- The contract is explicit and versioned, so the page doesn't break when the human-readable output changes.
- The engine is unit-tested in Node against redacted real output. A drift test keeps the portal's commands in line with the scripts' parameters.
- There is no server to run or secure.
- Adding a recognized failure means an `id` in the script, a branch in `portal-core.js` and a fixture.
