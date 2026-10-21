# Cloud-native AVD Landing Zone

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

An **enterprise-ready Azure Virtual Desktop landing zone for greenfield, cloud-native organizations** — Entra ID-joined, Intune-managed, private by default, and deployed end to end from one Bicep template.

> [!WARNING]
> **Personal project. Research and learning only. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer**, and it does not represent my employer's views, products or guidance. It is also not an official Microsoft product.
> - **Do not run it in production** or against subscriptions and tenants that matter. Test it first in a dedicated lab subscription and tenant.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk: you are responsible for what it deploys, for the Azure charges it incurs, and for reviewing the code before you run it.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

It is deliberately *not* a general-purpose accelerator. Microsoft's [AVD Landing Zone Accelerator](https://github.com/Azure/avdaccelerator) (LZA) covers every identity model and brownfield scenario through a wide option surface. This repo makes the opposite trade: **one opinionated path — no domain controllers, no line of sight to on-premises, no post-deployment scripts** — and hardens that path fully. See [`docs/design-decisions.md`](docs/design-decisions.md) for the side-by-side.

## What you get

| Area | What's deployed | Why it matters |
|------|-----------------|----------------|
| **Identity** | Session hosts Entra ID-joined and Intune-enrolled; Entra SSO; VM User/Admin Login RBAC; break-glass local admin stored in Key Vault | No AD DS or Entra Domain Services to run; devices managed like every other endpoint |
| **Profiles** | Premium Azure Files (ZRS) with **Entra Kerberos**, shared-key access disabled, SMB 3.1.1 + AES-256, private endpoint, share RBAC, soft delete, **Azure Backup** | FSLogix without storage keys, domain joins or a management VM |
| **Session hosts** | Memory-optimized E-series on Premium SSD (sized per workload in the portal), Trusted Launch (Secure Boot + vTPM), encryption at host, zone-spread, Windows 11 24H2 multi-session + M365, AMA + AVD Insights, Guest Configuration | Secure by default; registered and FSLogix-configured **declaratively** by managed Run Commands |
| **Control plane** | Pooled host pool with **AVD Private Link** for session hosts, Start VM on Connect, scheduled agent updates, hardened RDP properties, weekday/weekend autoscale | Hosts reach AVD privately; idle cost is scaled away |
| **Network** | Spoke with **no default outbound access**: NAT Gateway (standalone) or hub firewall (hub-peered, peering created both ways); NSG on the private endpoint subnet; private DNS | Egress is always explicit, which suits the retirement of Azure's default outbound access |
| **Operations** | Log Analytics, AVD Insights DCR, diagnostics on every resource, alerts (unhealthy hosts, FSLogix errors, connection errors, low disk, low memory, high CPU, Service Health), activity log export | Day-2 visibility from day 1 |
| **Governance** | Azure Policy guardrails (allowed locations, tag inheritance), Defender for Cloud (Servers P2, Storage, Key Vault), subscription budget | The subscription arrives governed |
| **Auto shutdown** | An Automation runbook stops the session hosts on a schedule and locks them off when the budget is exceeded (Resume undoes it) | Spend stops when the budget runs out, not at the end of the month |
| **Delivery** | Strict Bicep linting, PSScriptAnalyzer, shellcheck, PSRule for Azure, subscription what-if on PRs, environment-gated deploy workflow (OIDC) | Changes are reviewed as code and promoted with approvals |
| **Well-Architected** | PSRule's Well-Architected rules gate every template change; `-WellArchitected` reviews the **deployed** landing zone by pillar (design checks, Advisor, Defender for Cloud, Policy, PSRule on live resources) | Know where a deployment stands against a review, and what the dev settings trade away |

Everything is built from pinned [Azure Verified Modules](https://aka.ms/avm).

## Quick start

**Easiest path: the [deployment portal](https://avd-ops.github.io/avd-landing-zone/portal/).** It picks the closest region by measuring latency from your browser, sizes the host pool from how many people use it (and the preflight prices that at Azure list prices for the region), gives you each command to paste into Cloud Shell, and reads the output you paste back to tell you what to run next, all the way to signing in. Pasted output never leaves your browser. If you get stuck, **Report a problem** turns the output into a GitHub issue, with private details removed in your browser first.

Prerequisites (details in [`docs/deploy.md`](docs/deploy.md)):
- A **dedicated subscription** where you are Owner, plus Azure CLI ≥ 2.65.
- Two Entra ID security groups: AVD users and AVD admins.
- Intune licensing in the tenant (or set `enrollInIntune = false`).
- vCPU quota for the session host size in your region.

```bash
az login && az account set --subscription "<subscription-id>"

# Preflight first (Cloud Shell, PowerShell): repeat until clean; -Fix registers providers,
# creates the groups and the AVD service principal
# (-Location <region> checks another region than the file's default, northcentralus)
pwsh ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile parameters/dev.bicepparam \
  -UsersGroup "AVD Users" -AdminsGroup "AVD Admins"

# What-if (-l is the region the landing zone is deployed to)
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins" --what-if

# Deploy (≈30-45 min the first time)
./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
  --users-group "AVD Users" --admins-group "AVD Admins"
```

Then finish the three one-time tenant steps (admin consent for the storage account's Entra app, a Conditional Access exclusion, and NTFS hardening) from Azure Cloud Shell. The preflight checks them and `-Fix` applies them:

```powershell
./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix
./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix avdlz -Environment dev -TestUserUpn you@contoso.com   # optional demo + sign-in validation
```

See [`docs/operations.md`](docs/operations.md). Users in the AVD Users group can then sign in through the Windows App.

## Repo layout

The repo is split by who it is for. **If you only want to deploy and run the landing zone, you need the top-level folders `bicep/`, `parameters/`, `scripts/`, `contracts/` and `docs/`**, which is exactly what the zip on each [release](releases/README.md) holds. `site/` is the website and `build/` is how the project itself is built and tested.

```
avd-landing-zone/
├── bicep/                         # what you deploy
│   ├── main.bicep                 # subscription-scope orchestration
│   ├── demo/main.bicep            # demo host pool inside a deployed landing zone
│   ├── portal/                    # optional: your own copy of the deployment portal (Static Web Apps or storage)
│   ├── images/                    # golden image gallery and monthly build
│   └── modules/                   # governance, monitoring, network, privateDns, keyVault,
│                                  # storage, backup, controlPlane, sessionHosts, autoShutdown
├── bicepconfig.json               # linter: security rules are errors
├── parameters/                    # dev, test, prod, images: tenant values come from environment variables
├── scripts/
│   ├── deploy/deploy.sh           # providers, features, lookups, deploy
│   ├── ops/                       # Cloud Shell: preflight (-Fix), demo deploy + validation, cleanup, image build
│   ├── automation/                # auto shutdown runbook
│   ├── image/                     # golden image customization steps
│   └── sessionhost/               # embedded into Run Commands at compile time
├── contracts/                     # vendored avd-second-brain contracts the scripts read
├── docs/                          # how to deploy, operate and understand it
├── releases/                      # how to get a released version, and each release's notes
│
├── site/                          # the website (GitHub Pages, .github/workflows/pages.yml)
│   ├── index.html, family/        # redirects to the avd-ops site (avd-ops.dev)
│   ├── portal/                    # the deployment portal
│   └── region-latency/
│
├── build/                         # how the project is built: not needed to use it
│   ├── tests/                     # Pester unit tests, offline scenarios, template guards; portal tests
│   ├── lessons/                   # what real runs taught, each with its guard
│   ├── decisions/                 # why things are the way they are
│   └── specs/                     # design specs and their red-team reviews
├── scripts/kb/                    # knowledge capture and handoff hooks (left out of releases)
├── ps-rule.yaml, .ps-rule/        # PSRule for Azure (CI, and the -WellArchitected review)
└── .github/workflows/             # validate, deploy, image-build, pages, secret-scan, lanes
```

## Documentation

**Using it**

- [`docs/design-decisions.md`](docs/design-decisions.md): the opinions this repo takes and how it compares with the LZA
- [`docs/architecture.md`](docs/architecture.md): resource layout, traffic flows, identity and RBAC model
- [`docs/deploy.md`](docs/deploy.md): prerequisites, deployment, post-deployment steps, scaling out, teardown
- [`docs/operations.md`](docs/operations.md): preflight with fix mode, Well-Architected review, demo host pool with sign-in validation, cleanup
- [`docs/images.md`](docs/images.md): golden images, step 1: setting up and running the monthly image build
- [Deployment portal](https://avd-ops.github.io/avd-landing-zone/portal/) ([how it works](site/portal/README.md)): region by latency, then the next command from each pasted Cloud Shell output; or [publish your own copy](docs/operations.md#your-own-copy-of-the-portal-optional) into your subscription
- [`docs/demo.md`](docs/demo.md): a live demo in a 30-minute slot (dev built the night before, test deployed live beside it)
- [avd-ops site](https://avd-ops.dev/) ([source](https://github.com/nickprignano/avd-ops)): one page for this repo and its four siblings (avd-current-state, avd-swarm, avd-second-brain, avd-liquidware) and how they fit together
- [`docs/ci.md`](docs/ci.md): validation and deployment pipelines, OIDC setup
- [`docs/gotchas.md`](docs/gotchas.md): the things that bite
- [`docs/out-of-scope.md`](docs/out-of-scope.md): what this repo does not do
- [`docs/setup-azure-account.md`](docs/setup-azure-account.md): starting from zero on a personal card (lab use)
- [`CHANGELOG.md`](CHANGELOG.md): what changed, from each merged PR's `Changelog:` line
- [`releases/`](releases/README.md): released versions and how to pin one
- [avd-second-brain](https://github.com/nickprignano/avd-second-brain): the second brain for the whole AVD lifecycle, shared with avd-current-state and the assessment project. Its [operations spec](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) is this landing zone's self-healing, self-learning brain (moved there; the runtime still deploys from here). What this repo exchanges with it: [`docs/second-brain.md`](docs/second-brain.md)

**Building it**

- [`build/lessons`](build/lessons/README.md): what real deployments taught, each with the guard that now catches it
- [`build/decisions`](build/decisions/README.md): the choices that shape the repo, and why
- [`build/specs/image-pipeline-spec.md`](build/specs/image-pipeline-spec.md): proposed spec for a golden image pipeline (Azure Image Builder → Compute Gallery) and blue/green host rotation
- [`build/specs/verify-access-spec.md`](build/specs/verify-access-spec.md): verifying access from the operator's device
- [`build/specs/rebuild-spec.md`](build/specs/rebuild-spec.md): one prompt to rebuild this from an empty repo, with the protocol to count the prompts it takes

## Entry points

Each links its reference page, generated from the script's help or the template's `@description`s by the second brain's [Update-BrainDocs.ps1](https://github.com/nickprignano/avd-second-brain/blob/main/scripts/Update-BrainDocs.ps1). Edit the help, not the page.

<!-- generated:entry-points begin -->
<!-- Generated by scripts/Update-BrainDocs.ps1. Do not edit between the markers; edit the source and regenerate. -->
| Script | What it does |
|---|---|
| [`scripts/automation/Invoke-AvdPowerAction.ps1`](docs/reference/scripts-automation-Invoke-AvdPowerAction.md) | Stops, locks or resumes the landing zone's session hosts (auto shutdown, decision 0011). |
| [`scripts/image/custom/Invoke-CustomImageStep.ps1`](docs/reference/scripts-image-custom-Invoke-CustomImageStep.md) | Golden image: the adopter's own step, run after WDOT and before cleanup (build/specs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Disable-AutomaticUpdates.ps1`](docs/reference/scripts-image-Disable-AutomaticUpdates.md) | Golden image: Windows and Microsoft 365 Apps don't update themselves on hosts (build/specs/image-pipeline-spec.md section 5.6). |
| [`scripts/image/Disable-StorageSense.ps1`](docs/reference/scripts-image-Disable-StorageSense.md) | Golden image: turns Storage Sense off (build/specs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Enable-TimeZoneRedirection.ps1`](docs/reference/scripts-image-Enable-TimeZoneRedirection.md) | Golden image: sessions use the client's time zone (build/specs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Invoke-ImageCleanup.ps1`](docs/reference/scripts-image-Invoke-ImageCleanup.md) | Golden image: a smaller image, cleaned narrowly (build/specs/image-pipeline-spec.md section 5.3). |
| [`scripts/image/Invoke-Wdot.ps1`](docs/reference/scripts-image-Invoke-Wdot.md) | Golden image: runs the Windows Desktop Optimization Tool (WDOT) with the reviewed profile (build/specs/image-pipeline-spec.md section 5.5, scripts/image/wdot/README.md). |
| [`scripts/image/Set-SessionTimeLimit.ps1`](docs/reference/scripts-image-Set-SessionTimeLimit.md) | Golden image: disconnected sessions end after a set time (build/specs/image-pipeline-spec.md section 5.7). |
| [`scripts/image/Test-GoldenImage.ps1`](docs/reference/scripts-image-Test-GoldenImage.md) | Golden image: build-time validation (build/specs/image-pipeline-spec.md section 5.4). |
| [`scripts/image/Update-DefenderSignature.ps1`](docs/reference/scripts-image-Update-DefenderSignature.md) | Golden image: Defender starts with current signatures (build/specs/image-pipeline-spec.md section 5.3). |
| [`scripts/jumpbox/Install-JumpboxTools.ps1`](docs/reference/scripts-jumpbox-Install-JumpboxTools.md) | First boot of the Windows operator jumpbox (build/decisions/0019-jumpbox-bastion-developer.md): installs the Cloud Shell toolchain, the same tools scripts/jumpbox/cloud-init.yaml installs on Linux. |
| [`scripts/ops/Approve-AvdSandboxBatch.ps1`](docs/reference/scripts-ops-Approve-AvdSandboxBatch.md) | Records a person's go on a sandbox batch: checks "go batch <id> $<total>" against batch.json and writes approval.json next to it (docs/sandbox-runs.md). |
| [`scripts/ops/Connect-AvdJumpbox.ps1`](docs/reference/scripts-ops-Connect-AvdJumpbox.md) | Gets the operator jumpbox ready to connect to through Azure Bastion Developer, or stops it (build/decisions/0019-jumpbox-bastion-developer.md). |
| [`scripts/ops/Connect-AvdLandingZone.ps1`](docs/reference/scripts-ops-Connect-AvdLandingZone.md) | Signs in to Microsoft Graph once for the whole Cloud Shell session, so the preflight, -Fix, the demo and the cleanup don't each ask for a device code. |
| [`scripts/ops/ConvertFrom-AvdTargetState.ps1`](docs/reference/scripts-ops-ConvertFrom-AvdTargetState.md) | Turns an approved target-state manifest from the migration factory into the preflight and deploy.sh commands for one host pool. |
| [`scripts/ops/Deploy-AvdDemo.ps1`](docs/reference/scripts-ops-Deploy-AvdDemo.md) | Deploys a demo host pool and session host into an existing landing zone, then validates that a user can sign in. |
| [`scripts/ops/Export-AvdConfiguration.ps1`](docs/reference/scripts-ops-Export-AvdConfiguration.md) | Snapshots the landing zone's configuration that the Bicep doesn't hold, as a recorded run, so a rebuild can put it back (build/specs/recovery-spec.md section 7). |
| [`scripts/ops/Get-AvdRecoveryStatus.ps1`](docs/reference/scripts-ops-Get-AvdRecoveryStatus.md) | If this subscription were gone tomorrow, what would you lose, and is the recovery tier met? (build/specs/recovery-spec.md section 6). |
| [`scripts/ops/Get-AvdRunStatus.ps1`](docs/reference/scripts-ops-Get-AvdRunStatus.md) | Where did I leave off? Reads where a landing zone run stands from Azure and tells the deployment portal the next step (build/specs/run-recorder-spec.md section 4). |
| [`scripts/ops/Get-AvdSandboxBatchStatus.ps1`](docs/reference/scripts-ops-Get-AvdSandboxBatchStatus.md) | Where your sandbox batches stand: approved or not, each group's outcome, open spend runs, and the Cloud Shell block to continue anything that stopped part way (docs/sandbox-runs.md). |
| [`scripts/ops/Initialize-AvdGraphApp.ps1`](docs/reference/scripts-ops-Initialize-AvdGraphApp.md) | One-time setup of the "avd-opsbot" app registration, so operators sign in to Microsoft Graph once per Cloud Shell session with no consent prompts (decision 0016). |
| [`scripts/ops/Initialize-AvdRunStore.ps1`](docs/reference/scripts-ops-Initialize-AvdRunStore.md) | Sets up the run store once per subscription: durable storage for recorded runs (build/specs/run-recorder-spec.md sections 6.3, 9.2 and 9.3). |
| [`scripts/ops/Invoke-AvdHostRotation.ps1`](docs/reference/scripts-ops-Invoke-AvdHostRotation.md) | Replaces the landing zone's session hosts blue/green with a new image version (build/specs/image-pipeline-spec.md section 6.5). |
| [`scripts/ops/Invoke-AvdSandboxBatch.ps1`](docs/reference/scripts-ops-Invoke-AvdSandboxBatch.md) | Runs one group of an approved sandbox batch: opens the spend run, deploys at the pinned commit, runs each item's test, keeps what must survive, tears down, and closes the spend run with teardown evidence (docs/sandbox-runs.md). |
| [`scripts/ops/New-AvdSandboxBatch.ps1`](docs/reference/scripts-ops-New-AvdSandboxBatch.md) | Builds a sandbox batch from the ready queue items: pins sources to commits, groups items that can share a deployment, prices the groups, checks the caps, and writes batch.json and batch.md to your records (docs/sandbox-runs.md). |
| [`scripts/ops/Publish-AvdPortal.ps1`](docs/reference/scripts-ops-Publish-AvdPortal.md) | Publishes the deployment portal into your own subscription (optional; decision 0017). |
| [`scripts/ops/Remove-AvdDemo.ps1`](docs/reference/scripts-ops-Remove-AvdDemo.md) | Removes the demo host pool deployed by Deploy-AvdDemo.ps1, and optionally the whole landing zone. |
| [`scripts/ops/Set-AvdSpendBudget.ps1`](docs/reference/scripts-ops-Set-AvdSpendBudget.md) | Creates or updates a sandbox subscription's standing cost budget, named sandbox-spend, so Azure emails you even when no landing zone is deployed (docs/sandbox-runs.md). |
| [`scripts/ops/Start-AvdImageBuild.ps1`](docs/reference/scripts-ops-Start-AvdImageBuild.md) | Builds one golden image version with Azure Image Builder (build/specs/image-pipeline-spec.md section 5.2). |
| [`scripts/ops/Start-AvdRecoveryTest.ps1`](docs/reference/scripts-ops-Start-AvdRecoveryTest.md) | A recovery test of the profile share (T-profile, build/specs/recovery-spec.md section 8): restore the newest recovery point into a new storage account, measure the real RPO and restore time, tear down. |
| [`scripts/ops/Start-AvdRunRecorder.ps1`](docs/reference/scripts-ops-Start-AvdRunRecorder.md) | Opens a recorded run: its run ID, run.json and the expected cost (cost.json), checked against the cap before anything is deployed (build/specs/run-recorder-spec.md sections 6, 9.3a and 13a). |
| [`scripts/ops/Start-AvdSpendRun.ps1`](docs/reference/scripts-ops-Start-AvdSpendRun.md) | Before a sandbox run: estimate its cost, check it against your caps, snapshot what exists, and open a run record (docs/sandbox-runs.md). |
| [`scripts/ops/Stop-AvdRunRecorder.ps1`](docs/reference/scripts-ops-Stop-AvdRunRecorder.md) | Closes, updates or copies a recorded run (build/specs/run-recorder-spec.md sections 8.1, 9.2, 9.3 and 9.3a). |
| [`scripts/ops/Stop-AvdSpendRun.ps1`](docs/reference/scripts-ops-Stop-AvdSpendRun.md) | After teardown: prove the run's resources are gone and close its record (docs/sandbox-runs.md). |
| [`scripts/ops/Test-AvdLandingZoneReadiness.ps1`](docs/reference/scripts-ops-Test-AvdLandingZoneReadiness.md) | Preflight for the AVD landing zone, in two stages: -PreDeployment before deploying: is this subscription and tenant ready for the landing zone described by the parameter file? (default) after deploying: is the landing zone ready for session hosts and users, including the three post-deployment tenant steps? Check mode by default; -Fix remediates what it can. |
| [`scripts/ops/Test-AvdRecoveryCopies.ps1`](docs/reference/scripts-ops-Test-AvdRecoveryCopies.md) | The monthly verify routine (build/specs/recovery-spec.md section 9): copies rot silently, so read every one back. |
| [`scripts/ops/Test-AvdUserConnection.ps1`](docs/reference/scripts-ops-Test-AvdUserConnection.md) | Confirms from Azure telemetry that a user's sign-in reached the landing zone's desktop: the deployment portal's Verify access step (decision 0014, build/specs/verify-access-spec.md). |
<!-- generated:entry-points end -->

## Contributing

Contributions and forks are welcome and encouraged. Fork it and make it your own, or send back what you learn: open an issue for a bug, a question or an idea, or a pull request with a fix, a test, a doc or a lesson from a real run. Small pull requests are easiest to review.

Before you open one, read [CONTRIBUTING.md](CONTRIBUTING.md) and run the checks it lists. Keep tenant data, IDs and secrets out of the repo, issues and pull requests. By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). The software is provided "as is", without warranty of any kind, and the authors are not liable for any claim, damages or other liability arising from its use, including Azure charges and changes it makes to your subscription or tenant.

This is a personal research and learning project. It is not affiliated with, endorsed by or supported by my employer, and it is not an official Microsoft product. Azure, Microsoft Entra, Intune and FSLogix are trademarks of Microsoft. It is not intended for production use.
