# 0012. A second brain that heals by tested playbooks and evolves by pull request

- **Status:** Proposed
- **Update 2026-10-16:** the spec and its red team moved to [avd-second-brain](https://github.com/nickprignano/avd-second-brain) (its decision 0001: one brain for the AVD lifecycle), with section numbers unchanged. The decision and the runtime it describes stay here. See [`docs/second-brain.md`](../second-brain.md).

## Context
The project is for the community and has one maintainer, possibly for good. Decisions 0006 to 0011 built a learning loop that runs through people: a real run fails, the output is pasted, a lesson and a guard follow. The estate itself is not watched between runs, the same AVD failures (agent health, empty-host recycling, profile share headroom, drift) recur in every estate, and the knowledge to fix them already sits in this repo.

## Decision
Build the loop into the platform, as specified in [second-brain-spec.md](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md):
- **In tiers** (`AVD_BRAIN_TIER`):
  - **Tier 1, Notice**, is the supported core: detections, a Container Apps job running the preflight, pseudonymized evidence in episode issues, a Claude Code diagnosis, and the kill switch.
  - **Tier 2** adds approved fixes.
  - **Tier 3** adds Cosmos DB memory with vector search, Foundry agents and self-healing.
  - Everything new is PowerShell and Bicep.
- Sense through Azure Monitor, Resource Graph and the scheduled preflight, which writes the existing state line. Git is the only place policy lives.
- Reason with agents that can only propose. Data reaches a model only pseudonymized, and the deployment names who processes it.
- **A person approves every change before it is made.** The brain turns a proposal into a plan: exact targets, parameters, preconditions, verification and rollback, with a hash. A person approves that plan through a GitHub Environment, one approval per run, with no standing or batch approvals. Azure enforces this: the executor's identity is federated only to the approval environment, so no token exists until a person approves. Then deterministic, offline-tested playbook code runs, re-checks the plan, and verifies the result with positive evidence.
- **Pre-approved exceptions** are the only changes without approval of each run. A person writes each one in `brain/exceptions/`: one action, a deterministic trigger (never an agent), a narrow scope, an owner, approvers and a review date. The first two are decision 0011's budget Lock (EX-0001) and scheduled Stop (EX-0002). Self-healing is EX-0003: reversible, single-host playbooks with a detection trigger, entered one by one by PR after a record of approved, verified runs, and suspended on their first failure. The kill switch is EX-0004, a safety exception that can only take capability away. One person or a deterministic watchdog trips it: it sets a tag and deletes the executors' federated credentials. Only a person starts the brain again, through a redeploy. It never touches the cost safeties EX-0001 and EX-0002.
- **The project ships code and conservative defaults, and adopters run the brain in private forks.** Adopters sync from attested releases and review every upstream guardrail change. **Solo mode** lets one person run it safely: a 72-hour time-lock and CI evidence stand in for a second reviewer on changes that raise capability. Team mode adds two-person rules.
- Learn and evolve by pull request only: lessons and guards through the retro routine, drift and sizing through CI and the `test` environment. The brain never merges or deploys to prod.

## Consequences
- Known failures arrive as a plan a person can approve in a minute; unknown ones arrive with evidence instead of a guess. Nothing in the estate or the code changes without a named approver on record.
- Fixes wait for people. Approval fatigue becomes the main risk to manage: readable plans, merged duplicates, required rejection reasons, flagged instant approvals.
- New surface to secure and pay for, kept small by tiers and capped by the brain's own budget, which trips the kill switch. And a new kind of test: evals of the agents against redacted real episodes.
- Solo mode is weaker than a second reviewer: it protects against rash changes and hijacked sessions, not a determined owner. Adopters accept that knowingly.
- `AVD_BRAIN_MODEL=none` keeps Tiers 1–2 working without sending data to a model.
