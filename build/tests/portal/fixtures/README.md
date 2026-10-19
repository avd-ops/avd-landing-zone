# Portal fixtures

Output pasted from real Azure Cloud Shell runs during the first end-to-end deployment
(September 2026), trimmed to the lines that matter and redacted: UPNs are `admin@contoso.com`
/ `user@contoso.com`, subscription, tenant and object IDs are placeholders, and resource names
with random suffixes use `abc123`. They predate the `AVDLZ-STATE` line, so they also test the
portal's text fallback. Files named `state-*.txt` come from the offline scenarios and carry it.

Add a fixture whenever a real paste is analysed wrongly (see `.claude/skills/retro`).

`pii-sample.txt` is invented (Fabrikam), not a real run: it holds one of every kind of private value the issue-report redaction must remove (`tests/portal/report.test.mjs`).
