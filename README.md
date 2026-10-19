# Cloud-native AVD Landing Zone

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
| **Operations** | Log Analytics, AVD Insights DCR, diagnostics on every resource, alerts (unhealthy hosts, FSLogix errors, connection errors, Service Health), activity log export | Day-2 visibility from day 1 |
| **Governance** | Azure Policy guardrails (allowed locations, tag inheritance), Defender for Cloud (Servers P2, Storage, Key Vault), subscription budget | The subscription arrives governed |
| **Auto shutdown** | An Automation runbook stops the session hosts on a schedule and locks them off when the budget is exceeded (Resume undoes it) | Spend stops when the budget runs out, not at the end of the month |
| **Delivery** | Strict Bicep linting, PSScriptAnalyzer, shellcheck, PSRule for Azure, subscription what-if on PRs, environment-gated deploy workflow (OIDC) | Changes are reviewed as code and promoted with approvals |
| **Well-Architected** | PSRule's Well-Architected rules gate every template change; `-WellArchitected` reviews the **deployed** landing zone by pillar (design checks, Advisor, Defender for Cloud, Policy, PSRule on live resources) | Know where a deployment stands against a review, and what the dev settings trade away |

Everything is built from pinned [Azure Verified Modules](https://aka.ms/avm).

## Quick start

**Easiest path: the [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/).** It picks the closest region by measuring latency from your browser, sizes the host pool from how many people use it (and the preflight prices that at Azure list prices for the region), gives you each command to paste into Cloud Shell, and reads the output you paste back to tell you what to run next, all the way to signing in. Pasted output never leaves your browser. If you get stuck, **Report a problem** turns the output into a GitHub issue, with private details removed in your browser first.

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
│   ├── portal/                    # the deployment portal
│   └── region-latency/
│
├── build/                         # how the project is built: not needed to use it
│   ├── tests/                     # Pester unit tests, offline scenarios, template guards; portal tests
│   ├── lessons/                   # what real runs taught, each with its guard
│   ├── decisions/                 # why things are the way they are
│   └── specs/                     # design specs and their red-team reviews
├── ps-rule.yaml, .ps-rule/        # PSRule for Azure (CI)
└── .github/workflows/             # validate, deploy, image-build, pages, secret-scan, lanes
```

## Documentation

**Using it**

- [`docs/design-decisions.md`](docs/design-decisions.md): the opinions this repo takes and how it compares with the LZA
- [`docs/architecture.md`](docs/architecture.md): resource layout, traffic flows, identity and RBAC model
- [`docs/deploy.md`](docs/deploy.md): prerequisites, deployment, post-deployment steps, scaling out, teardown
- [`docs/operations.md`](docs/operations.md): preflight with fix mode, Well-Architected review, demo host pool with sign-in validation, cleanup
- [`docs/images.md`](docs/images.md): golden images, step 1: setting up and running the monthly image build
- [Deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) ([how it works](site/portal/README.md)): region by latency, then the next command from each pasted Cloud Shell output
- [`docs/demo.md`](docs/demo.md): a live demo in a 30-minute slot (dev built the night before, test deployed live beside it)
- [`docs/ci.md`](docs/ci.md): validation and deployment pipelines, OIDC setup
- [`docs/gotchas.md`](docs/gotchas.md): the things that bite
- [`docs/out-of-scope.md`](docs/out-of-scope.md): what this repo does not do
- [`docs/setup-azure-account.md`](docs/setup-azure-account.md): starting from zero on a personal card (lab use)
- [`releases/`](releases/README.md): released versions and how to pin one
- [avd-second-brain](https://github.com/nickprignano/avd-second-brain): the second brain for the whole AVD lifecycle, shared with avd-current-state and avd-readiness-stratusphere. Its [operations spec](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) is this landing zone's self-healing, self-learning brain (moved there; the runtime still deploys from here). What this repo exchanges with it: [`docs/second-brain.md`](docs/second-brain.md)

**Building it**

- [`build/lessons`](build/lessons/README.md): what real deployments taught, each with the guard that now catches it
- [`build/decisions`](build/decisions/README.md): the choices that shape the repo, and why
- [`build/specs/image-pipeline-spec.md`](build/specs/image-pipeline-spec.md): proposed spec for a golden image pipeline (Azure Image Builder → Compute Gallery) and blue/green host rotation
- [`build/specs/verify-access-spec.md`](build/specs/verify-access-spec.md): verifying access from the operator's device
- [`build/specs/rebuild-spec.md`](build/specs/rebuild-spec.md): one prompt to rebuild this from an empty repo, with the protocol to count the prompts it takes

## Contributing

Contributions and forks are welcome and encouraged. Fork it and make it your own, or send back what you learn: open an issue for a bug, a question or an idea, or a pull request with a fix, a test, a doc or a lesson from a real run. Small pull requests are easiest to review.

Before you open one, read [CONTRIBUTING.md](CONTRIBUTING.md) and run the checks it lists. Keep tenant data, IDs and secrets out of the repo, issues and pull requests. By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). The software is provided "as is", without warranty of any kind, and the authors are not liable for any claim, damages or other liability arising from its use, including Azure charges and changes it makes to your subscription or tenant.

This is a personal research and learning project. It is not affiliated with, endorsed by or supported by my employer, and it is not an official Microsoft product. Azure, Microsoft Entra, Intune and FSLogix are trademarks of Microsoft. It is not intended for production use.
