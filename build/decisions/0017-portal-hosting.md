# 0017. The portal runs from GitHub Pages by default, or from a copy you publish into your own subscription

- **Status:** Proposed

## Context
The deployment portal (`site/portal`) is a static page: no build step, no server code, nothing it
needs from GitHub. It hands operators PowerShell to paste into Cloud Shell as a subscription Owner,
so whoever controls the served page, the repo its commands clone, or the URL the scripts print
controls code in the operator's tenant. Until now it only ran from GitHub Pages, and only three
things assumed that: the fork check (`*.github.io`), the portal URL the scripts print, and links.
Some operators want the portal in their own subscription (Azure-native first), for a fork, or
pinned to a release. A red team of the two-mode design
(PH-1 to PH-14) set most of the shape below.

## Decision
Two modes, one build:

- **Mode A (default, unchanged):** run the scripts in Cloud Shell and use the portal on GitHub Pages.
  $0, nothing to set up.
- **Mode B:** `scripts/ops/Publish-AvdPortal.ps1` publishes the same `site/portal` and `site/assets`
  into `rg-<prefix>-<env>-portal` (`bicep/portal/main.bicep`), from Cloud Shell:
  - `-Hosting StaticWebApp` (default, Nick's pick): Azure Static Web Apps on the Free plan ($0, no
    SLA, 100 GB a month and no overage). Created only in centralus, eastus2, westus2, westeurope or
    eastasia. Uploaded with the Static Web Apps CLI from npm at a pinned version (an accepted risk:
    the one non-Azure-native piece); the deployment token goes to the CLI in an environment variable,
    is never printed, and is reset after the upload.
  - `-Hosting Storage`: a storage account's static website in the landing zone's region (cents a
    month). Pure Az PowerShell with the operator's own RBAC: no npm, no token, no app consent. No
    sign-in: anyone with the URL can open it.
- **Sign-in is invited users, never "anyone signed in."** On the Free plan the built-in Entra sign-in
  accepts any Microsoft account, so `-RequireSignIn` locks every route to an `operator` role given by
  invitation (25 on Free), turns GitHub sign-in off and invites the operator. Single-tenant sign-in,
  IP restrictions and private endpoints need the Standard plan (about $9 a month): the operator's
  choice in the Azure portal, never a script's. The script warns when the plan isn't Free.
- **The trust root moves with the copy.** `portal-config.js` names the repo and the tag or commit
  (`-RepoUrl`, `-Ref`; default: the checkout's origin and commit). The portal accepts only a
  `https://github.com/<owner>/<repo>` URL and a plain ref, and its commands then point an existing
  clone at that repo and check out that ref instead of pulling `master`. The page says which repo
  and ref the commands run.
- **The portal URL the scripts print** is GitHub Pages unless `AVD_PORTAL_URL` is an https URL; an
  override is spelled out (`Portal host: <host>, set by AVD_PORTAL_URL`) so an unexpected host stands
  out. It is read from the environment only.
- **A preflight before anything is created:** the subscription's allowed-locations assignments are
  checked against the host's region. The landing zone's own guardrail allows only its region, so in a
  northcentralus landing zone Static Web Apps is blocked; the script stops and names the ways out
  (an allowed Static Web Apps region, an exemption, or `-Hosting Storage`).
- **Secrets never show:** the portal masks tokens, keys, passwords and device codes on paste, before
  the text is drawn or read (`report.js` `maskSecrets`; the same patterns the issue report uses,
  plus Static Web Apps deployment tokens).
- Static Web Apps sends the headers GitHub Pages can't (CSP with `frame-ancestors 'none'`,
  `X-Frame-Options: DENY`, `nosniff`, `no-referrer`). `-Remove` and
  `Remove-AvdDemo.ps1 -IncludeLandingZone` delete the portal's resource group.

## Consequences
- The landing zone stays portal-driven Cloud Shell deployment in both modes; nothing in the landing
  zone's default deployment changes.
- A published copy is a snapshot pinned to a ref: republish to move it. A state-line field the copy
  doesn't know yet shows as unrecognized, never as a wrong command.
- Not done here (red team follow-ups): a custom domain and a CSP meta tag for the Pages portal
  (PH-9), SHA-pinned Actions and branch rules (PH-3), validating every settings field (PH-4),
  comparing the commit in the state line with the portal's (PH-8), and Report a problem naming the
  repo it files into (PH-10).
- The first real run of Mode B gets a lesson (decision 0006), including whether a Static Web Apps
  resource in an allowed region works under a landing zone whose resource group region differs.
