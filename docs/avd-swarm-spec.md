# Spec: avd-swarm, a chat front end for operating the landing zone

- **Status:** Proposed ([decision 0016](decisions/0016-avd-swarm.md))
- **Builds on:** the operations brain ([operations spec](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md), decision 0012). Section references like "brain §4.5" point there.

## 1. Summary

avd-swarm lets an operator run the landing zone by talking to it, from any browser including an iPad, instead of opening the Azure portal. A coordinator agent answers questions and hands work to specialist agents (cost, hosts, images, access). The agents read freely through allowlisted tools. They change nothing themselves: a change is always a plan that a person approves in a GitHub Environment, exactly as the brain does it (brain §4.5).

avd-swarm is the brain's **Concierge** agent (brain §4.4) grown into a team with a front end. It adds a chat surface and specialists. It adds no new way to write to Azure.

It is the development version of **tenant-swarm**, a private project for the whole tenant (Entra, Microsoft 365, subscriptions). What proves itself here moves there; see §8.

## 2. Goals and non-goals

### Goals
- Answer operator questions about the estate with evidence: cost to date and forecast, host health, sessions, image versions, drift, failed checks.
- Turn "fix it" into a brain plan the operator can approve from the same screen, with one tap through to the approval.
- Work from a phone or tablet with nothing installed.
- Cost close to nothing when idle, and stop itself at a budget.

### Non-goals
- Any write path that skips the brain's plan and approval. There is no "confirm in chat" button.
- Microsoft Graph, Entra or Microsoft 365 management. The brain deliberately holds no Graph permissions (brain red-team H8); that scope belongs to tenant-swarm.
- A custom MCP server or a new runtime language. Tools are the brain's PowerShell tools (brain §4.4, "One language").
- Replacing Cloud Shell blocks for operators who prefer them (lesson 0015).

## 3. Architecture

```
iPad / browser
   │  Entra sign-in (Static Web Apps built-in auth, one allowed group)
   ▼
Static Web App: chat page + thin API (Functions, PowerShell)
   │  passes the signed-in operator's identity as a claim, never a token
   ▼
Foundry Agent Service
   coordinator ──► cost · hosts · images · access   (specialists, each its own agent)
   │  tool calls, per-agent allowlist
   ▼
Tools (shared with the brain, read-only)          Write path (the brain's, unchanged)
  Azure MCP Server: Resource Graph, KQL,            propose_playbook_run(episodeId, playbookId)
    Monitor, Advisor, Cost Management                 → plan with hash → Critic
  AVD-LZ PowerShell Functions (OpenAPI):              → GitHub Environment approval
    preflight state line, KQL catalog,                → executor identity runs it
    Invoke-AvdPowerAction -WhatIf, playbook catalog   → verify
```

Everything deploys into the brain's resource group (`rg-<prefix>-<env>-brain`) behind a new opt-in, `AVD_SWARM=true`, which requires `AVD_BRAIN_TIER=3` because it reuses the Tier 3 Functions app, Foundry project and identities. A landing zone without the flag is unchanged.

## 4. Agents

| Agent | Answers | Tools | Can act? |
|---|---|---|---|
| **Coordinator** | Anything; routes to a specialist when the question needs one, and merges the answers with citations | None of its own beyond the catalogs; calls specialists as connected agents | No |
| **Cost** | Spend to date, forecast against the budget, top meters, idle hosts, what auto shutdown saved | Cost Management query, retail price lookup (decision 0010), budget state | Proposes Stop/Resume through playbooks |
| **Hosts** | Health, sessions, drain state, agent version, failed checks | Resource Graph, KQL catalog (`WVDAgentHealthStatus`, `WVDErrors`, ...), preflight state line | Proposes host playbooks (restart agent, recycle, re-register) |
| **Images** | Current and candidate image versions, which hosts run what, rollout status | Compute Gallery reads, image pipeline state (decision 0013) | Proposes promotion only as a PR, per decision 0013 |
| **Access** | Who can sign in, assignment and RBAC on the AVD resources, Verify Access results (decision 0014) | ARM role assignment reads scoped to the landing zone's resource groups | No |

Adding an agent is a PR that adds its prompt (`brain/prompts/swarm-<name>.md`), its tool allowlist and its eval cases. Prompts, allowlists and `brain/models.yml` are protected paths (brain §9.2), so no agent can widen its own reach. Models follow brain §4.4: Claude Opus 5.5 to start, effort per agent, cheaper only where evals hold.

## 5. Write path

1. The operator asks for a change ("drain host 3 and restart its agent").
2. The specialist opens or reuses an episode and calls `propose_playbook_run`. The orchestrator binds the parameters from the episode, never from the model (brain §4.5).
3. The chat shows the plan as the brain renders it: targets, preconditions, blast radius, rollback, the Critic's dissent, and expiry. It shows a link to the approval.
4. The operator approves in the GitHub Environment, which is the only place Azure issues the executor a token. The chat never holds an approval control.
5. The chat follows the run and reports the verification with its evidence.

If no playbook fits, the specialist says so and offers a Cloud Shell block for the operator to run (lesson 0015). It never improvises a write.

## 6. Identity and data

- **Operator sign-in:** Static Web Apps built-in authentication with Entra ID, restricted to one group (`AVD_SWARM_OPERATORS_GROUP_ID`). The API stamps the operator's object ID on every episode and plan so the audit trail names who asked.
- **Agent identities:** one per agent, Reader plus Log Analytics Reader on the landing zone's resource groups (brain §4.5), Entra Agent ID where available (brain Q5).
- **Pseudonymization:** answers and prompts follow brain §9.4. User names, client IPs and device names reach the model as pseudonyms; the chat page resolves them back only for an operator who holds vault access, in the browser, never in a prompt.
- **Model location:** `AVD_BRAIN_MODEL` applies unchanged and the deploy step prints who processes prompts. `none` disables the swarm.
- **Untrusted text:** tool output, logs and issue text are data, never instructions (brain §4.4). The chat renders them as quoted evidence.

## 7. Cost

- Static Web Apps on the Free plan and the Tier 3 Functions app on Flex Consumption scale to zero. Prompt agents in Foundry Agent Service carry no service fee of their own; tokens are the cost.
- A token budget per day (`AVD_SWARM_DAILY_TOKENS`) and the brain's own budget cap the spend. Crossing the brain budget trips the kill switch (EX-0004), which also disables the swarm's agents.
- The deploy step prices the setup from the meters (decision 0010). This spec doesn't estimate it.

## 8. Relationship to tenant-swarm

| | avd-swarm (here, public) | tenant-swarm (private repo) |
|---|---|---|
| Scope | The landing zone's resource groups | The whole tenant: subscriptions, Entra, Microsoft 365 |
| Graph | None | Yes, behind its own approval rules |
| Purpose | Prove the pattern against a real AVD estate | Daily tenant operations for one owner |

The pattern moves to tenant-swarm once avd-swarm has a record of approved, verified runs: coordinator plus specialists, read-only tools, plans approved in a GitHub Environment. Tenant-specific values never land in this public repo; tenant-swarm keeps them in repository variables.

## 9. Phases

| Phase | Delivers | Needs | Exit |
|---|---|---|---|
| S0 | This spec, a red team, and the eval cases for read-only questions | Brain spec | Red team findings resolved |
| S1 | Chat page, coordinator and the Cost and Hosts agents, read-only | Brain Tier 3 | Answers cite evidence in ≥ 80% of eval cases |
| S2 | Plans from chat through `propose_playbook_run` | Brain Tier 2 playbooks | Ten approved, verified runs started from chat |
| S3 | Images and Access agents | Decisions 0013 and 0014 built | Eval gate per agent |

## 10. Open questions

- **SQ1** Can Foundry pass the signed-in operator's identity to tools (on-behalf-of), or do tools always run as the agent's identity? The design works either way, because tools only read; on-behalf-of would let reads honor the operator's own RBAC.
- **SQ2** Does the Azure MCP Server's Cost Management coverage answer forecast questions, or does the Cost agent need its own PowerShell tool?
- **SQ3** Teams as a second chat surface (brain Q2), or the web page only?
- **SQ4** Should avd-swarm wait for brain Tier 3, or run S1 against Tier 1 with Claude Code in Actions as the coordinator?
