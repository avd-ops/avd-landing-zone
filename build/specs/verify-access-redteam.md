# Red-team review: Track B, the computer-use agent

- **Reviewed:** [verify-access-spec.md](verify-access-spec.md) §7–§10c as of 2026-10-05 (decision 0015, Proposed). Track A is built and is reviewed here only where Track B depends on it.
- **Method:** follow the agent's run end to end (start, sign-in, desktop, checks, sign-out, evidence) and ask, at each step, what a prompt-injected or simply wrong model can make the sandbox do with the identity and the network it has. Microsoft's guidance is the baseline: screenshots are untrusted input, and computer use belongs on an isolated, low-privilege machine with no sensitive data or credentials. Every finding has a scenario and a fix. Nothing here has been tried against a real tenant, and Track B is blocked on model access and a test user license (spec §12).
- **Also settles:** Q9, logoff rights for the agent's identity, which the owner deferred to this review.

## Verdict

The isolation of the *network* is sound: own VNet, no peering, no public IP, keyless Foundry. The isolation of the *machine* is not. As written, the model drives the same desktop that holds a managed identity able to read the test user's secrets, call Foundry and (with Q9) log off users. And once signed in, it drives a session on the landing zone's pooled hosts, beside real users. Three findings would make the agent itself the most privileged thing in the landing zone that an attacker can steer from a web page:

- the model can reach the VM's managed identity through the desktop it controls (C1);
- the credential guard trusts the foreground window, which the remote desktop also is (C2);
- after sign-in, the model acts as a user on a production pooled host (C3).

The fixes make the agent **observe-only after a deterministic sign-in**, put the identity in a broker the agent's session can't reach, and point the agent at a **dedicated pool**. They also shrink what the model adds over Track A's telemetry, which makes the strategic finding S1 sharper: Track B should stay designed but unbuilt until its prerequisites exist and its remaining value is confirmed.

| Severity | Count |
|---|---|
| Critical: the safety claim doesn't hold | 3 |
| High: wrong in a likely case | 6 |
| Medium: gaps and inconsistencies | 6 |
| Strategic | 2 |

## Critical

### C1. The model can use the VM's managed identity through the desktop it controls
**Where:** §9 "system-assigned managed identity", "Harness … scheduled task at that user's logon, in session 1"; §10.2 "kill switch: read the VM's tags from IMDS"; §10.3 Key Vault read by "the VM's identity".
**Scenario:** the model's actions are mouse and keyboard on the sandbox's own desktop, not only inside the AVD client. Any process on the VM can ask IMDS (`169.254.169.254`) for the managed identity's token: no permission, no secret. A screenshot that carries an instruction ("press Win+R, type `powershell`…") gets the model to open a shell as `avdagent` and ask IMDS for a token for Key Vault, then read the test user's password and TOTP seed, and send them anywhere through the any-443 egress (§8). The same token calls Foundry on the account's budget and, with Q9's role, logs off users. `pending_safety_checks` won't reliably catch it: the domain checks evaluate a browser URL, and this happens outside any browser.
**Fix:**
- **A broker holds the identity, never the agent's session.** A local service in session 0, running as its own virtual service account, makes every Azure call: Foundry, Key Vault, evidence upload, ARM logoff. The harness in session 1 talks to it over a named pipe with a fixed set of verbs: next action for this screenshot, enter this credential kind, store this evidence, finish. There is no verb that returns a token or a secret.
- **Outbound default-deny, not an IMDS block** (Copilot review). Windows Firewall block rules override allow rules, so "block IMDS except for the broker" can't be expressed. Instead, every profile's default outbound action is **Block**, and the only allow rules are:
  - the broker's service SID: IMDS (`169.254.169.254`) and the three private endpoints;
  - Windows App and its WebView2 sign-in, by program path: TCP 443 and UDP 3478 (TURN) to the internet;
  - the DNS Client service: DNS.
  Nothing else on the VM, including anything the model might start, can reach IMDS or the internet. **If the B0 spike can't enforce this while Windows App still works, Track B stops**, or the broker moves off the VM: an Azure Function in the agent VNet with its own identity, and a sandbox VM with no managed identity at all. The boundary is never weakened to make the spike pass.
- **An application allowlist for the agent's session.** App Control for Business (WDAC) in enforced mode: Windows App (by publisher), the harness, Explorer, and nothing else. No PowerShell, cmd, Run dialog, browser or Store for `avdagent`. Test at B2 that Win+R and the Start menu can't launch anything outside the list.
- **Least privilege per secret:** Key Vault Secrets User on each secret, held by the broker's identity (it is the VM's, but only the broker can get a token).
- A template test fails if the sandbox VM's identity holds any role outside the agent resource group, except Q9's (below).

### C2. The credential guard trusts the foreground window, and the remote desktop is that window
**Where:** §10.3 step 1 "checks that the foreground window belongs to the expected client or `login.microsoftonline.com`".
**Scenario:** after the session starts, the foreground window is the Windows App, which shows the remote desktop. Anything rendered on that desktop, such as a web page, a dialog, or a phishing form from a compromised profile or a malicious notification, can ask for "your password". The model calls `enter_credential(password)`. The guard sees the expected client in front and types the test user's password into the session, where whatever asked for it can read it. The same applies to the TOTP code. The window check can't tell the client's own sign-in UI from pixels the remote session draws inside it.
**Fix:**
- **Sign-in is deterministic and happens before the model sees anything.** A trusted sign-in step of the harness, in session 1 (UI Automation only works within the session; a session-0 broker can't drive it, Copilot review), launches Windows App, subscribes with the test user, and answers the Entra prompts through UI Automation on the sign-in web view. That view is a separate top-level window owned by Windows App, with `login.microsoftonline.com` as its URL. It never types into the client's main window.
  - With TOTP, the harness gets each credential from the broker through a **one-shot verb**. The broker closes it for the rest of the run the moment the harness reports the session window, or after 5 minutes, whichever comes first. The model is engaged only after that, and its actions are executed by the same harness, which accepts nothing but `screenshot` and `wait` (C3). So nothing the model does can reach the verb.
  - With CBA there is no credential verb at all.
- **No `enter_credential` tool at all.** The model gets control only once the harness has seen the session window, and from then on it can't trigger any credential entry. This also removes the open question B6 (mixing a function tool with the `computer` tool).
- **Prefer CBA (§10a).** With certificate-based authentication there's nothing to type and nothing to steal by typing. TOTP stays the fallback.
- If deterministic sign-in proves too brittle in the B3 spike, Track B stops there. The fallback is not to let the model type secrets.

### C3. After sign-in, the model acts as a user on the landing zone's pooled hosts, beside real users
**Where:** §10.5 "Task prompt: open the desktop…, report what's visible"; §10.6 logoff "on the host pool"; §10a "assigned … on the desktop app group".
**Scenario:** the test user is assigned to the landing zone's desktop, so the agent's session lands on a production session host shared with real users. A prompt in the session (a page that opens at logon, a shared file, a notification) makes the model click, type and browse inside that host as the test user, with the host's egress and the user's access to the profile share. Whatever the session can do, an injected instruction can do. The "fixed task prompt" constrains a well-behaved model only.
**Fix:**
- **Observe-only after connect.** Once the session window is up, the harness accepts only `screenshot` and `wait` from the model, plus one harness-owned sign-out. Clicks, typing, scrolling and key presses inside the session are rejected and recorded as an attempted action (`status: needsreview`). The checklist (§10.7) is answered from screenshots alone. That is enough for "desktop appeared, no error dialog, expected icons present".
- **A dedicated check pool, never the main pool, and not the demo or QA pool** (Copilot review). `Deploy-AvdDemo.ps1` assigns the demo desktop and VM login to the landing zone's AVD Users group and reuses the production profile share. Decision 0013's QA pool is used by QA users. Real users can reach both. So the target is a **one-host agent check pool**:
  - its own desktop app group, assigned only to the test user's group;
  - local profiles (no FSLogix share, so no path to real users' profiles);
  - the same image and host template as the main pool, so what it checks still means something.
  The preflight with `-FoundryCua` fails if the test user's group can reach any other app group, or if anyone else can reach this one. The trade-off: the agent checks a pool built like the main one, not the main pool itself; Track A covers the main pool from real devices. It costs one more host while it runs (deallocated between runs).
- **Q9 settled by this:** the broker's identity gets **Desktop Virtualization User Session Operator on the check pool only**. Only the test user can be on that pool, so the role can't affect real users. On every other pool: no ARM rights, ever. A template test asserts the role's scope.

## High

### H1. The kill switch is slower than the run
**Where:** §10.2 step 1, §10.5 "VM tag `avdlz-agent=off` (read each iteration)".
**Scenario:** IMDS serves tags from instance metadata, which isn't documented to update immediately after a tag change (unverified). A run can finish before the tag is seen. Deleting the model deployment is a hard stop, but it takes the account offline for every run.
**Fix:** keep the tag as the soft stop and document its latency as unverified. The real hard stops are **deallocating the VM** and **removing the broker identity's Foundry role**. Both are one portal click or one command, and both are listed in the runbook. The wall-clock cap stays the bound that always holds.

### H2. Safety checks don't cover the paths that matter here
**Where:** §10.4.
**Scenario:** `irrelevant_domain` and `sensitive_domain` evaluate `current_url`. With Windows App there's no browser URL to evaluate, and after C3 the model can't navigate anyway. `malicious_instructions` is a model-side heuristic. Treating "no pending checks" as "nothing happened" overstates the protection.
**Fix:** keep the rule (never acknowledge; stop with `needsreview`), and state that the harness's own controls are what holds: observe-only after connect, the allowlist, the broker. Rejected action attempts are reported the same way as safety checks.

### H3. Remote access to the sandbox ends the run, and a run ends remote access
**Where:** §9 "Operator access … Bastion Developer … for watching a run", "Screen lock off", "Autologon".
**Scenario:** Windows 11 Enterprise single-session has one interactive session. A Bastion (RDP) sign-in takes the console from `avdagent`. The harness's desktop disconnects, and screenshots go black or fail, mid-run. Conversely, Autologon takes the console back at the next reboot.
**Fix:** no live watching. The evidence (screenshots and the action log) is how people observe a run. Bastion is for maintenance only, and the harness refuses to start while a non-`avdagent` session exists. When the console session disconnects mid-run, the harness aborts with `status: aborted` and a reason, and signs out through ARM.

### H4. Conditional Access for the test user needs licenses and may block itself
**Where:** §10a "A Conditional Access policy targeting this user … from the agent's NAT IP only".
**Scenario:** Conditional Access needs Microsoft Entra ID P1 for the user. A sign-in from a datacenter IP by an account that signs in on a schedule can look automated or risky to Identity Protection (P2), and risk-based policies can block or force a password change the harness can't do.
**Fix:** state the licensing: P1 for CA, plus the AVD-eligible license (many AVD-eligible bundles include P1; to confirm per bundle). Exclude the test user from risk-based policies only. Alert on any risk detection for it, so a block shows up as a finding, not a silent failure. Record this in §10a.

### H5. Nothing caps the spend across runs
**Where:** §10.5 token budget "per run"; §10c.
**Scenario:** a schedule plus retries on failure, or a stuck run restarted by hand, multiplies the per-run budget. Screenshots dominate the tokens, and the per-token prices aren't confirmed (§11 B13).
**Fix:**
- A daily run cap (default 4).
- Three failed or aborted runs in a row disable the schedule.
- A budget on the agent resource group, reusing decision 0011's pattern. Its alert deallocates the sandbox and disables the schedule.
- The state line carries the run's `usage`, so cost per run is measured.

### H6. Rollback deletes and purges by name
**Where:** §7.4 step 4.
**Scenario:** the stage 1 cleanup deletes and purges "the half-created account". A name collision with an account from an earlier run, or a typo in the name, purges the wrong account irreversibly.
**Fix:**
- Delete only an account whose tags carry this run's deployment name, created in this run (`createdAt` after the run started).
- Purge only after the delete, and only by the exact name and location from the delete response.
- Print what will be purged under `-WhatIf`.
- An offline scenario covers a foreign account with the same name.

## Medium

| # | Finding | Fix |
|---|---|---|
| M1 | **Evidence hashes typed text** (§10.8). A hash of a short secret or a TOTP code can be guessed offline. | Record the action kind only for any typing, never a hash. After C2 the model never types anyway. |
| M2 | **Evidence uploads with the VM's identity** (§10.8), which C1 makes reachable. | The broker uploads. The container gets a write-once (immutability) policy for the 7-day retention, so a run can't rewrite earlier evidence. |
| M3 | **A pinned model version retires** (§7.2). The deployment and the runs break on the retirement date. | The preflight reads the model's lifecycle (`lifecycleStatus`, `deprecation.inference`, per-SKU `deprecationDate`, confirmed in the Models API docs, spec §11 B26) from the region's model list and warns 60 days ahead. A version change is a PR. |
| M4 | **Windows 11 licensing for a workgroup VM** (§9). Multitenant hosting rights are per user. The VM's user is a local account, so which license covers it isn't obvious. | Mark it unverified, and ask at B2. If it can't be settled, the sandbox becomes the target pool's own client-less check (S2) or Windows 365 for Agents (§10b). |
| M5 | **Who starts the sandbox for a schedule** (§9 Power). The spec says "the scheduled run starts it" but names no identity. That would be a new automation identity with start rights. | Reuse decision 0011's Automation account and runbook pattern: a schedule calls a runbook with Virtual Machine Contributor scoped to the sandbox VM only. That's a new role assignment, listed in the decision. |
| M6 | **Track A shows the agent's sign-ins.** `Test-AvdUserConnection.ps1` filters by user, but a person reading WVDConnections or AVD Insights sees scheduled test sign-ins as real usage. | Tag the test user clearly (display name `AVD agent (test)`), exclude it in the image pipeline's QA-usage counts (`qa-pool-unused`), and say so in operations.md. |

## Strategic

### S1. After the fixes, the model adds little over Track A, at real cost and risk
With observe-only after a deterministic sign-in, the model's job is to look at screenshots and say whether the desktop looks right. Track A's telemetry already proves the connection reached the desktop, from the user's real device and for free. What's left is the visual check: no error dialog, the profile loaded, and expected icons present. That's worth having, but it costs:
- a Foundry account, a gated model, a sandbox VM with WDAC and a broker, a NAT Gateway and three private endpoints;
- a test user with two entitlements, AVD-eligible and Entra ID P1 (possibly one bundle);
- screenshots of the desktop sent to a model endpoint.

**Recommendation:**
- Keep Track B designed, with these fixes folded in, and **don't build it** until both prerequisites exist (Q4, Q10).
- Then decide whether the visual check is worth that standing cost, compared with S2.
- This is the brief's own scope-creep rule (risk 8) applied honestly.

### S2. A deterministic visual check might do the job without a model
The checklist ("desktop appeared, no error dialog, icons present") is a fixed comparison: take a screenshot after sign-in, then match known UI elements through UI Automation on the client, or compare against a reference image. That needs no Foundry, no model access and no data sent to a model. It still needs the sandbox, the test user and the broker, so the broker design applies to both. **Recommendation:** when Track B is unblocked, spike S2 first. Use the model only if the deterministic check can't tell a good desktop from a broken one often enough.

## Status

| Finding | Status |
|---|---|
| C1 Identity reachable from the agent's desktop | **Resolved in spec**: broker service holds the identity; outbound default-deny with broker-scoped IMDS, a stop condition if B0 can't enforce it, off-box broker as the alternative; WDAC allowlist (§9, §10.2, §10.3). Revised after Copilot review |
| C2 Credential guard trusts the foreground window | **Resolved in spec**: deterministic sign-in by a trusted session-1 harness step before the model acts; one-shot credential verb closed at the session window; no credential tool; CBA preferred (§10.3, §10a). Revised after Copilot review |
| C3 Agent acts on production pooled hosts | **Resolved in spec**: observe-only after connect; a dedicated one-host check pool (not demo, not QA); Q9 = User Session Operator on that pool only (§10.5, §10.6, §10.6a). Revised after Copilot review |
| H1 Kill switch latency | **Resolved in spec**: deallocation and role removal as hard stops; tag latency marked unverified (§10.5) |
| H2 Safety checks overstated | **Resolved in spec**: harness controls named as what holds; rejected actions reported like checks (§10.4) |
| H3 Bastion vs the console session | **Resolved in spec**: evidence instead of watching; refuse to start with another session; abort on disconnect (§9) |
| H4 CA licensing and risk policies | **Resolved in spec**: P1 stated, risk-policy exclusion with alerts (§10a) |
| H5 No spend cap across runs | **Resolved in spec**: daily cap, auto-disable after three failures, a budget that deallocates (§10.5, §10c) |
| H6 Rollback purges by name | **Resolved in spec**: delete only this run's tagged account; purge from the delete's response; `-WhatIf` (§7.4) |
| M1–M6 | **Resolved in spec** (§10.8, §7.2, §9, §10a); M4 stays unverified; M3's lifecycle API is confirmed (spec §11 B26) |
| S1 Value over Track A | **Accepted as the recommendation**: designed, not built, until Q4 and Q10; then decide against S2 (§12, §13) |
| S2 Deterministic visual check | **Resolved in spec**: the first spike when Track B is unblocked (§13) |

## Next step

Nothing in Track B is built. When model access (Q4) and a test user license (Q10) exist, start with the B2/B3 spikes this review adds: the IMDS firewall rule by service SID, the WDAC allowlist, deterministic sign-in through UI Automation, CBA in Windows App, and S2. Each spike that fails changes the design before any module is written.
