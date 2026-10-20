# Decisions

Short records of choices that shape this repo, so they are not reopened without the reasoning. New decision: copy [`TEMPLATE.md`](TEMPLATE.md), take the next number and add a row.

| # | Decision | Status |
|---|---|---|
| 0001 | [Entra ID-only, greenfield, private by default](0001-cloud-native-scope.md) | Accepted |
| 0002 | [Call ARM and Graph REST when a cmdlet reshapes or blocks](0002-rest-over-cmdlets.md) | Accepted |
| 0003 | [Region chosen by browser latency; parameter files default, `AVD_LOCATION` overrides](0003-region-by-latency.md) | Accepted |
| 0004 | [Random break-glass password, applied at host creation](0004-random-break-glass.md) | Accepted |
| 0005 | [Set the profile share root ACL through the Azure Files REST API from a session host](0005-ntfs-via-rest.md) | Accepted |
| 0006 | [Every real-run finding becomes a lesson and a guard](0006-lessons-and-guards.md) | Accepted |
| 0007 | [The deployment portal reads a state line from the scripts, in the browser only](0007-portal-state-line.md) | Accepted |
| 0008 | [Problem reports from the portal: redacted in the browser, submitted by the reporter](0008-portal-issue-reports.md) | Accepted |
| 0009 | [The Well-Architected review runs against the deployed landing zone and only warns](0009-well-architected-review.md) | Accepted |
| 0010 | [Size in the portal, validate and price in the preflight](0010-sizing-and-cost.md) | Accepted |
| 0011 | [Auto shutdown: one runbook, started by a schedule and by the budget](0011-auto-shutdown.md) | Accepted |
| 0012 | [A second brain that heals by tested playbooks and evolves by pull request](0012-second-brain.md) | Proposed |
| 0013 | [A generic golden image built by Azure Image Builder, promoted by a person, rotated blue/green](0013-image-pipeline.md) | Proposed |
| 0014 | [Verify access from the operator's device in three layers, each claiming only what it measures](0014-verify-access.md) | Proposed |
| 0015 | An optional computer-use agent on an isolated VM (never built; moved out of this repo 2026-10-20) | Withdrawn |
| 0016 | [One delegated Microsoft Graph sign-in per session, through a dedicated public client app](0016-graph-operator-app.md) | Accepted |
