# 0015. An optional computer-use agent on an isolated VM, as its own deployment, with no credential ever reaching the model

- **Status:** Proposed

## Context
Track A (decision 0014) needs a person. An unattended, repeatable check would catch a broken sign-in path between deployments. Microsoft Foundry offers computer-use models that drive a desktop from screenshots. Microsoft's guidance is to run them only on isolated, low-privilege machines with no sensitive data, and never to act on a pending safety check without a person. Model access is gated by application, and the docs describe two different tools (spec §7.1). Details and sources: [verify-access-spec.md](../specs/verify-access-spec.md).

## Decision
- **Optional and separate:** its own template and run (`bicep/agent`, `deploy.sh --agent`). The landing zone's template and default deployment don't change.
- **Model:** the Responses API `computer` tool with `gpt-5.4` (2026-03-05), GlobalStandard by default. Model, version, SKU, capacity and `foundryLocation` are parameters.
  - Not the Agent Service's preview tool.
  - Access is a prerequisite the preflight names.
  - The run deploys the model first, and rolls the account back when it fails, rather than leaving a half-built track.
- **Isolation:** a workgroup Windows 11 VM in its own VNet, never peered to the landing zone spoke. No public IP, Trusted Launch, encryption at host, 443 egress only, keyless Foundry behind a private endpoint, and its own Key Vault.
- **Credentials and actions** (after the [red-team review](../specs/verify-access-redteam.md)):
  - Sign-in is deterministic, with no model involved, and certificate-based authentication is preferred.
  - The model only observes the desktop afterwards (`screenshot` and `wait`). Any other action ends the run for review.
  - A broker service in session 0 holds the identity. Windows Firewall denies outbound traffic by default and allows IMDS only for the broker, and an application allowlist limits the agent's session. If the B0 spike can't enforce that, Track B stops or the broker moves off the VM.
  - The agent signs in only to a dedicated one-host check pool, not the main, demo or QA pool. Only there may its identity log sessions off (Q9).
  - Safety checks are never acknowledged: the run stops with *needs review*.
- **Bounds and evidence:** an iteration cap, a wall-clock limit, a token budget, a daily run cap with a resource-group budget, and kill switches (a tag, deallocation, role removal). It always logs off. Evidence is kept 7 days, write-once, with restricted access. Timing still comes from telemetry, not the loop.
- **Not built yet:** it waits for model access and a test user license. When both exist, a deterministic visual check with no model is tried first (red-team S1, S2).

## Alternatives considered
- **`computer-use-preview` through Foundry Agent Service:** preview, three regions, and its tool is listed as unsupported behind network isolation.
- **Peering the sandbox to the spoke:** it gives a prompt-injectable machine a route to session hosts for no test benefit. The user path is public anyway.
- **Windows 365 for Agents:** a better host in principle. It's generally available (since June 2026) and billed pay-as-you-go per Cloud PC through an Azure subscription, but it's driven from Copilot Studio, with no Foundry or REST entry point. It's the revisit trigger (spec §10b).
- **A Python harness on the official SDK:** see open question Q8. PowerShell and REST keep the repo to one language and testable offline.

## Consequences
- Standing cost (NAT Gateway, private endpoints, disk) and per-run tokens, priced by the preflight and measured per run. A test user license is required.
- Screenshots of the desktop go to the Foundry endpoint, processed per the deployment type (GlobalStandard: any region).
- Proves only what an Azure-hosted client sees. It never replaces Track A.
- Unverified until a real run: private endpoint support for the `computer` tool, the console display resolution, an unattended Windows App install, the IMDS firewall rule, the application allowlist, and sign-in through UI Automation (spec §11).
