# Security policy

avd-landing-zone is a personal research project, not for production, provided as is, and not affiliated with the author's employer, Liquidware or Microsoft. There is no support agreement and no response time, but reports are welcome and read.

## Reporting a vulnerability

- **Privately, please.** Use **Report a vulnerability** on this repository's Security tab (GitHub private vulnerability reporting). If that button isn't there, open an issue titled "Security contact request" with no details, and a private channel will be arranged.
- **Never put secrets, tenant, subscription or object IDs, names or estate data in a report or an issue.** Issues are public.
- Say what is affected (a template, a script, the deployment portal), how it can be misused, and how to reproduce it with synthetic or placeholder data.

## What is in scope here

This repo deploys and operates the AVD estate (Bicep templates, PowerShell and Bash operator scripts, five-plane orchestrator, and static deployment portal). See [docs/threat-model.md](docs/threat-model.md) for this repo's threat model and the [security review page](https://avd-ops.dev/security.html) for the family-wide map.
