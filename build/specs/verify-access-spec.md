# Spec: verify access from the operator's device, and an optional computer-use agent

- **Status:** Proposed. The owner agreed with every proposal in §12 (2026-10-05); Track A (Phases A1–A3) is built. Decisions [0014](../decisions/0014-verify-access.md) (Track A) and [0015](../decisions/0015-foundry-cua.md) (Track B). Track B was red-teamed ([verify-access-redteam.md](verify-access-redteam.md)) and the fixes are folded in below.
- **Date:** 2026-10-05
- **Scope:** landing zones built from this repo. Track A changes the deployment portal and the ops scripts, not the deployed resources. Track B is a separate, optional deployment, off by default.

This is a personal project, not for production, provided as is. Nothing here has run against a real tenant yet. §11 lists every fact this spec relies on, how it was checked, and what is still unverified.

## 1. Summary

After a deployment the portal says "sign in to the desktop" and stops. Nothing confirms that the operator's device can reach AVD, that the right person can get the right desktop, or that a connection actually happened. This spec adds two tracks.

- **Track A, *Verify access* (the default path).** A new portal step after *Sign in* has three layers, run from the operator's own device and signed in as themselves:
  1. **Reachability:** a browser probe to concrete AVD client hostnames.
  2. **Launch:** a direct web client link to this landing zone's desktop, built from IDs the post-deployment run reports.
  3. **Confirmation:** a Cloud Shell script that reads `WVDConnections`, `WVDErrors` and `WVDCheckpoints` for that user and reports *verified*, *failed* or *not verified*.

  No test account, no stored credentials, no new Azure resources.
- **Track B, *computer-use agent* (optional, off by default).** A Microsoft Foundry resource with a computer-use model, and an isolated Windows VM that runs a bounded screenshot-and-action loop. The loop signs a dedicated test user in to the desktop and checks that it looks right. It is the unattended counterpart to Track A. It can't replace Track A, because it proves only what an Azure-hosted client sees.

"Foundry" here means **Microsoft Foundry** (formerly Azure AI Foundry). Cloud Foundry, the PaaS, is out of scope.

## 2. Goals and non-goals

### Goals
1. An operator can tell, from their own device, whether AVD is reachable, can open the desktop in one click, and gets an objective answer from Azure telemetry about whether a connection was made.
2. Each layer says exactly what it proves and what it doesn't. No layer claims more than it measured.
3. The default deployment is unchanged: no new resources, no added deploy time, no new required parameters. The 30-minute desktop stays 30 minutes.
4. (Track B) Repeatable, unattended sign-in checks from an isolated client, without the model ever handling a credential.

### Non-goals
- **Proving the user experience.** None of this measures input delay, frame rate or "the desktop felt fast". AVD Insights and `WVDConnectionNetworkData` already cover that.
- **Testing every network a user might be on.** Track A tests the operator's network now. Track B tests one Azure region's egress.
- **Load testing.**
- **A server for the portal.** The portal stays a static page (decision 0007).

## 3. Principles

| # | Principle | Source |
|---|---|---|
| V1 | Fail closed: a missing row, a timeout or an unknown state is *not verified*, never a pass | the brief; lesson 0021 (ARM omits empty properties) |
| V2 | Name each metric for what it measures. Started→Connected is *connection setup time*, not time to a usable desktop | AVD Insights' "time to connect" includes logon (§11) |
| V3 | Nothing pasted or measured leaves the browser | decisions 0007, 0008 |
| V4 | Prefer REST where a cmdlet reshapes or blocks | decision 0002; the cmdlet help doesn't document `ObjectId` (§11) |
| V5 | Default deployment unchanged; Track B is its own template and its own run | the brief; scope creep risk |
| V6 | Credentials never reach the model, in text or, as far as we can control, in pixels | the brief; Microsoft's computer-use guidance |
| V7 | Never auto-acknowledge a safety check | Microsoft's computer-use guidance |
| V8 | Every new state the portal recognizes gets an `id`, a branch in `portal-core.js`, a Node test and an offline scenario | decision 0007, CLAUDE.md |

---

# Track A: Verify access

## 4. What each layer proves

| Layer | Proves | Doesn't prove |
|---|---|---|
| A1 Reachability probe | This browser, on this network, completed DNS, TCP and TLS to each probed host, and got *some* HTTP response | Sign-in, authorization, the feed, the host pool, the RDP gateway path, UDP (RDP Shortpath, TURN on 3478), or anything about the session host. A proxy that answers with its own block page also counts as "reached" (§5.3) |
| A2 Launch link | The operator can open this landing zone's desktop in the web client with one click, as the account they choose | On its own, nothing: the person reads the result on screen. Layer A3 makes it objective |
| A3 Telemetry confirmation | The AVD service recorded a connection by *this user* to *this host pool* that reached `Connected`, in the time window, with its errors and checkpoints | That the desktop was usable, the profile loaded, apps worked, or that the next user will succeed. That the *operator's device* made the connection (the user name and client type are reported, so the operator can judge) |
| Track B agent (§7) | An Azure-hosted client signed in as the test user and saw a desktop matching the expected checks | What any real user's device or network sees |

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

# Track B: Foundry computer-use agent (optional)

## 7. Model and region

### 7.1 The doc conflict, resolved
The three pages the owner found are all current. They describe **two different tools**:

| Page | What it covers | Model | Regions | Status |
|---|---|---|---|---|
| Foundry **Agent Service** computer use tool (ms.date 2026-08-21) | The `computer_use_preview` tool inside Foundry agents | `computer-use-preview` (2025-03-11) only | eastus2, swedencentral, southindia; GlobalStandard only | Preview, limited access (aka.ms/oai/cuaaccess) |
| **Responses API** computer use how-to (foundry-classic, ms.date 2026-03-09) | The `computer` tool called directly through `/openai/v1/responses` | `gpt-5.4` | Not stated on the page | Registration required (aka.ms/OAI/gpt54access), even with other limited-access approvals |
| **Models sold directly by Azure** (ms.date 2026-09-21) | Model capabilities | "Computer use" on gpt-5.4 (2026-03-05), gpt-5.4-mini, gpt-5.5, gpt-5.6-*, gpt-6-*, gpt-6.1-sol | Region matrix: GlobalStandard almost everywhere; gpt-5.4, gpt-5.5 and gpt-6-sol also DataZoneStandard | Not marked preview. The page doesn't say whether the gpt-5.4 registration also gates the newer models |

### 7.2 Choice
- **The Responses API `computer` tool with `gpt-5.4`, version `2026-03-05`, SKU `GlobalStandard`, capacity a parameter (default 10 thousand TPM, to be confirmed against quota at B1).**
- All four are parameters: `foundryModelName`, `foundryModelVersion`, `foundryModelSku`, `foundryModelCapacity`.
- **Retirement (red-team M3):** a pinned version retires on a date. The preflight reads the model's lifecycle from the region's model list (whether that API exposes it is to verify) and warns 60 days ahead. A version change is a PR.

Why this over the others:
- **Not `computer-use-preview`.** It's a preview model in three regions, behind the agent service and the older tool shape. The Agent Service computer use tool is also listed as *not supported* behind network isolation (§8).
- **gpt-5.4 rather than newer models.** It's the only model with a computer-use how-to and a stated access process. Changing the parameter tries a newer one (**Q4**).
- **GlobalStandard rather than DataZoneStandard.** Global has the widest availability. `DataZoneStandard` keeps processing in the US or EU data zone and is one parameter away. **Data residency:** with `GlobalStandard`, prompts (screenshots of the desktop) may be processed in any Azure region. Data at rest stays in the resource's geography. The docs and the deployment output say so.

### 7.3 Region
- `foundryLocation` is separate from the landing zone's `location`.
- **Default:** the landing zone's region when the preflight finds the model and SKU there, else `eastus2` (in the matrix for every candidate). The preflight checks the region's model list and quota through ARM (`Microsoft.CognitiveServices/locations/<region>/models`, `…/usages`). Both routes are to be verified at B1.

### 7.4 Access as a prerequisite, never a half-deployment
Model access is an application to Microsoft (aka.ms/OAI/gpt54access) with no stated turnaround. It may block Track B entirely. So:
1. **Pre-deployment preflight, `-FoundryCua`:** checks the model, version and SKU in `foundryLocation`, quota, the resource providers, and that the PE subnet range is free.
   - It can't see whether access was granted. As far as I could find, no documented API exposes that. It says so and links the form.
2. **Track B is its own template and its own run** (`bicep/agent/main.bicep`, like `bicep/demo`). The landing zone's deployment never waits on it, and its failure can't touch the landing zone.
3. **Order inside the run:**
   - Stage 1: the Foundry account and the model deployment, as one deployment.
   - Stage 2: everything else (sandbox network, VM, Key Vault, evidence storage), in a second deployment that runs only when stage 1 succeeded.
4. **When stage 1 fails:**
   - The script reports the ARM error (code, message, target) and recognizes the access error by its code. The code is unverified; the first real failure becomes a fixture (retro).
   - It **deletes the half-created account**, then purges it, because Cognitive Services accounts soft-delete. Only an account whose tags carry this run's deployment name and that was created in this run is deleted. The purge uses the exact name and location from the delete's response, never a name typed or derived again. `-WhatIf` prints what would be purged. Both steps need a prompt, or `-Force`. The purge needs the same care as lesson 0022, and an offline scenario covers a foreign account with the same name (red-team H6).
   - It prints the access form link. The state line says `stage: "agent-deploy"`, `status: "failed"`, `id: "model-access"`.

## 8. Networking

```
┌─ rg-<prefix>-<env>-agent  (Track B only) ─────────────────────────────────────────────┐
│ vnet-<prefix>-<env>-agent  10.100.8.0/24 (parameter; must not overlap the spoke)      │
│   snet-agent-vm     /27   sandbox VM, NSG: no inbound; outbound 443 only              │
│   snet-agent-pe     /27   private endpoints: Foundry (account), Key Vault, blob       │
│ NAT Gateway + public IP   (standalone)  │  UDR → hub firewall (hub-peered mode)       │
│ Foundry account (foundryLocation) · Key Vault · evidence storage · sandbox VM         │
└───────────────────────────────────────────────────────────────────────────────────────┘
        ✗ no peering to the landing zone spoke, ever
```

- **Its own VNet, not peered to the landing zone spoke.** This deliberately differs from the brief's "own peered spoke".
  - The agent tests the *user* path: the public AVD gateway, Entra sign-in and the web or Windows App client. All of these are internet endpoints.
  - Peering would give a prompt-injectable machine a route to the session host and private endpoint subnets for no test benefit.
  - In hub-peered mode it peers to the **hub only**, for firewall egress. The firewall's rules decide what it reaches.
  - **Q5** asks the owner to confirm.
- **Egress:** 443 only.
  - Standalone: a NAT Gateway, so it has no public IP of its own, matching decision 0001.
  - Hub-peered: the hub firewall, allowing the AVD end-user FQDNs, Entra sign-in and the Foundry and Key Vault private endpoints (which resolve privately and don't need a rule).
  - An Azure Firewall in standalone mode to narrow egress to FQDNs was considered and rejected on cost. The NSG can't filter by FQDN, so in standalone mode egress is *any 443*, and this is documented.
- **Foundry, private by default:**
  - A private endpoint (group `account`) in `snet-agent-pe`, with the three zones `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com` and `privatelink.services.ai.azure.com`, linked to the agent VNet only.
  - `publicNetworkAccess: Disabled`, `disableLocalAuth: true`, and `customSubDomainName` set (required for token auth and private endpoints).
  - **Risk:** Foundry's private-link page lists *Computer Use: not supported* behind network isolation. That row is in the **Agent Service tools** table. This design calls the Responses API directly, which is ordinary model inference, and nothing I found says inference with the `computer` tool fails over a private endpoint. Unverified (**Q6**). If the first real run shows it fails, the fallback is `publicNetworkAccess: Enabled` with `networkAcls` allowing only the NAT Gateway's public IP. It's still keyless, still Entra-only, and decided by the owner, not silently.
  - The private endpoint can sit in the landing zone's region while the account is in `foundryLocation` (Private Link is cross-region). To verify at B1.
- **Key Vault and evidence storage:** private endpoints in the same subnet, public access off. This is a **separate** vault from the landing zone's, so the agent's identity has no path to the break-glass secret.

## 9. Sandbox VM (Phase B2)

| Choice | Decision | Why |
|---|---|---|
| OS | Windows 11 Enterprise (single session), `licenseType: Windows_Client` | Windows App supports Windows 11, Windows 10 1809+ and Windows Server 2019 or later for AVD (§11 B17); Windows 11 is kept because the test should look like a user's device. Windows 11 on Azure needs an eligible per-user license (Windows E3/E5 or similar) through multitenant hosting rights. Which license covers a workgroup VM whose only user is a local account is **unverified** (red-team M4). Image `MicrosoftWindowsDesktop/windows-11/win11-24h2-ent` to be confirmed at B2 |
| Size | `Standard_D2as_v5` (parameter) | Enough for a browser or Windows App and a script. Priced by the preflight from the retail meters, never guessed (decision 0010) |
| Security | Trusted Launch, encryption at host, no public IP, system-assigned managed identity, Microsoft Defender Antivirus (built in). **App Control for Business (WDAC), enforced, for the agent's session:** Windows App (by publisher), the harness and Explorer only. No PowerShell, cmd, Run dialog, browser or Store for `avdagent` (red-team C1) | Same baseline as session hosts, plus the allowlist: the model drives this desktop, so anything it can launch is in scope |
| **Broker** (red-team C1) | A local service in session 0, as its own virtual service account, makes every Azure call (Foundry, Key Vault, evidence, ARM logoff). The harness in session 1 reaches it over a named pipe with fixed verbs: next action for this screenshot, a one-shot credential (TOTP only, §10.3), store evidence, sign out, finish. No verb returns a token. **Windows Firewall outbound default-deny** on every profile, with allows only for the broker's service SID (IMDS, the private endpoints), Windows App and WebView2 by program path (TCP 443, UDP 3478) and DNS. An IMDS *block* with a broker exception can't work: block rules override allows (Copilot review). If B0 can't enforce this with Windows App working, Track B stops or the broker moves off the VM (an Azure Function in the agent VNet; the VM gets no managed identity) | The model controls the desktop's mouse and keyboard. Without the default-deny, anything it can open could ask IMDS for the identity's token |
| **Not joined** to Entra ID or Intune | Workgroup VM | A compromised or misled agent then has no device identity in the tenant, and nothing on it is trusted by Conditional Access. Consequence: a "require compliant device" policy would block the test user here (B4 deals with it) |
| Session for screenshots | A local, non-admin user `avdagent` with Autologon. Its random password is generated at deploy and stored as an LSA secret through Sysinternals Autologon, never as plain text in `Winlogon\DefaultPassword`. The harness runs as a scheduled task at that user's logon, in session 1, and holds no identity: it talks to the broker | Screenshots and input need the interactive desktop. Services run in session 0 and can't see it. The local password protects nothing of value (no network rights, not used for AVD) and nobody needs to know it (rule: never make operators remember secrets) |
| Display | 1440x900 | The Responses API how-to recommends 1440x900 or 1600x900 for click accuracy. **How to set the console resolution on an Azure VM with no RDP session is unverified** (B2 spike; **Q7**) |
| Screen lock | Off for `avdagent`. The VM is reachable only through Run Command or Bastion | A locked screen stops the loop |
| Client under test | **Windows App** (pinned MSIX version and SHA-256, from Microsoft's download link) | It tests the real client and RDP path. The web client is the fallback when the MSIX can't be installed unattended |
| Harness install | An embedded managed Run Command (`loadTextContent`), like `Register-AvdAgent`. Pinned versions and hashes for everything it installs | Same as the session hosts (design decision 3) |
| Operator access | **None by default.** Run Command for status and evidence. Azure Bastion **Developer** (free, one connection, no peering, local sign-in only, not in every region) is an opt-in for **maintenance only**: an RDP session takes the single console from `avdagent`. People watch a run through its evidence, not live. The harness refuses to start while another session exists, and aborts (`status: aborted`, signed out through ARM) if the console session disconnects mid-run (red-team H3) | No standing access path and no added cost. Basic or Standard Bastion costs per hour and isn't needed. Just-in-time access needs Defender for Servers Plan 2 and an NSG rule on a management port, so it's rejected |
| Power | Deallocated except during a run. A schedule calls a runbook on decision 0011's Automation pattern, with Virtual Machine Contributor scoped to the sandbox VM only, to start it. The broker deallocates it at the end (red-team M5) | Cost |

**What this VM tests:** an Azure-hosted client in `foundryLocation`'s egress, signing in as the test user. It doesn't test any user's device, ISP, proxy or Conditional Access device state. Docs and the portal say so beside every Track B result.

## 10. The harness (Phase B3)

### 10.1 Language (**Q8**)
The brief asks for the official SDK of the chosen language. The options:

| Option | Pros | Cons |
|---|---|---|
| **Python + `openai` SDK** (Microsoft's samples use it; `openai` 3.24.0, `azure-identity` 1.26.0 on PyPI today), pinned with `--require-hashes` | Matches the docs, so the call shape is the documented one | A second language. Python plus screenshot and input libraries on the VM, all from PyPI at deploy. The offline mock and Pester harness don't cover it |
| **Windows PowerShell 5.1 + REST** (`Invoke-RestMethod` to `/openai/v1/responses`, token from IMDS for `https://ai.azure.com/.default`) | Matches the repo: PowerShell only, REST over SDKs (decision 0002), 5.1 on hosts (lesson 0011). No third-party packages: screenshots through `System.Drawing`, input through `SendInput`. The existing offline harness can mock the Responses API | Not an "official SDK"; the request shape is maintained by hand |

**Proposed: PowerShell 5.1 + REST.** The request and response shapes are small, documented and testable offline. Adding Python only for an SDK wrapper would break the repo's one-language rule. The owner decides.

### 10.2 Loop (red-team C2, C3)
1. **Kill switch:** the broker reads the VM's tags from IMDS. If `avdlz-agent=off`, stop.
2. **Sign-in, without the model.** A trusted sign-in step of the harness, in session 1 (UI Automation only works within the session, so the session-0 broker can't drive it), launches Windows App and drives the sign-in through UI Automation on the Entra sign-in web view. That view is a separate top-level window owned by Windows App, with `login.microsoftonline.com` as its URL. Nothing is typed into the client's main window, and the model hasn't seen anything yet.
3. **Desktop, observed by the model.** Once the session window is up, the harness sends the task and a screenshot (`tools: [{type: "computer"}]`). From here it accepts only `screenshot` and `wait`. Any click, typing, scroll or key press inside the session is rejected, recorded, and ends the run with `needsreview`.
4. **Sign-out, by the harness** (§10.6).
5. **Stop** on a final message, a safety check, a rejected action, or a bound.

### 10.3 Credentials never go through the model
- **Certificate-based authentication is preferred** (§10a): nothing is typed, and nothing can be stolen by typing. TOTP with a password is the fallback.
- With TOTP, the password and seed live in the agent's Key Vault. **Key Vault Secrets User on each secret**, held by the VM's identity, which only the broker can use (§9).
- **Credentials are typed only during sign-in (§10.2 step 2)**, by the harness's sign-in step, only into the Entra sign-in window identified by owner and URL through UI Automation, with Enter in the same step. With TOTP, the step gets each value from the broker's **one-shot credential verb**, which the broker closes for the run when the harness reports the session window, or after 5 minutes. There is **no credential tool for the model**. It gets control only after the verb is closed, and its actions run through a harness that accepts only `screenshot` and `wait`, so nothing it does can reach a credential (red-team C2, revised after Copilot review). This also removes the open question of mixing a function tool with the `computer` tool (§11 B6).
- **What the model can see:** the desktop after sign-in. No sign-in screen, no password field, no TOTP code.
- **If deterministic sign-in proves too brittle** in the B3 spike, Track B stops there. The fallback is never to let the model type secrets.
- Secrets are never logged, never put in the state line or evidence, and never kept after use.

### 10.4 Safety checks
- **`pending_safety_checks`** (`malicious_instructions`, `irrelevant_domain`, `sensitive_domain`) are **never acknowledged** in unattended runs. The harness stops, records each check's code and message, logs off (§10.6), and reports `status: "needsreview"`.
- **A check is never cleared by a later run.** It's a person's job: they read the evidence and either fix the cause or accept it and rerun.
- **What actually holds is the harness, not the checks** (red-team H2). The domain checks evaluate a browser URL that Windows App doesn't have, and `malicious_instructions` is a model-side heuristic. The controls that hold are: observe-only after connect, the WDAC allowlist and the broker. A rejected action is reported exactly like a safety check.

### 10.5 Bounds

| Bound | Default (parameter) |
|---|---|
| Task prompt | Fixed in the repo: look at the desktop and report what's visible against the checklist, then stop |
| Actions allowed | `screenshot` and `wait` only, after the session window is up. Anything else is rejected and ends the run with `needsreview` (red-team C3) |
| Iterations | 40 |
| Wall clock | 15 minutes |
| Token budget | 400,000 input + output per run, summed from each response's `usage`. Exceeding it stops the run |
| Across runs | At most 4 runs a day. Three failed or aborted runs in a row disable the schedule. A budget on the agent resource group, whose alert deallocates the sandbox and disables the schedule (decision 0011's pattern; red-team H5) |
| Kill switch | Soft: VM tag `avdlz-agent=off`, read each iteration (how fast IMDS reflects a tag change is unverified). Hard: **deallocate the VM**, or **remove the broker identity's Foundry role**; both are one command in the runbook. The wall clock is the bound that always holds (red-team H1) |
| Allowed hosts | When the web client fallback is used, the harness drives sign-in only on `login.microsoftonline.com` and the documented sign-in hosts, and the model never navigates (observe-only) |

### 10.6 Always sign out
- The harness logs the test user's AVD session off on success, failure, timeout and kill, from a `finally` block.
- **Primary:** inside the session, by sending the sign-out keyboard sequence through the client.
- **Then it verifies through ARM:** list `userSessions` on the host pool, filtered to the test user's UPN, and delete any left.
  - That needs **Desktop Virtualization User Session Operator** on the host pool. **Q9, settled by the red team:** granted to the VM's identity (used only by the broker) **on the dedicated check pool only** (§10.6a), never on the main, demo or QA pool. Only the test user can be on the check pool, so the role can't affect real users. A template test asserts the scope.
  - On the main pool there are no ARM rights at all. Leftover sessions there would end by the disconnect time limit, but the agent never signs in there (§10.6a).

### 10.6a The target pool (red-team C3)
- The test user's group is assigned **only** to a **one-host agent check pool**: its own desktop app group, assigned to nobody else; local profiles (no FSLogix share); the same image and host template as the main pool. **Not the demo pool and not the QA pool**: `Deploy-AvdDemo.ps1` assigns the demo to the landing zone's AVD Users group and reuses the production profile share, and the QA pool (decision 0013) has QA users (Copilot review).
- The pre-deployment preflight with `-FoundryCua` fails if the test user's group can reach any other app group, or if anyone else can reach the check pool's.
- Why: after sign-in the agent's session runs on a session host, as a user. A pooled production host is shared with real users and the profile share; the check pool isn't. The trade-off: the agent checks a pool built like the main one, not the main pool itself. Track A covers the main pool from real devices. The check pool costs one more host while it runs, deallocated between runs, priced by the preflight.

### 10.7 What it checks, and the result
- **The checklist, a parameter:** the desktop appeared; the expected apps are pinned or present (default: none); a profile banner or error isn't visible. Answered from screenshots alone (observe-only).
- **Timing comes from telemetry** (Track A's KQL against the test user), never from the loop, because model latency would pollute it.
- **The result is a state line, `stage: "agent"`:**
  - `status`: `verified` | `failed` | `needsreview` | `aborted`
  - `data`: `iterations`, `tokens`, `checks[]` (`name`, `passed`, `evidence`), `safetyChecks[]`, `signedOut`, `connection` (the A3 query result for the test user)
- The portal's Verify step reads it like A3's.

### 10.8 Evidence
- Each action the model proposed (its kind and coordinates; never typed text, and no hash of it, because a hash of a short secret can be guessed; red-team M1) and each screenshot go to a private blob container, with a lifecycle rule deleting them after **7 days** (parameter) and a write-once immutability policy for that period, so a run can't rewrite earlier evidence (red-team M2).
- Only the broker uploads: Storage Blob Data Contributor scoped to the container, held by the VM's identity, which only the broker can use (to be narrowed further at B3 if a write-only data role fits).
- Operators read it with their own RBAC. Nothing is public.
- Evidence never holds secrets (§10.3). The redaction in `report.js` doesn't apply to images. Evidence isn't attached to portal issue reports.

## 10a. Test identity (Phase B4): options for the owner, not built yet

| Option | Phishing-resistant | Unattended | Notes |
|---|---|---|---|
| Password + **software TOTP** (seed in Key Vault) | No | Yes | Fits the MFA authentication strength, not the phishing-resistant one. The seed is a long-lived secret. Graph v1.0 manages software OATH methods; hardware OATH tokens are in preview |
| **Certificate-based authentication** (cert in the `avdagent` user store, non-exportable) | Yes (multifactor CBA) | Probably | No typed secret at all. Whether Windows App's sign-in picks the cert unattended is unverified. Needs a CA and CBA configured in the tenant |
| Temporary Access Pass | No | Briefly | Default lifetime 1 hour and maximum 8 hours by default; the policy allows 10 minutes to 30 days. One usable at a time. It needs a person to issue it, so it doesn't suit schedules |
| FIDO2 / passkey | Yes | No | Needs a person or a hardware authenticator present |

- **Common to all options:**
  - A cloud-only user with no mailbox data and no roles, a member of a dedicated group assigned Desktop Virtualization User on the desktop app group only.
  - A license for AVD access (Microsoft 365 E3/E5/A3/A5/F3/Business Premium/Student Use Benefit, Windows Enterprise E3/E5, Windows Education A3/A5 or Windows VDA per user). That's **one more paid license** for the tenant.
  - A Conditional Access policy *targeting* this user to the Azure Virtual Desktop and Windows Cloud Login apps from the agent's NAT IP only (named location). Excluding the user from the tenant's MFA policy doesn't weaken it for anyone else. The user is excluded only from the device-compliance requirement, and only for those two apps. **Conditional Access needs Microsoft Entra ID P1 for this user** (many AVD-eligible bundles include it; to confirm per bundle). Exclude the user from risk-based policies only, and alert on any risk detection for it, so a block shows up as a finding (red-team H4).
  - Sign-in log alerts for any sign-in by this user from anywhere else. A display name that says what it is (`AVD agent (test)`), and its sign-ins excluded from QA-usage counts such as the image pipeline's `qa-pool-unused` (red-team M6).
- **Agreed:** CBA if a spike shows Windows App completes it unattended, else TOTP (Q10). No license is available yet.

## 10b. Future work (Phase B5): Windows 365 for Agents
- Windows 365 for Agents provides Intune-managed Cloud PCs that agents check out and back in, with a dedicated security baseline. It powers Copilot Studio computer use.
- It could replace the sandbox VM, the Autologon session, the display spike and the VM's patching.
- **Not built because:**
  - It's billed pay-as-you-go per Cloud PC through an Azure subscription (US $0.40 per hour, no per-user license; §11 B21), but the Cloud PCs aren't an Azure resource this repo deploys.
  - It's driven from Copilot Studio, not the Foundry Responses API.
  - It would add a second product to a deliberately narrow repo.
- **Revisit trigger:** a Foundry or REST entry point. It's generally available since the week of June 1, 2026 (§11 B21), so that's the only gap left.

## 10c. Cost (Track B only; the default deployment adds nothing)

| Item | Billing | Notes |
|---|---|---|
| Foundry account | No standing charge for the account itself (to confirm at B1) | |
| Model tokens | Per 1M input and output tokens. Each iteration sends a screenshot | `gpt-5.4` (<272k context) GlobalStandard: $2.50 input, $0.25 cached input, $15.00 output per 1M tokens; DataZoneStandard (US): $2.75 / $0.275 / $16.50 (pricing page and Retail Prices API, 2026-10-06; §11 B13). How a screenshot is tokenized for `gpt-5.4` isn't documented. The run's `usage` totals go into the state line, so real cost per run is measured, not estimated |
| Sandbox VM | Per hour while running, plus OS disk always | Deallocated between runs |
| NAT Gateway + public IP | Per hour plus data, always | The biggest standing cost. Shared with nothing in standalone mode |
| 3 private endpoints | Per hour plus data each | Foundry, Key Vault, blob |
| Key Vault, storage | Per operation / GB | Small |
| Bastion Developer (opt-in) | Free | Not in every region |
| Budget on the agent resource group | No charge | Its alert deallocates the sandbox and disables the schedule (red-team H5) |
| Test user license | Per user per month | Tenant-side, not Azure |

The pre-deployment preflight with `-FoundryCua` prices the Azure lines from the retail meters, with one meter per line or the meters it saw (decision 0010, lesson 0025). Prices quoted in this spec (§10b, §10c, §11) are verification snapshots dated 2026-10-06, not estimates to deploy against; the preflight's meters are the source of truth.

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
| B1 | Agent Service computer use tool: `computer-use-preview` only, 3 regions, limited access, preview | Verified (doc source, ms.date 2026-08-21) | [Agent tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/computer-use) |
| B2 | Responses API `computer` tool with `gpt-5.4`, registration at aka.ms/OAI/gpt54access, 1440x900/1600x900, scope `https://ai.azure.com/.default`, endpoint `/openai/v1/` | Verified (doc source, ms.date 2026-03-09) | [Responses API computer use](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/computer-use) |
| B3 | Models with "Computer use" capability; region and SKU matrix | Verified (doc source, 2026-09-21 / 2026-09-03) | [Models](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure), [regions](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability) |
| B4 | Whether the gpt-5.4 registration also gates newer models' computer use; GA vs preview; SLA | **Split.** SLA: **verified only in general**: the models page says models sold directly by Azure are "covered by Azure service-level agreements"; nothing narrows that to, or excludes, the `computer` tool. Registration scope and GA vs preview: **unverifiable**. Evidence: the Responses API how-to (ms.date 2026-03-09) has no preview label, mentions no model but `gpt-5.4`, and says other limited-access approvals don't carry over; the models page (2026-09-21) lists "Computer use" on gpt-5.4 through gpt-6.1-sol, all linking to that how-to, with no registration note for them, and says these models are "covered by Azure service-level agreements". Only the Agent Service tool is stated as preview without an SLA. Ask at access request time (Q4) | [How-to](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/computer-use), [models](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure) |
| B5 | Safety check codes; never execute with pending checks without user approval; run on a low-privilege VM with no sensitive data | Verified | B1, B2, [transparency note](https://learn.microsoft.com/azure/foundry/responsible-ai/openai/transparency-note) |
| B6 | Mixing a function tool with the `computer` tool in one request | **No longer needed**: the red team removed the credential tool (§10.3) | — |
| B7 | `accounts` kind `AIServices` with `allowProjectManagement`, `disableLocalAuth`, `publicNetworkAccess`, `customSubDomainName`; `accounts/projects`; `accounts/deployments` with `sku` and `model {format,name,version}` | Verified (Bicep types; stable 2025-06-01 through 2026-09-01) | [Template reference](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/accounts) |
| B8 | AVM `cognitive-services/account` (0.19.x) doesn't deploy projects; `avm/ptn/ai-ml/ai-foundry` 0.7.0 does (projects at 2025-12-01) | Verified (AVM source and registry) | [AVM](https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/cognitive-services/account) |
| B9 | Private endpoint group `account`; zones `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` | Verified | [Foundry VNets](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks) |
| B10 | Agent Service *Computer Use* tool not supported behind network isolation | Verified; whether it affects the Responses API path is **not verified** (Q6) | [Private link](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link) |
| B11 | Inference role: **Foundry User** (formerly Azure AI User, `53ca6127-db72-4b80-b1b0-d745d6d5456d`) on the account; Cognitive Services OpenAI User `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd` | Verified (built-in roles, 2026-07-01; Foundry RBAC, 2026-09-16) | [Built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning), [Foundry RBAC](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry) |
| B12 | GlobalStandard may process in any region; DataZoneStandard in the US/EU/APAC zone | Verified | [Deployment types](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/deployment-types) |
| B13 | Model prices, image tokenization | **Prices verified** (2026-10-06): `gpt-5.4` (<272k) Global $2.50 / $0.25 cached / $15.00 output per 1M; Data Zone US $2.75 / $0.275 / $16.50; `computer-use-preview` $3 / $12; matched by Retail Prices API meters (`serviceName eq 'Foundry Models'`, effective 2026-03-01). **Image tokenization unverifiable** for `gpt-5.4`: the vision how-to (2026-07-29) only gives the GPT-4 Turbo with Vision tile example | [Pricing](https://azure.microsoft.com/pricing/details/azure-openai/), [vision](https://learn.microsoft.com/azure/foundry/openai/how-to/gpt-with-vision) |
| B14 | Bastion Developer: free, no peering, one VM connection at a time, region list; Entra ID sign-in needs Basic or higher | **Verified** (SKU comparison ms.date 2025-11-24; Entra auth page 2026-08-11, which puts the portal's minimum SKU at Basic) | [Bastion SKUs](https://learn.microsoft.com/azure/bastion/bastion-sku-comparison), [Entra auth](https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication) |
| B15 | JIT needs Defender for Servers Plan 2 | **Verified** (ms.date 2026-07-03: "Enable Microsoft Defender for Servers Plan 2 on the subscription") | [JIT](https://learn.microsoft.com/azure/defender-for-cloud/enable-just-in-time-access) |
| B16 | Autologon stores the password as an LSA secret (readable by an administrator); the Winlogon `DefaultPassword` value is plain text, remotely readable by Authenticated Users | **Verified** (Autologon updated 2021-07-27; automatic logon ms.date 2026-02-12). Neither page mentions session 0 isolation | [Autologon](https://learn.microsoft.com/sysinternals/downloads/autologon), [Automatic logon](https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon) |
| B17 | Windows 11 on Azure needs an eligible per-user license, `licenseType: Windows_Client`; Windows App supports Windows 11/10 | **Corrected**: licensing and `Windows_Client` verified (ms.date 2025-05-22), but Windows App also supports **Windows Server 2019 or later** for AVD (ms.date 2025-11-03). §9 updated | [Multitenant hosting](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment), [Windows App](https://learn.microsoft.com/windows-app/get-started-connect-devices-desktops-apps) |
| B18 | AVD user licenses | **Corrected** (ms.date 2024-09-17): "Microsoft 365 E3, E5, A3, A5, F3, Business Premium, Student Use Benefit / Windows Enterprise E3, E5 / Windows Education A3, A5 / Windows VDA per user". §10a updated | [Prerequisites](https://learn.microsoft.com/azure/virtual-desktop/prerequisites) |
| B19 | Auth methods: TOTP, TAP lifetimes, authentication strengths | **Verified, with detail** (2025-03-04 / 2026-03-04): software and hardware OATH TOTP (hardware is preview; no HOTP); TAP default lifetime 1 hour, maximum 8 hours by default, configurable 10 minutes to 30 days; three built-in strengths, TAP satisfies MFA only. §10a updated | [OATH](https://learn.microsoft.com/entra/identity/authentication/concept-authentication-oath-tokens), [TAP](https://learn.microsoft.com/entra/identity/authentication/howto-authentication-temporary-access-pass), [strengths](https://learn.microsoft.com/entra/identity/authentication/concept-authentication-strengths) |
| B20 | Key Vault Secrets User `4633458b-17de-408a-b874-0445c86b69e6` | **Verified** (ms.date 2026-07-01). Goes into `PUBLIC_IDS` when Track B is built | [Security roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security) |
| B21 | Windows 365 for Agents exists; status and licensing | **Exists and billing verified** (2026-07-23, 2026-05-01): pay-as-you-go through an Azure subscription, US $0.40 per Cloud PC hour, no per-user license. **GA verified** (What's new, updated 2026-08-28, week of June 1, 2026): "Windows 365 for Agents is now generally available" | [W365 for Agents](https://learn.microsoft.com/windows-365/agents/introduction-windows-365-for-agents), [what's new](https://learn.microsoft.com/windows-365/agents/whats-new), [pricing](https://learn.microsoft.com/windows-365/agents/pricing-paygo-always-available) |
| B22 | Setting the console display resolution on an Azure VM without RDP; Windows App unattended install and its dependencies | Resolution: **unverifiable** (no page; B2 spike). Install: **verified in part**: an offline install with `Add-AppxPackage` and its dependencies (`Microsoft.VCLibs.140.00`, `…UWPDesktop`, `Microsoft.WindowsAppRuntime.2`) is documented (updated 2026-08-11); per-machine provisioning isn't (B2 spike) | [Offline install](https://learn.microsoft.com/windows-app/troubleshoot-basic) |
| B23 | Windows Firewall with outbound default-deny on every profile, allowing IMDS only for one service SID and the internet only for Windows App and WebView2 by program path, while Windows App still signs in and connects (red-team C1; block rules override allows, so this is the only form that can work) | **Not verified** (B0 spike; failure stops Track B or moves the broker off the VM) | — |
| B24 | App Control for Business (WDAC) blocking Run, the Start menu and shells for one local user while Windows App works | **Not verified** (B2 spike) | — |
| B25 | Driving the Entra sign-in web view in Windows App through UI Automation from the harness in session 1, and CBA completing unattended there | **Not verified** (B0 spike) | — |
| B26 | How fast IMDS reflects a tag change; whether the model list API exposes a retirement date | IMDS: **unverifiable** (no latency stated; scale set tags only update on reboot, reimage or disk change). Retirement: **verified**: the Models API returns `lifecycleStatus`, `deprecation.inference`, `deprecation.fineTune` and per-SKU `deprecationDate` (ms.date 2026-07-24) | [IMDS](https://learn.microsoft.com/azure/virtual-machines/instance-metadata-service), [retirements](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements) |
| B27 | Which Windows license covers a Windows 11 Enterprise VM whose only user is a local account | **Unverifiable**: the multitenant hosting page is per user ("Users must have one of the below subscription licenses") and allows only dev/test for trial accounts. Ask Microsoft licensing (red-team M4) | [Multitenant hosting](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment) |

## 12. Open questions for the owner

**Answered 2026-10-05:** the owner agreed with every proposed answer below. Q1: only the confirmed hosts. Q2: document trusted devices. Q3: pick the route at A3 and mark it. Q5: no peering to the spoke. Q6: public access restricted to the NAT IP is the fallback. Q7: spike. Q8: PowerShell 5.1 + REST. Q11: its own template and run. Q10: CBA if a spike shows it works unattended, else TOTP. Q12: a 7-day blob container. **Answered 2026-10-05 (later):** Q4: no model access is held yet. Q10: no license for a test user yet. Q9: deferred to a red-team review of Track B.

**What that means for Track B.** It is **blocked on two prerequisites the repo can't supply**: approved access to a computer-use model (aka.ms/OAI/gpt54access, §7.4) and an AVD-eligible license for the test user (§10a). **Q9 is settled by the [red-team review](verify-access-redteam.md):** User Session Operator on a dedicated one-host check pool only, never the main, demo or QA pool (§10.6, §10.6a). The review also recommends (S1) keeping Track B **designed but unbuilt** until both prerequisites exist, then deciding whether the model's visual check is worth its standing cost, starting with a deterministic check that needs no model (S2).

1. **Q1, probe hosts:** add `rdweb.wvd.microsoft.com` and `client.wvd.microsoft.com` as informational and unconfirmed, or probe only the two confirmed hosts? *Proposed: only the confirmed ones.*
2. **Q2, consent prompt:** document trusted devices only (proposed), or have the post-deployment `-Fix` create a device group of the session hosts and register it with `targetDeviceGroups`? The second needs a new Graph permission in the operator's sign-in, and a group that tracks hosts.
3. **Q3, query route:** the Log Analytics query route is settled at A3 from the live docs. OK to pick it then and mark it in code?
4. **Q4, model:** `gpt-5.4` (2026-03-05) as the default, with newer models a parameter change. Have you applied for, or do you hold, access to any of them, and in which region?
5. **Q5, network isolation:** the sandbox gets its own VNet, **not peered to the landing zone spoke** (hub only in hub mode). This deviates from the brief's "peered spoke". Agree?
6. **Q6, Foundry public access fallback:** if the Responses API `computer` tool fails over the private endpoint, is public access restricted to the NAT IP (keyless) acceptable, or should Track B stop there?
7. **Q7, display spike:** OK to treat the console resolution and the unattended Windows App install as a B2 spike, with the web client as a fallback?
8. **Q8, harness language:** PowerShell 5.1 + REST (proposed, repo convention) or Python + the `openai` SDK (the brief's "official SDK")?
9. **Q9, logoff rights:** give the VM's identity Desktop Virtualization User Session Operator on the host pool, so it can log off leftover test sessions (and, in principle, anyone's)? Or rely on session time limits and a Track A warning?
10. **Q10, test identity:** CBA, after a spike, or TOTP? A license for the test user is needed either way. Is one available?
11. **Q11, entry point:** Track B as its own template and run (`bicep/agent/main.bicep`, proposed), rather than a flag in `main.bicep`. The brief says "behind a flag". This is a flag on the *run* (`deploy.sh --agent`, preflight `-FoundryCua`) and changes nothing in the default template. Agree?
12. **Q12, evidence:** a 7-day blob container (proposed), or keep evidence only on the VM's disk and fetch it with Run Command (cheaper, no storage account, lost when the VM is rebuilt)?

## 13. Phases

| Phase | Builds | Done when |
|---|---|---|
| **0** | This spec, decisions 0014 and 0015 | The owner has answered §12 |
| **A1** | `classifyReachability`, the probe in the Verify step, copy, Node tests | Node tests green; a manual check in a browser (not possible from CI) |
| **A2** | `context.launch` from the post-deployment and demo runs, `launchUrl`, the README schema, the PostDeployment scenario asserting `launch` | Pester, offline scenario and Node tests green |
| **A3** | `Test-AvdUserConnection.ps1`, `kql/user-connection.kql`, AzMock query route, `VerifyConnection` scenario (5 cases), portal `verify` branch, template test for `allLogs` | All CI checks green. Real sign-in still unverified until the owner runs it |
| **B0 spikes** (when Q4 and Q10 are met) | The S2 deterministic check; IMDS firewall by service SID (B23); the WDAC allowlist (B24); deterministic sign-in and CBA in Windows App (B25) | Each spike that fails changes the design before any module is written |
| **B1** | `bicep/agent/foundry.bicep` (account, project, deployment, private endpoint and zones), preflight `-FoundryCua` checks (including the target-pool rule), deploy-stage rollback | Builds and lints, PSRule clean, nothing created without `--agent` |
| **B2** | `bicep/agent/sandbox.bicep` (VNet, NAT or hub route, VM, Key Vault, storage with immutability), the broker and WDAC policy through the Run Command installer | Same, plus template tests for no peering to the spoke, no public IP, Trusted Launch, encryption at host, roles scoped to the agent group and the target pool |
| **B3** | Broker and harness, offline-tested against a mocked Responses API (observe-only rejection, safety check, budgets, kill switch, logoff in every exit path) | Pester green. No real Foundry call has been made |
| **B4** | Test identity as chosen, portal wiring, optional schedule | After the owner's B4 decision |

Each phase is one commit. Track A (A1–A3) is built. Track B is designed and red-teamed, and waits for model access and a test user license (§12); its first step is the B0 spikes.
