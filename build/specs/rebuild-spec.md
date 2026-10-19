# Rebuild spec: this landing zone from one prompt

This repo took 85 prompts to reach its first working deployment and post-deployment checks, and more after that (see the lessons). About a quarter of them fixed things that real Azure runs broke. This page tests how many prompts it takes **with hindsight**. It holds:

1. **The protocol:** how to run the experiment and count prompts, so the number means something.
2. **The prompt:** a single prompt to paste into a new Claude Code session on an empty repository. It carries the scope and design, plus every lesson from `build/lessons` written as a design rule.

The result is only a measurement if it follows the protocol. Until someone runs it, the number of prompts is unknown.

## Protocol

**Before you start**

- Use a **new, empty GitHub repository** and a **new Claude Code session**. Don't copy code from this repo; the prompt is the only input.
- Use a **clean subscription** in a tenant with Entra ID and Intune. This subscription can be reused after `Remove-AvdDemo.ps1 -IncludeLandingZone -ResetDefender`, with two caveats:
  - The purge-protected Key Vault stays soft-deleted for 90 days. The rebuild must recover it (rule 22 below).
  - Quota already raised and providers already registered make a rerun easier than a truly new subscription. Record which one you used.
- Let Claude open **and merge** its own pull requests, or work on one branch, so PR housekeeping doesn't count as prompts. Record which.

**What counts as a prompt**

Every message you type counts, including pasted command output, "continue" and answers to questions. Count every prompt, and label each one:

| Label | Meaning |
|---|---|
| spec | the prompt below |
| run | pasting the output of a command Claude gave you |
| fix | reporting or pasting something that didn't work |
| question | answering a question from Claude, or asking one |
| other | anything else, with a note |

**When to stop**

Stop when a member of the users group signs in to a desktop through the Windows App, **and** the post-deployment preflight reports Ready.

Record separately whether the FSLogix profile was created on the share. As of 2026-09-30 this repo itself fails that for cloud-only users; see "Known open issue" below.

**What to record**

- The number of prompts, by label.
- Wall-clock time from the first prompt to the sign-in.
- Every deployment attempt, with its result.
- Every lesson the rebuild rediscovered despite the prompt. That list is how you know which lessons the prompt failed to prevent.

## The prompt

Paste everything between the lines as the first message.

---

Build an Azure Virtual Desktop landing zone in this empty repository. I'll run what you give me in Azure Cloud Shell against my own subscription and paste the output back. You can't reach my tenant, so design everything so that one pasted output tells you what happened. Work on a branch and open and merge your own pull requests. Ask me only for things only I can do: run a command, sign in, approve something in my tenant. Once CI is green, carry on without waiting for me.

### Scope

- Greenfield and cloud-native: Entra ID-joined, Intune-enrolled session hosts. No AD DS, no Entra Domain Services, no line of sight to on-premises. One opinionated path, hardened fully. Brownfield and other identity models are out of scope.
- A personal project, not for production. MIT license. README, portal and entry-point code carry a notice: "provided as is, without warranty; not affiliated with the author's employer or with Microsoft; not for production use".
- American English throughout.

### Infrastructure (Bicep, subscription scope, pinned Azure Verified Modules)

- **`bicep/main.bicep`** orchestrates these modules:
  - `network`: spoke VNet with no default outbound access. Egress through a standalone NAT Gateway, or through a hub firewall when hub-peered (peering created both ways). NSG on the private endpoint subnet.
  - `privateDns`: the privatelink zones for standalone mode.
  - `monitoring`: Log Analytics, an AVD Insights DCR, alerts (unhealthy hosts, FSLogix errors, connection errors, Service Health).
  - `keyVault`: the break-glass local admin credential.
  - `storage`: Premium Azure Files for FSLogix.
    - Entra Kerberos (AADKERB), shared key access disabled.
    - SMB 3.1.1, Kerberos only, AES-256.
    - Private endpoint only; share RBAC for the users and admins groups; soft delete.
  - `backup`: Azure Backup of the profile share.
  - `controlPlane`: a pooled host pool with AVD Private Link, Start VM on Connect, scheduled agent updates, hardened RDP properties, weekday and weekend autoscale.
  - `sessionHosts`:
    - Windows 11 24H2 multi-session + M365, Trusted Launch, encryption at host, spread across zones, AMA.
    - Registered and FSLogix-configured by managed Run Commands, with no post-deployment scripts on the host.
  - `governance`: policy guardrails (allowed locations, tag inheritance), Defender for Cloud, budget, activity log export.
  - `autoShutdown`: an Automation runbook that stops hosts on a schedule and locks them off when the budget is exceeded, with a Resume action.
- **`bicep/demo/main.bicep`:** a demo host pool inside a deployed landing zone.
- **Parameter files:** `parameters/dev.bicepparam`, `test.bicepparam` and `prod.bicepparam`. `test` sits beside `dev` in the same subscription and leaves the subscription-wide pieces (policy, activity log) to `dev` (`deploySubscriptionSettings = false`).
- **Tenant values and sizing come from environment variables:**
  - groups and service principal: `AVD_USERS_GROUP_ID`, `AVD_ADMINS_GROUP_ID`, `AVD_SERVICE_PRINCIPAL_ID`;
  - region: `AVD_LOCATION`;
  - sizing: `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT`, `AVD_PROFILE_QUOTA_GIB`;
  - power: `AVD_START_VM_ON_CONNECT`, `AVD_AUTO_SHUTDOWN_TIME`.
- **Defaults:** memory-optimized `Standard_E4as_v5` on Premium SSD, one host for the smallest kit.

### Operator tooling (Azure Cloud Shell)

- **`scripts/deploy/deploy.sh`:**
  - Registers providers and features, looks up groups by name, and deploys.
  - Flags for sizing and power.
  - Generates the break-glass password; never asks for it.
- **`scripts/ops/Test-AvdLandingZoneReadiness.ps1`** has two stages, each checking and, with `-Fix`, repairing:
  - **`-PreDeployment`:**
    - tooling, and the Entra groups (created with `-Fix`);
    - providers and the EncryptionAtHost feature;
    - VM size availability and vCPU quota;
    - the name being free, soft-deleted Key Vaults;
    - sizing validation and a cost estimate at retail list prices.
  - **Post-deployment:**
    - the resources and RBAC;
    - admin consent for the storage app, and the `kdc_enable_cloud_group_sids` tag on it;
    - the Conditional Access exclusion for the storage app;
    - the profile share root ACL, set through the Azure Files REST API from a session host.
  - **`-WellArchitected`:** reviews the deployed landing zone by pillar, as warnings only.
- **`scripts/ops/Deploy-AvdDemo.ps1`:** a demo host pool, plus sign-in validation.
- **`scripts/ops/Remove-AvdDemo.ps1`:** cleanup, `-WhatIf`-safe.
  - `-IncludeLandingZone` removes everything.
  - It keeps what another landing zone in the subscription still uses.
- **Every script ends with a machine-readable state line,** `<<<AVDLZ-STATE {json} AVDLZ-STATE>>>`: stage, status, context, counts, failures and warnings, each with an id and data.

### Deployment portal (static GitHub Pages site, `site/portal`)

- **Steps:** region by browser latency → size → cost → pre-deployment → deploy → post-deployment → sign in. They scroll horizontally, and each step appears only once it's reached.
- **Size:** a host count, defaulting to 1.
- **Cost:** its own page. Start VM on Connect and auto-shutdown toggles reprice from the preflight's unit prices.
- **Commands:** it gives a self-contained Cloud Shell block for each step. It reads the pasted output (the state line and known ARM error codes) and says what to run next.
- **Privacy:** pasted output never leaves the browser.
- **Report a problem:** redacts private values in the browser and opens a prefilled GitHub issue.
- **Deployment settings:** a link in the header; the parameter file sets the environment.
- **Engine:** `portal-core.js`, UMD, tested with `node --test` against fixtures of real output.

### Quality

- **CI checks:**
  - `bicep lint` and `bicep build-params`, with strict linting where security rules are errors;
  - PSScriptAnalyzer and shellcheck;
  - PSRule for Azure, Well-Architected rules;
  - Pester: unit tests, offline end-to-end scenarios and template guards;
  - node tests for the portal;
  - a subscription what-if on PRs.
- **Offline scenarios** run the real scripts against a mock of ARM, Graph and the price API. The mock must never be more permissive than Azure: omit empty properties the way ARM does.
- **Every real-run failure gets:**
  - a fix;
  - a guard (a test, scenario or preflight check);
  - a lesson under `build/lessons`.

  Record design choices under `build/decisions`.

### Design rules from real runs

Build these in from the start. Each one cost at least one failed run last time.

1. The AVM NAT Gateway public IP defaults to zones 1–3. Set zones from the region, and test a region without zones.
2. The break-glass password only matters at VM creation. Generate it, store it in Key Vault, and never make the operator remember it.
3. Choose the region by latency from the user's browser, not from Cloud Shell.
4. `readEnvironmentVariable` returns `''` when a variable is set but empty. Guard every optional variable with `empty()`.
5. `Get-AzResourceProvider -ProviderNamespace` returns one object per region. Collapse the results before judging registration.
6. Registering providers and EncryptionAtHost blocks and is slow:
   - print a line before anything slow;
   - re-register Microsoft.Compute after the feature;
   - say "Fixed" only when the change is done.
7. Microsoft Graph in Cloud Shell:
   - never pipe `Connect-MgGraph` to `Out-Null`, because that hides the device code;
   - verify the sign-in with a real request;
   - identify the Azure user with `Get-AzADUser -SignedIn`;
   - warn if Graph and Azure are signed in as different accounts.
8. Every loop over remote calls ends on an error, an empty page or a page cap.
9. Emit items, not a single array object. Watch PowerShell array unrolling in helpers and tests.
10. Private endpoints live in their target's resource group.
11. Azure Files REST with OAuth:
    - send `x-ms-date` on every request, and `x-ms-file-request-intent: backup`;
    - a new share root has no permission key: treat that as the default ACL (a finding), not an error;
    - Windows PowerShell 5.1 keeps error bodies on the response stream.

    Set the root ACL from a session host, using its managed identity with a temporary role.
12. When an external API fails, the first version prints everything it returned: step, HTTP status, error code, body and headers. Diagnose before fixing.
13. New subscriptions have no quota for most VM families. Check quota per family and regionally, and generate the Microsoft.Quota increase request.
14. Check every cmdlet's parameter sets and output shapes against the docs. Prefer ARM and Graph REST where a cmdlet reshapes data or blocks.
15. Commands for operators are self-contained Cloud Shell blocks: clone or update the repo, `Set-Location`, and `Connect-MgGraph` when needed.
16. CI's PSScriptAnalyzer is newer than most local ones. Use approved verbs and singular nouns.
17. Don't reset a shared branch over an unmerged PR.
18. Follow PSRule for Azure's specifics, and suppress a rule only with a written reason.
19. Watch the Bicep authoring traps:
    - no runtime values in loop resource names (BCP178);
    - `existing` references for built-in policy definitions;
    - no `readEnvironmentVariable` defaults for secrets.

    Keep the linter strict; fix causes, don't suppress rules.
20. The offline harness provides every tool it touches; don't depend on the machine's tools.
21. ARM leaves out empty properties, and `@($null).Count` is 1. Count with `@($x | Where-Object { $_ }).Count`.
22. A purge-protected Key Vault left soft-deleted by cleanup blocks redeploys. The preflight's `-Fix` recreates its resource group and recovers the vault.
23. Deleting a resource group only soft-deletes its Log Analytics workspace, and a same-name redeploy recovers it with broken tables. Cleanup must delete the workspace permanently first.
24. A deployed host's vCPUs are already counted in quota "used". The post-deployment quota check must not count them twice.
25. The retail price list has lookalike meters: CloudServices products share VM SKU names, and Premium Page Blob shares disk meter names. Match on the product as well as SKU and meter, and print the product when a match fails. Price a line only when exactly one meter matches, otherwise report the meters seen. Never guess a price.
26. Entra Kerberos over a private endpoint:
    - add the privatelink names to the storage app's identifier URIs;
    - cleanup must purge the storage app and its service principal from Entra's deleted items, because the storage account name is deterministic and the app's names would otherwise be claimed twice. They appear there as soon as the storage account is deleted; wait for them with a capped loop.

### Acceptance

1. The pre-deployment preflight with `-Fix` reaches Ready.
2. `deploy.sh` succeeds on the first attempt.
3. The post-deployment preflight with `-Fix` reaches Ready.
4. A member of the users group signs in to a desktop through the Windows App.
5. FSLogix creates the profile on the share. Record the result either way; see "Known open issue".
6. Cleanup removes everything, and a second deployment with the same name prefix succeeds.

---

## Known open issue

On 2026-09-30 in this repo, a cloud-only user's Kerberos sign-in to the profile share was rejected at SMB `SESSION_SETUP` with `STATUS_ACCESS_DENIED`. The server's metrics counted it as `SessionSetup / Kerberos / ClientOtherError`.

The following didn't change the result:

- the private link names;
- purging a leftover deleted storage app;
- opening share-level and root permissions to the user;
- re-keying Entra Kerberos;
- rebooting the host and signing in again.

It is with Microsoft support; see the root cause, when known, in `build/lessons`. Until then, acceptance criterion 5 may fail in a rebuild for the same reason. The desktop still works with a local profile. Record the result rather than treating it as a failure of the prompt.

Rule 26 is included as good practice for private endpoints. It is **not** proven to be required for sign-in.
