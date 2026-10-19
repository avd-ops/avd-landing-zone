# 0008. Problem reports from the portal: redacted in the browser, submitted by the reporter

- **Status:** Accepted

## Context
Operators get stuck at steps the portal doesn't recognize, and a real paste is the best input for a fix (decision 0006: a real paste analyzed wrongly becomes a fixture). Cloud Shell output is full of tenant details: UPNs, subscription and tenant IDs, subscription names, storage and key vault names, group names, sometimes device codes or keys. GitHub issues are public. The portal is a static page with no server (decision 0007).

## Decision
- **No backend, no token:** the portal opens `github.com/<repo>/issues/new` with the title and body filled in. The reporter reviews the report on GitHub and submits it with their own account.
- **Redaction in the browser** (`site/portal/report.js`), before anything leaves the page. It covers secrets, emails and UPNs, the operator's domains, tenant names, subscription names, IDs, globally unique resource names, public IPs, home-folder user names, the name prefix and group names from the settings and the state line, and any terms the operator adds. Secrets are removed outright; other values get numbered placeholders (`<email-1>`) so a report still shows which values match. IDs that are the same in every tenant (built-in roles, first-party apps) and private IP addresses stay, because they help diagnosis.
- **The reporter reviews it:** the report is shown in full, editable. Sending needs a tick that it contains nothing private. Edits are redacted again on send.
- **Reports are marked** (`<!-- avdlz-portal-report v1 -->`), and a workflow labels them `portal-report`. GitHub drops the `labels` URL parameter for people without triage access.

## Consequences
- Pattern redaction can't know every private value, such as a person's name typed in free text. So the page says issues are public and asks for a review, and the report's footer tells maintainers to check before committing anything from it.
- Redaction must not change what the portal makes of the output. A test runs every fixture through it and compares the analysis, so a redacted report can become a fixture as-is.
- Long reports are cut in the middle to fit a GitHub link (about 7,500 characters). The start and the state line are kept, and the full report is copied to the clipboard.
