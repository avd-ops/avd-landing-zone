# 0016. Liquidware ProfileUnity, FlexApp and CommandCTRL as an optional tier: FSLogix stays the container, FlexApp goes through app attach

- **Status:** Proposed

## Context
FSLogix on Azure Files with Entra Kerberos is the proven default (lesson 0028). Customers leaving Citrix, Omnissa or Ivanti, migrating Windows versions, or replacing Group Policy Preferences after going Entra-only need profile portability, user environment management and app layering for apps that won't convert to MSIX. Liquidware covers those, and CommandCTRL adds real-time support for session hosts and user devices. Most deliveries are into customer environments run by Nerdio Manager for Enterprise. Details and sources: [liquidware-spec.md](../liquidware-spec.md).

## Decision
- **Optional:** nothing changes unless `AVD_LIQUIDWARE` is set (landing zone) or the Nerdio scripted action is run (customer environment).
- **Profiles:** FSLogix stays the container; ProfileUnity adds Portability for a named list of settings and user environment management. ProfileDisk is gated on a spike.
- **Apps:** one assignment system per app. MSIX through native app attach when it exists; otherwise FlexApp through AVD app attach; ProfileUnity rules or Nerdio's FlexApp One where those already own assignment.
- **Storage:** app attach images live in a separate packages account, the only place storage keys are allowed, with keys in Key Vault and rotated. The profiles account never enables shared-key access. Machine-context ProfileUnity configuration is out until a keyless path is shown.
- **CommandCTRL:** a support tool, not monitoring and not an actor. Remote control, shell and AI Insights off by default; never available to agents; the swarm's kill switch can disable them.
- **Second brain and swarm:** read-only facts and detections, and three approved-plan actions (package version swap, configuration rollout, key rotation), landed in both repos together.

## Alternatives considered
- **ProfileDisk instead of FSLogix:** loses the proven, license-included container and needs storage access that isn't shown to work Entra-only.
- **FlexApp only through ProfileUnity rules:** a second assignment surface the AVD control plane, Nerdio and the second brain don't see.
- **Packages on the profiles account:** would require enabling shared-key access on every user's profile storage.
- **A separate repo:** duplicates the storage, Run Command, preflight and portal patterns and their tests.

## Consequences
The landing zone gains a console VM and a key-based packages account when the tier is on, both covered by template tests. The spike (phase L0) decides several paths, so parts of the tier may stay out. Licenses are quoted by Liquidware or a partner and aren't priced by the preflight.
