# 0009. The Well-Architected review runs against the deployed landing zone and only warns

- **Status:** Accepted

## Context
CI already checks the templates against the Well-Architected rules in PSRule for Azure, with justified suppressions (lesson 0018). That doesn't say whether a **deployed** landing zone would pass a Well-Architected review. The parameter file chosen matters more than the template: `dev.bicepparam` makes cost trade-offs on purpose, such as one host, LRS storage, no backup and Defender off. Settings also drift after deployment. And Azure already evaluates much of this itself, in Advisor, Defender for Cloud and Azure Policy.

## Decision
- **An opt-in section of the post-deployment preflight** (`-WellArchitected`), grouped by pillar, with a scorecard. It needs only Reader and no Graph sign-in (`-SkipTenant -SkipNtfs`).
- **Its sources are the deployed resources and Azure's own evaluations, through REST** (decision 0002):
  - design checks read from the resources;
  - Azure Advisor recommendations, whose categories are the pillars;
  - open Defender for Cloud recommendations;
  - Azure Policy compliance;
  - PSRule for Azure on the exported live resources, with the repo's suppressions, so the same rule set covers both the templates and the deployment.
  Each source is filtered to the landing zone's resource groups. A source that can't be read becomes a warning with the error, and the rest still run.
- **Warnings, never failures.** Well-Architected findings are trade-offs to decide on, not blockers, and a dev landing zone must still come back Ready. Findings that are deliberate in the dev and test parameter files carry `data.accepted` and say so. In prod the same findings are plain warnings.
- **The portal** offers the review once post-deployment is Ready, and summarizes its findings by pillar. The state line carries `context.wellArchitected`, and each finding has an id `waf-<check>` with `data.pillar` and `data.accepted`.

## Consequences
- "Would it pass a review?" has a concrete, repeatable answer per pillar, and it can be rerun after changes.
- Advisor and Policy refresh on their own schedule, so a same-day run can under-report. The output says so.
- PSRule installs a module from the PowerShell Gallery in Cloud Shell. `-SkipPSRule` leaves it out.
- The questionnaire part of Microsoft's Well-Architected assessment remains manual.
- A new check needs a mock response in `build/tests/offline/AzMock.psm1` and an assertion in the WellArchitected scenario.
