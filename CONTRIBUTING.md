# Contributing

Contributions and forks are welcome and encouraged. Open an issue for a bug, a question or an idea, or a pull request with a fix, a test, a doc or a lesson from a real run. Forking it to fit your own environment is just as welcome.

This is a personal research and learning project, not affiliated with the author's employer, and not intended for production use. Contributions are accepted under the [MIT License](LICENSE), as is and without warranty.

This is an **opinionated** landing zone: Entra ID-only, Intune-managed, private by default, greenfield. Contributions that harden or simplify that path are the best fit here. Another identity model or brownfield options belong in a fork, or in the [AVD LZA](https://github.com/Azure/avdaccelerator), which already covers them: the narrow scope is the point (see [`docs/design-decisions.md`](docs/design-decisions.md)).

## Before you open a PR

Run the same checks CI runs ([`docs/ci.md`](docs/ci.md#running-the-checks-locally)):

```bash
az bicep lint --file bicep/main.bicep
AVD_USERS_GROUP_ID=x AVD_ADMINS_GROUP_ID=x AVD_SERVICE_PRINCIPAL_ID=x AVD_LOCAL_ADMIN_PASSWORD=Placeholder-1234 \
  az bicep build-params --file parameters/prod.bicepparam --stdout > /dev/null
pwsh -c "Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
pwsh -c "Invoke-Pester ./tests"
shellcheck scripts/deploy/deploy.sh
```

`./tests` holds three kinds of test: unit tests for the ops module, **offline end-to-end scenarios** (`tests/offline`: the real scripts against a mock of Azure and Graph), and **template guards** (compile the Bicep and assert on it). The last two need the Bicep CLI on `PATH`.

If your change touches resources, include `deploy.sh --what-if` output from a test subscription in the PR.

## Secret scanning

The repo is public, so a leaked ID or key is public the moment it's pushed. Turn on the pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks   # needs gitleaks 8.30.1: https://github.com/gitleaks/gitleaks/releases
```

The hook runs `gitleaks` over the staged changes and blocks the commit if it finds something, or if `gitleaks` isn't installed. The [`secret-scan`](.github/workflows/secret-scan.yml) workflow scans the full history on every PR as a backstop. A false positive goes in [`.gitleaksignore`](.gitleaksignore) by fingerprint, with a comment saying what it is. A real secret gets rotated first: deleting it in a later commit leaves it in history.

## When a real run surprises you

Real deployments and Cloud Shell runs are the source of truth. When one fails for a reason the tests didn't catch:
1. **Fix it.**
2. **Add a guard** (a test, an offline scenario or a preflight check) that fails if it comes back.
3. **Record a lesson** in [`docs/lessons`](docs/lessons/README.md).

The routine is written up in [`.claude/skills/retro/SKILL.md`](.claude/skills/retro/SKILL.md), and the PR template asks for it. Choices that shape the repo are recorded in [`docs/decisions`](docs/decisions/README.md). [`CLAUDE.md`](CLAUDE.md) collects the standing rules.

## Conventions

- **Pin AVM versions** (`br/public:avm/res/...:<version>`) and note version bumps in the PR. Use native resources only where AVM has no module or adds nothing.
- **One concern per module.** `main.bicep` stays readable; push complexity down.
- **Everything declarative.** Session host configuration belongs in `scripts/sessionhost/`, runs through Run Commands, and must be **idempotent** (it re-runs on every deployment). No post-deployment scripts, and no runtime downloads beyond Microsoft's agent links.
- **Windows PowerShell 5.1**: Run Commands use it, so avoid PowerShell 7-only syntax in `scripts/sessionhost/` and `scripts/ops/host/`. The ops scripts themselves target PowerShell 7 (Cloud Shell).
- **Ops scripts** (`scripts/ops/`) must stay check-by-default: anything that changes state goes behind `-Fix` or a confirmation, and supports `-WhatIf`.
- **Secure by default.** New resources get private endpoints where supported, diagnostics to Log Analytics, and least-privilege RBAC on Entra groups.
- **No tenant data in the repo.** Identity values and secrets come from environment variables.
- Every parameter gets an `@description`. Update `docs/` when behavior changes.

## License

By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).
