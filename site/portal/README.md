# Deployment portal

[`index.html`](index.html) is a static page (GitHub Pages: <https://nickprignano.github.io/avd-landing-zone/portal/>, or a copy in your own subscription from [`Publish-AvdPortal.ps1`](../../docs/operations.md#your-own-copy-of-the-portal-optional), [decision 0017](../../build/decisions/0017-portal-hosting.md)) that walks an operator through a deployment:

1. **Choose a region.** Latency measured from the browser; the closest region is selected.
2. **Size the host pool.** Starts at the minimum viable kit (one E4as_v5 host). You choose the number of hosts, or Automatic sizes it from people and workload; the commands then carry the sizing ([decision 0010](../../build/decisions/0010-sizing-and-cost.md)).
3. **Cost.** Toggles for Start VM on Connect and the scheduled auto shutdown, and the hours people work. Together they give the hours each host runs. The commands deploy the settings, the preflight prices the plan, and after that the toggles reprice it in the page (`repriceEstimate`).
4. **Pre-deployment preflight.**
5. **Deploy the landing zone.**
6. **Post-deployment setup.**
7. **Sign in** (and optionally the demo host pool).
8. **Verify access.** From the operator's own device ([decision 0014](../../build/decisions/0014-verify-access.md)):
   - a reachability probe to the AVD sign-in and client hosts, timed like the latency step. It's a warning, never a stop, and the page says what it doesn't prove;
   - a direct link to the desktop in the web client, built from the workspace and desktop object IDs the post-deployment setup or the demo reports (`launchUrl`). The IDs must be GUIDs and the link always points at `windows.cloud.microsoft`. There's no Windows App (`ms-avd:`) link yet: Microsoft's URI scheme page lists `user` in its parameter table but `username` in its example, so the names aren't confirmed (TODO, [verify-access-spec.md](../../build/specs/verify-access-spec.md) §6.3).

   - confirmation from telemetry: the step's command runs `Test-AvdUserConnection.ps1`, and a pasted result shows *Verified*, *Failed* or *Not verified* with what to do next. Only *Verified* is a pass. Error codes get specific guidance only once a real run shows them (`decide`, stage `verify`); until then the portal shows the code, the message and whether AVD marked it a service error.

The steps sit side by side and scroll horizontally (swipe, trackpad, or Back and Next); a step stays hidden until the deployment reaches it, so the page opens on the latency check. A pasted output moves to the step it leads to. Next skips a step without running it, for an operator who did it earlier or elsewhere.

At each step it gives a self-contained Cloud Shell block (clone or update the repo, move into it, run the command). The operator pastes the output back and the portal works out what happened and what to run next. The **Deployment settings** link in the header opens the settings the commands use (parameter file, region, groups, name prefix, environment, test user) and *Start over*. It keeps progress and settings in the browser's local storage. **Secrets in pasted output are masked as you paste** (`maskSecrets` in [`report.js`](report.js): tokens, keys, SAS signatures, passwords, device codes, Static Web Apps deployment tokens), before the text is drawn or read, so they are never on screen, in the analysis or in a report; IDs and names stay because the analysis needs them. **Pasted output is never sent anywhere**: apart from the page's own files (scripts, and the [avd-ops design system](https://github.com/nickprignano/avd-ops/blob/main/docs/design-system.md) vendored in [`../assets/`](../assets/): its stylesheet, logo slot and fonts, under the SIL Open Font License), the only network requests are the latency test's and the reachability probe's (`no-cors`, no credentials, no referrer). A test keeps it that way.

**Report a problem** opens a GitHub issue with the pasted output and the portal's analysis. [`report.js`](report.js) redacts it in the browser first (decision [0008](../../build/decisions/0008-portal-issue-reports.md)). The reporter reviews it and submits it on GitHub.

The logic lives in [`portal-core.js`](portal-core.js), which runs in the browser and in Node, so it is tested against real Cloud Shell output: `node --test "build/tests/portal/*.test.mjs"` (CI job *Deployment portal tests*).

## The state line

Every script ends its run with one line the portal reads (anything around it is ignored; if a terminal copy breaks the line, the portal rejoins it):

```
<<<AVDLZ-STATE {"v":1,"stage":"predeploy","status":"notready",...} AVDLZ-STATE>>>
```

Written by `Write-AvdPortalState` (PowerShell scripts) and `portal_state` (`deploy.sh`).

| Field | Meaning |
|---|---|
| `v` | Schema version (1). |
| `stage` | `predeploy`, `deploy`, `postdeploy`, `demo`, `cleanup`, `verify` (`Test-AvdUserConnection.ps1`) `resume` (`Get-AvdRunStatus.ps1`, where did I leave off) `recovery` (`Get-AvdRecoveryStatus.ps1` and `Start-AvdRecoveryTest.ps1`, [recovery spec](../../build/specs/recovery-spec.md)) or `rotation` (`Invoke-AvdHostRotation.ps1`, [image pipeline spec](../../build/specs/image-pipeline-spec.md) section 6.5; status `refused`, `waiting`, `done` or `failed`). |
| `status` | `ready` / `notready` (preflight, demo, cleanup); `started` / `succeeded` / `failed` / `whatif` (`deploy.sh`); `verified` / `failed` / `notverified` (`verify`: only `verified` is a pass); `ready` / `unknown` (`resume`: `unknown` means it couldn't tell, never a guess); `met` / `notmet` (`recovery` status check), and for a recovery test `ready` / `notready` (plan), `passed` / `failed` (`-Go`) and `done` (`-Cleanup`). A deployment prints `started` before it begins, so output cut off by a disconnect still says what is running. |
| `fix` | Whether the run used `-Fix`. |
| `context` | What the next command needs: `parameterFile`, `location`, `usersGroup`, `adminsGroup`, `namePrefix`, `environment`, `deploymentName`, `storageAccount`, `testUserUpn`, `workspace`, `includeLandingZone`, `wellArchitected`, `sizing` (`hosts`, `vmSize`, `maxSessions`, `profileQuotaGiB`, `activeHoursPerWeek`: the sizing a preflight or `deploy.sh` was given), `power` (`autoShutdownTime`: `HH:mm` or `none`, `startVmOnConnect`: the power settings a preflight or `deploy.sh` was given), `estimate` (`currency`, `location`, `total`, `alwaysOnTotal`, `lines[]` with `key`, `item`, `quantity`, `unit`, `unitPrice`, `monthly`, `meter`; `unpriced[]` with the meters seen; `excluded[]`), `launch` (post-deployment and demo: `workspaceObjectId`, `desktopObjectId`, `tenantId`, `workspace`, `appGroup`: what the Verify access step's direct launch link needs; left out when an ID is missing), for `resume`: `lastStage`, `lastStatus` (`running`, `failed`, `succeeded`), `nextStage` (`predeploy`, `deploy`, `postdeploy`, `signin`, `verify`), `basis` (what Azure showed); for `recovery`: `tier`, `met`, `total`, `recoveryLocation`, and for a recovery test `test`, `mode` (`plan`, `go`, `cleanup`), `runId`; for `rotation`: `from`, `to`, `version`, `rollback`, `phase`, `sessionsLeft`, `rollbackPending` (a rollback waiting for the deployment to end: the next command is the rollback again); and for `verify`: `user`, `windowMinutes`, `resourceGroup`, `demo`, `waitedSeconds`, `connections[]` (`correlationId`, `startedAt`, `connectedAt`, `completedAt`, `connectionSetupSeconds`, `sessionHost`, `clientType`, `clientOS`, `gatewayRegion`, `transportType`, `errors[]` with `code`, `message`, `source`, `serviceError`, `checkpoints[]`; the latest 5) (whichever apply). |
| `counts` | `pass`, `fail`, `warn`, `fixed`, `skip`. |
| `failures`, `warnings` | `{ id, area, check, detail, remediation, data }` for each. `id` is set where the portal needs to recognize the check: `quota` (data: `location`, `quotaName`, `limit`, `used`, `needed`), `hostpool-region` (`regions`), `lz-region` (`deployedIn`), `lz-missing` (`found`), `kv-softdeleted` (`vaults`), `smb-channel` (`channelEncryption`: the profile share needs a deployment to allow AES-128-GCM), `devices-left` (`devices`: a cleanup warning when the Graph step did not finish), `registering`, the access check's `connect-errors` (`codes`, `serviceError`), `no-connection`, `in-progress`, `query-failed` (`status`: the HTTP status), `no-landing-zone` and `security-defaults` (a warning in both preflights: the portal adds a decision step and never blocks on it), and `waf-<check>` for the Well-Architected review (`pillar`, and `accepted` when the parameter file makes that trade-off on purpose). |

Add fields; don't rename or remove them without bumping `v` and keeping the old reading in `portal-core.js`.

## Issue reports

`report.js` builds the report and redacts it:

| Removed | Placeholder |
|---|---|
| Tokens, keys, SAS signatures, passwords, device codes | `<token>`, `<secret>`, `<device-code>` |
| Email addresses and UPNs (guests too), their domains, `*.onmicrosoft.com` tenant names | `<email-N>`, `<domain-N>`, `<tenant-N>` |
| Subscription names, storage account and key vault names | `<subscription-N>`, `<storage-N>`, `<vault-N>` |
| GUIDs, except the ones in `PUBLIC_IDS` (the same in every tenant) | `<id-N>` |
| Public IPv4 addresses (private ranges stay) | `<ip-N>` |
| The user name in `/home/...` and `C:\Users\...` | `<user-N>` |
| Name prefix, group names, test user and storage account from the settings or the state line; terms the reporter adds | `<name-N>`, `<custom-N>` |

The same value always gets the same placeholder. Reports carry `<!-- avdlz-portal-report v1 -->`, and `.github/workflows/portal-report.yml` labels them `portal-report`.

**Triage:** a report whose analysis is wrong is a fixture waiting to happen. The retro routine applies. Check the output for anything private the patterns missed, then save it to `build/tests/portal/fixtures/`.

## Sizing

`portal-core.js` keeps sizing per host pool: `HOST_POOL_DEFAULTS` describes one entry (name, type, users, `concurrencyPercent`, workload, `vmSize`, `hostCount` (a number, or `'auto'`), `spareHost` (Automatic only), `profileGiBPerUser`, `activeHoursPerWeek`), `computePool()` sizes it, and `toSizing()` turns the result into the object the commands use. The page stores a list (`avdlz.portal.hostPools`) with one entry while `MAX_HOST_POOLS` is 1. To add host pools: raise the limit, give each entry its own commands, and extend the templates. The single-pool commands don't change.

## Reachability probe

`REACHABILITY_HOSTS` in `portal-core.js` lists the probed hosts: concrete names from Microsoft's [required endpoints for end-user devices](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint). Most of that list is wildcards, which a browser can't probe. `classifyReachability()` turns the page's medians into `reachable`, `partial`, `blocked` or `unknown`. Only every host reached is `reachable`, and an untested host never counts as reached. A resolved `no-cors` request means DNS, a connection and TLS succeeded. It says nothing about sign-in, the feed and gateway hosts, UDP or the session host, and a proxy's block page also resolves. The page shows that text (`limits`) beside the result.

## Changing it

- **A script's output or parameters change:** run the portal tests. One of them checks that every parameter the portal puts in a command exists in the script.
- **A real paste is analyzed wrongly:** add it (redacted) to `build/tests/portal/fixtures/`, add a test, then fix `portal-core.js`. This is the retro routine (`.claude/skills/retro`).
- **A new kind of private value turns up in a report:** add it to `fixtures/pii-sample.txt` and to the `PRIVATE` list in `build/tests/portal/report.test.mjs`, then add the pattern to `report.js`. A new GUID in `bicep/` or `scripts/` must go into `PUBLIC_IDS`, and a test checks this.
- **A new known error:** add it to `ARM_ERRORS` (deployment errors) or `shellProblems` (errors before a script can report) in `portal-core.js`, with a fixture.

## A published copy

[`portal-config.js`](portal-config.js) is empty here. `Publish-AvdPortal.ps1` rewrites it in the copy it publishes, as one object on `window.AVDLZ_PORTAL_CONFIG`:

| Key | Meaning |
|---|---|
| `repoUrl` | The repo the commands clone. Only `https://github.com/<owner>/<repo>`; anything else is ignored and the page says so. |
| `ref` | The tag or commit the commands check out (an existing clone is pointed at `repoUrl` first). Without it, the commands follow `master`. |
| `portalUrl`, `hosting` | Where the copy is served and how (`StaticWebApp` or `Storage`), for reference. |

The page shows which repo and ref its commands run, under the command blocks.
