# This repo and avd-second-brain

**[avd-second-brain](https://github.com/nickprignano/avd-second-brain)** is the second brain for the whole AVD lifecycle: assess (avd-readiness-stratusphere), inventory (avd-current-state), deploy and operate (this repo). Its [architecture](https://github.com/nickprignano/avd-second-brain/blob/main/docs/architecture.md) and [contracts](https://github.com/nickprignano/avd-second-brain/blob/main/docs/contracts.md) are the source of truth; this page lists this repo's part.

| What | Where | Status |
|---|---|---|
| The operations brain's **spec** and red team | avd-second-brain [`docs/operations-spec.md`](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) (moved from here, section numbers unchanged) | Proposed |
| The operations brain's **runtime**: `brain.bicep`, detections, playbooks, exceptions, executor, kill switch | This repo, once built ([decision 0012](decisions/0012-second-brain.md)) | Not built |
| Lessons and decisions | This repo; avd-second-brain searches them in place and cites `avd-landing-zone@<commit>:<path>` (contract C7) | Built |

## Contracts with the brain

| Contract | Direction | What this repo does |
|---|---|---|
| C4 `avd-sizing-evidence/v1` | here → brain | The operations brain's Tier 1 job writes a monthly document from its baselines: per host pool, VM size, max session limit, hosts, peak sessions per host, p95 CPU and memory. No names; the schema has no field for them. avd-second-brain turns it into sizing calibration |
| C5 Host pool tags | factory → here → brain | Host pools deployed from a factory design carry `avdbrain-engagement` and `avdbrain-tier`. The job copies them into C4; pools without them produce no observation |
| C6 Reading the knowledge | brain → here | Sizing defaults can start from avd-second-brain's `knowledge/rules/workload-tiers.json` and calibration; the image pipeline can check `knowledge/catalog/apps.json` before baking an app. Read at a pinned commit |

The brain's rules apply here unchanged: a person approves every change, tenant data stays in the tenant, and knowledge moves into avd-second-brain only by a reviewed PR.
