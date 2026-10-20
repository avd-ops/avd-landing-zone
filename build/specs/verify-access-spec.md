# Spec: verify access from the operator's device

- **Status:** Proposed. The owner agreed with every proposal in §12 (2026-10-05); Track A (Phases A1–A3) is built. Decision [0014](../decisions/0014-verify-access.md). An optional computer-use agent (Track B) was designed and red-teamed alongside it; it is not part of this repo any more, and its sections, facts, questions and phases are left out below.
- **Date:** 2026-10-05
- **Scope:** landing zones built from this repo. Track A changes the deployment portal and the ops scripts, not the deployed resources.

This is a personal project, not for production, provided as is. Nothing here has run against a real tenant yet. §11 lists every fact this spec relies on, how it was checked, and what is still unverified.

## 1. Summary

After a deployment the portal says "sign in to the desktop" and stops. Nothing confirms that the operator's device can reach AVD, that the right person can get the right desktop, or that a connection actually happened. This spec adds one track.

- **Track A, *Verify access* (the default path).** A new portal step after *Sign in* has three layers, run from the operator's own device and signed in as themselves:
  1. **Reachability:** a browser probe to concrete AVD client hostnames.
  2. **Launch:** a direct web client link to this landing zone's desktop, built from IDs the post-deployment run reports.
  3. **Confirmation:** a Cloud Shell script that reads `WVDConnections`, `WVDErrors` and `WVDCheckpoints` for that user and reports *verified*, *failed* or *not verified*.

  No test account, no stored credentials, no new Azure resources.


## 2. Goals and non-goals

### Goals
1. An operator can tell, from their own device, whether AVD is reachable, can open the desktop in one click, and gets an objective answer from Azure telemetry about whether a connection was made.
2. Each layer says exactly what it proves and what it doesn't. No layer claims more than it measured.
3. The default deployment is unchanged: no new resources, no added deploy time, no new required parameters. The 30-minute desktop stays 30 minutes.

### Non-goals
- **Proving the user experience.** None of this measures input delay, frame rate or "the desktop felt fast". AVD Insights and `WVDConnectionNetworkData` already cover that.
- **Testing every network a user might be on.** Track A tests the operator's network now.
- **Load testing.**
- **A server for the portal.** The portal stays a static page (decision 0007).

## 3. Principles

| # | Principle | Source |
|---|---|---|
| V1 | Fail closed: a missing row, a timeout or an unknown state is *not verified*, never a pass | the brief; lesson 0021 (ARM omits empty properties) |
| V2 | Name each metric for what it measures. Started→Connected is *connection setup time*, not time to a usable desktop | AVD Insights' "time to connect" includes logon (§11) |
| V3 | Nothing pasted or measured leaves the browser | decisions 0007, 0008 |
| V4 | Prefer REST where a cmdlet reshapes or blocks | decision 0002; the cmdlet help doesn't document `ObjectId` (§11) |
| V5 | Default deployment unchanged | the brief; scope creep risk |
| V6 | Every new state the portal recognizes gets an `id`, a branch in `portal-core.js`, a Node test and an offline scenario | decision 0007, CLAUDE.md |

---

# Track A: Verify access

## 4. What each layer proves

| Layer | Proves | Doesn't prove |
|---|---|---|
| A1 Reachability probe | This browser, on this network, completed DNS, TCP and TLS to each probed host, and got *some* HTTP response | Sign-in, authorization, the feed, the host pool, the RDP gateway path, UDP (RDP Shortpath, TURN on 3478), or anything about the session host. A proxy that answers with its own block page also counts as "reached" (§5.3) |
| A2 Launch link | The operator can open this landing zone's desktop in the web client with one click, as the account they choose | On its own, nothing: the person reads the result on screen. Layer A3 makes it objective |
| A3 Telemetry confirmation | The AVD service recorded a connection by *this user* to *this host pool* that reached `Connected`, in the time window, with its errors and checkpoints | That the desktop was usable, the profile loaded, apps worked, or that the next user will succeed. That the *operator's device* made the connection (the user name and client type are reported, so the operator can judge) |

The portal shows this table, shortened, next to the results.

## 5. Phase A1: reachability probe in the portal

### 5.1 Method
It reuses the latency step's method (decision 0003): one warm-up request, then 5 timed `fetch` calls with `mode: 'no-cors'`, `cache: 'no-store'`, `credentials: 'omit'`, `referrerPolicy: 'no-referrer'`, a 4-second timeout each, and the median.
- **Resolves:** the endpoint was reachable over the network.
- **Rejects or times out:** DNS failure, TLS failure (including TLS inspection with an untrusted certificate), a TCP block, or a content blocker.

`no-cors` responses are opaque, so the status code can't be read. That limit is the reason for the wording in §4.

### 5.2 Targets
Microsoft's required-endpoint list for end-user devices is mostly wildcards, which can't be probed. Concrete hosts only:

| Host | Why | Confirmed |
|---|---|---|
| `login.microsoftonline.com` | Entra ID sign-in, for every client | In the end-user FQDN list ("Authentication to Microsoft Online Services"; §11 A1) |
| `windows.cloud.microsoft` | The web client and Windows App service | In the same list ("Connection center"); also the web client's direct launch host (§11 A2) |
| `go.microsoft.com`, `aka.ms` | Client update and help links | In the same list. **Not probed:** a failure here doesn't stop a connection, and a warning would be noise |

`*.wvd.microsoft.com` (feed, broker, gateway) is the most important wildcard. The probe can't reach it without a concrete host. Older docs name `rdweb.wvd.microsoft.com` and `client.wvd.microsoft.com`; the current list (read 2026-10-06) names neither, only the wildcard (§11 A1). **Open question Q1:** probe them as *informational, unconfirmed*, or leave them out (proposed: leave out).

### 5.3 Classification (`portal-core.js`, Node-tested)
`classifyReachability(results)` takes `[{ host, median|null, error }]` and returns `{ status, hosts[], guidance }`:

| Status | When | Shown as |
|---|---|---|
| `reachable` | Every required host resolved | "Reachable" with the median, rated with the latency step's labels (Good/Usable/Sluggish) only as context |
| `partial` | Some resolved, some didn't | Warning naming the failed hosts |
| `blocked` | None resolved | Warning: "a firewall, proxy, DNS filter or content blocker is stopping requests to AVD" |
| `unknown` | Probe not run, or the browser lacks `fetch`/`AbortController` | Neutral |

It's a **warning, never a hard stop**. The operator can always continue. The copy says what §4 says, including that a corporate proxy answering with a block page looks reachable, and that UDP and the gateway aren't tested.

### 5.4 Privacy
- The probe's only requests go to the listed Microsoft hosts, as the latency step's do.
- Results are kept in the page's memory, with only a summary in local storage, and are never sent anywhere.
- The `site/portal/README.md` sentence "the only network requests are the latency test's" becomes "the latency test's and the reachability probe's".

## 6. Phase A2: launch link from deployment output

### 6.1 State line additions (backward compatible)
The post-deployment run (`Test-AvdLandingZoneReadiness.ps1` without `-PreDeployment`) adds `context.launch` when the control plane exists:

```json
"launch": { "workspaceObjectId": "<guid>", "desktopObjectId": "<guid>", "tenantId": "<guid>", "workspace": "vdws-…", "appGroup": "vdag-…" }
```

- **Where the IDs come from:** read through REST (`Invoke-AvdArm`, decision 0002), not `Get-AzWvdWorkspace`/`Get-AzWvdDesktop`. The read-only `properties.objectId` exists on workspaces and on `applicationGroups/desktops` in the API spec and in Bicep's types at `2024-04-03`. The cmdlets do output `ObjectId` (Microsoft's object ID and direct launch pages use it, §11 A2c), but REST keeps the readiness script on one code path.
- **New fetch:** `Get-AvdLandingZone` already fetches the host pool and app group. It gains the workspace and the desktop (`…/applicationGroups/<ag>/desktops`).
- **Missing values:** each ID is counted with `@($x | Where-Object { $_ })` (lesson 0021). A missing ID omits `launch`, and the portal falls back to the plain `https://windows.cloud.microsoft` link.
- **Schema version:** `v` stays 1, because the field is added, not renamed.

The demo run (`Deploy-AvdDemo.ps1`) gets the same field for the demo workspace.

### 6.2 The link
`portal-core.js` builds it with `launchUrl(launch, { tenant, loginHint })`:

```
https://windows.cloud.microsoft/webclient/avd/<workspaceObjectId>/<desktopObjectId>[?tenant=<tenantId>][#loginHint=<UPN>]
```

- **`#loginHint`** comes last, as the docs require. It's filled from the portal's test user setting when set, and is otherwise empty.
- **`?tenant=`** is documented for external identities, so it's off by default. A checkbox adds it for a guest account.
- **IDs are validated as GUIDs before use.** A pasted state line is untrusted input, so the link can only ever point at `windows.cloud.microsoft`.
- **Confirmed:** the path, the `tenant` and `loginHint` parameters and the "fragment last" rule are read from the live direct-launch URLs page (§11 A2), and a Node test reproduces the page's fully formatted example. Building it from the API's `objectId` is confirmed. A real sign-in is still the owner's first run.

### 6.3 Windows App link (`ms-avd:connect`): TODO, not shipped
- The live URI scheme page (§11 A3) says, in its parameter table, that Windows App 2.0.804.0 and later supports `ms-avd:connect` with `resourceid` (required), `user` (required) and `usemultimon` (optional), and that `workspaceid`, `env`, `version`, `launchpartnerid` and `peeractivityid` are **not supported in Windows App**.
- The same page's only example still uses `workspaceId=…&resourceid=…&username=…&version=0`, which contradicts its own table (`username` vs `user`, and two parameters Windows App doesn't support). The parameter names are therefore not confirmed verbatim.
- Proposed link, once a real Windows App run confirms it: `ms-avd:connect?resourceid=<desktopObjectId>&user=<UPN>`.
- Per the brief, only the web link ships. The `ms-avd:` link is documented as a TODO in `site/portal/README.md`, to be added when the parameters are confirmed from the live page or a real Windows App run.
- The page still tells the operator to open the Windows App and choose the same desktop, which tests the real RDP client path by hand.

### 6.4 What to expect, and who is assigned

| Topic | Guidance |
|---|---|
| **Who can sign in** | The deployment assigns **Desktop Virtualization User on the desktop app group** and **Virtual Machine User Login on the hosts resource group** to `AVD_USERS_GROUP_ID` (`controlPlane.bicep`, `main.bicep`). The pre-deployment `-Fix` adds the operator to that group (`Add-AvdCallerToGroup`). With `-TestUserUpn`, the post-deployment run checks the test user's membership. The portal names the group and repeats that new memberships can take up to an hour to reach the token. **Nothing is missing.** The guidance only names the group, it doesn't add an assignment step |
| **Consent prompt** | Microsoft Entra SSO (`enablerdsaadauth:i:1`, set by default here) shows a one-time "Allow remote desktop connection" prompt for each new session host. Entra remembers up to 15 hosts for 30 days. Fresh deployments are exactly when it appears. **Expected; choose Yes** |
| **Trusted devices** | The prompt can be hidden by adding Entra device groups holding the session hosts as `targetDeviceGroups` on the *Windows Cloud Login* service principal's `remoteDesktopSecurityConfiguration`. That's a Microsoft Graph call (max 10 groups, permission `Application-RemoteDesktopConfig.ReadWrite.All`), so Bicep can't set it, and the hosts would need a device group. Documented as an option, not built (**Q2**) |
| **Cold start** | Start VM on Connect and the scaling plan mean the first connection may wait for a deallocated host to boot. The portal says so before the operator clicks, and A3 marks a first connection after a start as "not steady state" (§6.5) |

### 6.5 Phase A3: confirmation from telemetry

**Diagnostics are already on, at no new cost.**
- `controlPlane.bicep` passes `diagnosticSettings: [{ workspaceResourceId }]` to the AVM host pool, application group and workspace modules.
- Those modules default `logCategoriesAndGroups` to `[{ categoryGroup: 'allLogs' }]`. That's confirmed in the compiled template and the AVM source.
- `allLogs` includes `Connection` (→ `WVDConnections`, host pool only), `Error` and `Checkpoint`.
- **Phase A3 adds a template test** that fails if the host pool's diagnostic setting stops sending `allLogs`. No Bicep change, no added cost: the rows are already ingested and billed today.

**New script: `scripts/ops/Test-AvdUserConnection.ps1`**
- Parameters: `-NamePrefix`, `-Environment`, `-UserPrincipalName` (default: the signed-in Azure user, from `Get-AzADUser -SignedIn`, lesson 0007), `-SinceMinutes` (default 60), `-TimeoutMinutes` (default 15), `-PollSeconds` (default 60).
- It follows the readiness script's shape: `Add-AvdCheckResult` items, a summary, then `Write-AvdPortalState`.
- It prints a line before it starts waiting (lesson 0006 rule).

**KQL in `scripts/ops/kql/user-connection.kql`**, commented, defining each metric:
- Filter `WVDConnections` by `UserName =~ <upn>`, `TimeGenerated > ago(window)` and `_ResourceId` = this host pool, then group by `CorrelationId`.
- Per connection: `startedAt`, `connectedAt` and `completedAt` (the `State` rows), `connectionSetupSeconds = connectedAt - startedAt`, plus `SessionHostName`, `ClientType`, `ClientOS`, `GatewayRegion` and `TransportType`.
- Join `WVDErrors` and `WVDCheckpoints` on `CorrelationId` (`CodeSymbolic`, `Message`, `Source`, `ServiceError`; checkpoint `Name`, `Source`).
- The file says plainly: *this is connection setup time, from the service accepting the request to the session being connected. It isn't AVD Insights' "time to connect" (which includes logon), and it isn't time to a usable desktop.*

**Polling and outcomes (fail closed)**
- Diagnostic resource logs usually arrive 3–10 minutes end to end, and up to 20 minutes for the collection stage (§11). The script polls every `PollSeconds` until `TimeoutMinutes`.

| `status` | Condition |
|---|---|
| `verified` | At least one connection for the user in the window has a `Connected` row. Errors on *other* attempts are still reported |
| `failed` | Rows for the user exist and none reached `Connected`, and there are errors. Or a `Started` with errors and no `Connected` after the timeout |
| `notverified` | No rows for the user by the timeout. Or rows exist with no `Connected` and no errors (still in progress, or ingestion lag). The query itself failing is also `notverified`, with the HTTP status and body (lesson 0012) |

- `WVDConnections` has no documented `Failed` state, only `Started`, `Connected` and `Completed`. Failures are therefore detected through `WVDErrors` on the same `CorrelationId`.
- A missing row never becomes a pass.

**The query call**
- It goes through Log Analytics' REST query API with the operator's Entra token. The workspace has local auth disabled, and Entra queries are unaffected.
- **Route (built, Q3):** `POST https://api.loganalytics.io/v1/workspaces/{customerId}/query` with a token for `https://api.loganalytics.io/.default`, confirmed from the API spec (§11 A11). The workspace's `customerId` comes from ARM.
- The operator needs read access to the workspace. Owner or Contributor on the management resource group covers it. Otherwise a failure says which role to grant.

**State line: `stage: "verify"`** with `status` from the table above, and:
- `context`: `user`, `windowMinutes`, `hostPool`, `waitedSeconds`
- `context.connections[]` (the latest 5): `correlationId`, `sessionHost`, `clientType`, `clientOS`, `gatewayRegion`, `transportType`, `startedAt`, `connectedAt`, `completedAt`, `connectionSetupSeconds`, `errors[]`, `checkpoints[]`
- `failures`/`warnings` with ids: `connect-errors`, `no-connection`, `in-progress`, `query-failed`, `no-landing-zone`

**Cold start (built as text only):** no reliable signal was confirmed for "this connection started a stopped host", so there is no `coldStart` field. The script and the portal always say a first connection to a stopped host includes it starting. A field can follow once a real run shows which checkpoint marks it.

**`portal-core.js`**
- `extractStates` already reads any stage. `analyze` gains a `verify` branch:

| Result | Next action shown |
|---|---|
| `verified` | Done; shows connection setup time with its definition, the client type, the not-steady-state note, and other failed attempts |
| `failed` | The code and message as logged. With `serviceError`, retry and check Service Health; otherwise the post-deployment check, then check again. Code-specific guidance (`CodeSymbolic` → advice) is added only from real fixtures: no error code was confirmed in the docs this session could read |
| `notverified`, no rows | "Did the sign-in complete? Rerun to wait longer", the same command with a longer `-TimeoutMinutes` |
| `notverified`, `query-failed` | The HTTP status and the role to grant |

- Command builder `cmd.verify(cfg)` is a self-contained Cloud Shell block (lesson 0015). The parameter-drift test covers it.

**Tests**
- Node tests for `classifyReachability`, `launchUrl` (GUID validation, fragment last, no tenant by default) and every `verify` branch, with redacted fixtures.
- New offline scenario `build/tests/offline/VerifyConnection.Scenario.ps1`. `AzMock.psm1` answers the query route with canned tables, omitting empty columns the way the service does. Cases: verified, failed with errors, no rows (timeout shortened), still in progress, query 403.
- Added to `OfflineScenarios.Tests.ps1`.
- `report.js`: correlation IDs and object IDs are GUIDs and are already redacted. Session host names carry the name prefix, which is already redacted. No new pattern is expected; a `pii-sample.txt` line confirms it.

### 6.6 Track A failure modes and portal guidance

| Symptom | Likely cause | Portal says |
|---|---|---|
| Probe `blocked` | Firewall, DNS filter, content blocker, captive portal | Try another network or disable the blocker for this page. Your IT must allow the AVD end-user FQDNs (link) |
| Probe `reachable`, launch fails before sign-in | Wildcard hosts blocked (`*.wvd.microsoft.com`), not probed | The probe can't test the feed and gateway hosts. Check the FQDN list |
| Sign-in loops or is blocked | Conditional Access, MFA, the wrong account | Sign in as a member of `<group>`. CA policies apply to both *Azure Virtual Desktop* and *Windows Cloud Login* |
| "No resources" in the client | Not in the users group, or the token predates membership | Group changes take up to an hour. Sign out and in again |
| Consent prompt | Expected on first connection to each host | Choose Yes. To hide it, see trusted devices (§6.4) |
| Long first connect | Start VM on Connect is booting the host | Expected once. Not steady state |
| `notverified` | Ingestion lag, or sign-in never reached the service | Rerun with a longer timeout. If still nothing, the connection never reached AVD |

---

## 11. Facts verified, and what is not

**How this was checked.**
- The first pass couldn't reach learn.microsoft.com, azure.microsoft.com or prices.azure.com. On **2026-10-06** every *Summary* and *Not verified* row was rechecked against the live page text (raw HTML, not a summary); the dates below are each page's `ms.date`.
- **Verified** means read from Microsoft's published doc source in GitHub (MicrosoftDocs/azure-ai-docs at 2026-10-05, azure-monitor-docs, microsoft-graph-docs-contrib), from Azure/azure-rest-api-specs, from Bicep 0.48.1's built-in types (a test template compiled locally), or from the AVM source and the compiled `main.bicep`.
- **Summary** meant a search engine's summary of the Learn page, not its text. None is left.
- **Corrected** means the live page says something different; the row gives what it says, and the spec and code now follow it.
- **Unverifiable** means no current Microsoft page states it; it stays a spike or a question for the owner.

| # | Fact | Status | Source |
|---|---|---|---|
| A1 | End-user devices list `login.microsoftonline.com` ("Authentication to Microsoft Online Services"), `windows.cloud.microsoft` ("Connection center"), `go.microsoft.com`, `aka.ms`, and wildcards including `*.wvd.microsoft.com` and `*.windows.cloud.microsoft`. `rdweb.`/`client.wvd.microsoft.com` aren't named | **Verified** (live page, ms.date 2026-03-11, updated 2026-09-22). The list also has `*.service.windows.cloud.microsoft`, `*.windows.static.microsoft`, `graph.microsoft.com` and others the probe doesn't need | [Required FQDNs](https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint#end-user-devices) |
| A2 | Direct launch `https://windows.cloud.microsoft/webclient/avd/<workspaceID>/<resourceID>`; `?tenant=` for external identities; `#loginHint=<UPN>` "will only work if it is at the end of the URL", and works without `tenant` for internal identities | **Verified** (live page, ms.date 2026-09-09). A Node test reproduces the page's fully formatted example | [Direct launch URLs](https://learn.microsoft.com/windows-app/direct-launch-urls) |
| A2b | `properties.objectId` (read-only) on workspaces, app groups and desktops | Verified (API spec 2025-10-10; Bicep types 2024-04-03) | [REST spec](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/desktopvirtualization) |
| A2c | `Get-AzWvdWorkspace`/`Get-AzWvdDesktop` output an `ObjectId` property | **Verified**: `(Get-AzWvdWorkspace …).ObjectID`, `(Get-AzWvdDesktop …).ObjectId` (ms.date 2024-01-08) and `FT Name, ObjectId` with sample output (direct launch page, 2026-09-09). The cmdlet reference pages still don't list output properties. The code keeps REST | [Object IDs](https://learn.microsoft.com/azure/virtual-desktop/cli-powershell#retrieve-the-object-id-of-a-host-pool-workspace-application-group-or-application) |
| A3 | `ms-avd:connect` parameter names for Windows App | **Still not confirmed** (live page, updated 2025-12-02). The table says Windows App 2.0.804.0+ takes `resourceid` and `user` (required) and `usemultimon`, and doesn't support `workspaceid`, `env`, `version`, `launchpartnerid` or `peeractivityid`; the page's only example uses `workspaceId`, `username` and `version=0`, contradicting it. No link shipped; proposal in §6.3 | [URI schemes](https://learn.microsoft.com/azure/virtual-desktop/uri-scheme) |
| A4 | SSO shows a dialog to allow the connection for each new session host; Entra remembers up to 15 hosts for 30 days; up to 10 device groups hide it | **Verified** (live page, ms.date 2025-08-29, updated 2026-07-29) | [Configure SSO](https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on#hide-the-consent-prompt-dialog) |
| A5 | `targetDeviceGroups` Graph API, max 10, `Application-RemoteDesktopConfig.ReadWrite.All` | Verified | [Graph](https://learn.microsoft.com/graph/api/remotedesktopsecurityconfiguration-post-targetdevicegroups) |
| A6 | `WVDConnections` is host-pool only; states seen are Started/Connected/Completed, no Failed | Verified (table reference, ms.date 2026-07-27) | [WVDConnections](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdconnections), [queries](https://learn.microsoft.com/azure/azure-monitor/reference/queries/wvdconnections) |
| A7 | `WVDErrors`, `WVDCheckpoints` columns; categories per resource | Verified | [WVDErrors](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvderrors), [WVDCheckpoints](https://learn.microsoft.com/azure/azure-monitor/reference/tables/wvdcheckpoints), [host pool logs](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-desktopvirtualization-hostpools-logs) |
| A8 | AVM host pool, app group and workspace default to `categoryGroup: allLogs` | Verified (compiled `main.bicep`, AVM source) | `bicep build bicep/main.bicep` |
| A9 | Resource logs usually 3–10 minutes end to end; collection stage 30 s–20 min | Verified | [Ingestion time](https://learn.microsoft.com/azure/azure-monitor/logs/data-ingestion-time) |
| A10 | AVD Insights "time to connect" runs until the desktop has loaded and is ready (connection plus logon): from `WVDConnections` `State = Started` to the `WVDCheckpoints` `ShellReady` checkpoint for desktops, minus the time the user takes to enter credentials | **Verified** (live page, ms.date 2023-09-12, updated 2026-05-25). The KQL comment now names the checkpoints | [Insights glossary](https://learn.microsoft.com/azure/virtual-desktop/insights-glossary#time-to-connect) |
| A11 | Log Analytics query route `POST {endpoint}/v1/workspaces/{workspaceId}/query`, default endpoint `https://api.loganalytics.io`, scope `https://api.loganalytics.io/.default`, response `tables[].columns/rows` | Verified (API spec) | [Azure/azure-rest-api-specs: monitor/data-plane/OperationalInsights](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/monitor/data-plane/OperationalInsights) |

## 12. Open questions for the owner

**Answered 2026-10-05:** the owner agreed with every proposed answer below. Q1: only the confirmed hosts. Q2: document trusted devices. Q3: pick the route at A3 and mark it.

1. **Q1, probe hosts:** add `rdweb.wvd.microsoft.com` and `client.wvd.microsoft.com` as informational and unconfirmed, or probe only the two confirmed hosts? *Proposed: only the confirmed ones.*
2. **Q2, consent prompt:** document trusted devices only (proposed), or have the post-deployment `-Fix` create a device group of the session hosts and register it with `targetDeviceGroups`? The second needs a new Graph permission in the operator's sign-in, and a group that tracks hosts.
3. **Q3, query route:** the Log Analytics query route is settled at A3 from the live docs. OK to pick it then and mark it in code?

## 13. Phases

| Phase | Builds | Done when |
|---|---|---|
| **0** | This spec, decision 0014 | The owner has answered §12 |
| **A1** | `classifyReachability`, the probe in the Verify step, copy, Node tests | Node tests green; a manual check in a browser (not possible from CI) |
| **A2** | `context.launch` from the post-deployment and demo runs, `launchUrl`, the README schema, the PostDeployment scenario asserting `launch` | Pester, offline scenario and Node tests green |
| **A3** | `Test-AvdUserConnection.ps1`, `kql/user-connection.kql`, AzMock query route, `VerifyConnection` scenario (5 cases), portal `verify` branch, template test for `allLogs` | All CI checks green. Real sign-in still unverified until the owner runs it |

Each phase is one commit. Track A (A1–A3) is built.
