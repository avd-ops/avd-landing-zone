# 0016. Operate the landing zone through chat agents that can only read and propose brain plans

- **Status:** Proposed

## Context
The owner wants to run the landing zone, and eventually the whole tenant, from a chat window on any device instead of the Azure portal. The operations brain (decision 0012) already defines agents in Foundry Agent Service, read-only tools in PowerShell, and one write path: a plan a person approves in a GitHub Environment. Its Concierge agent answers operator questions but has no front end. Details: [avd-swarm-spec.md](../avd-swarm-spec.md).

## Decision
- Build **avd-swarm** as the brain's Concierge grown into a coordinator with specialist agents (cost, hosts, images, access), behind a chat page on Static Web Apps with Entra sign-in.
- Opt-in through `AVD_SWARM=true`, which requires brain Tier 3 and reuses its Functions app, Foundry project and identities.
- Agents read through the brain's allowlisted tools (Azure MCP Server read operations and the AVD-LZ PowerShell Functions). They change Azure only through `propose_playbook_run`, which a person approves in a GitHub Environment.
- No Microsoft Graph. Tenant-wide management (Entra, Microsoft 365) belongs to **tenant-swarm**, a separate private repository, which adopts this pattern once it has proven itself here.

## Alternatives considered
- **A custom MCP server with a confirmation token in the chat:** simpler to start, but it creates a second write path that the brain's approval, audit and kill switch don't cover, and a new runtime language (brain §4.4 rules out both).
- **Building it straight into tenant-swarm:** no public, testable estate to prove it against, and Graph permissions from day one.
- **Claude Code in GitHub Actions as the only agent:** works for Tiers 1 and 2 but has no interactive surface; kept as a fallback for phase S1 (spec SQ4).

## Consequences
- One write path, one audit trail, one kill switch for both the brain and the chat.
- The chat is only as capable as the playbook catalog: a fix with no playbook becomes a Cloud Shell block, not an action.
- Waits on brain Tier 3 unless SQ4 decides otherwise.
- A new eval set for conversational questions, alongside the brain's episode evals.
