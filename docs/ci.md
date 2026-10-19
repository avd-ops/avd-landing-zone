# CI / CD

Workflows:

| Workflow | Trigger | Jobs |
|---|---|---|
| [`validate.yml`](../.github/workflows/validate.yml) | PRs and pushes to `master` touching Bicep, parameters, scripts or config | **bicep** (lint + build template and param files) · **scripts** (PSScriptAnalyzer over `scripts/`, Pester: unit tests, offline end-to-end scenarios (`tests/offline`) and template guards, with a standalone Bicep CLI; shellcheck) · **psrule** (Well-Architected rules, a gate) · **what-if** (opt-in) |
| [`secret-scan.yml`](../.github/workflows/secret-scan.yml) | Every PR and push to `master` | **gitleaks** over the full history. Accepted false positives live in [`.gitleaksignore`](../.gitleaksignore); the same scan runs before each commit through `.githooks/pre-commit` ([CONTRIBUTING.md](../CONTRIBUTING.md#secret-scanning)) |
| [`lanes.yml`](../.github/workflows/lanes.yml) | Every PR and push to `master` | **no-hcl**: fails on any Terraform, Packer or other HCL file, which belongs to nerdio-hcl ([out-of-scope.md](out-of-scope.md#another-projects-lane)) |
| [`deploy.yml`](../.github/workflows/deploy.yml) | Manual (`workflow_dispatch`) | Deploys `parameters/<env>.bicepparam` to the matching GitHub Environment, with optional what-if only |
| [`image-build.yml`](../.github/workflows/image-build.yml) | Third Monday of the month (a daily cron on days 15–21 that skips all but Monday), and manual with `force` and `emergency` | Builds the month's golden image with Azure Image Builder through `scripts/ops/Start-AvdImageBuild.ps1`, keeps the customization log as an artifact and opens an `image-build` issue. Signs in through the `images` GitHub Environment's federated identity. Setup: [images.md](images.md) |

**Advisory AI review** comes from GitHub Copilot code review, not a workflow: Copilot follows [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) (the review checklist, distilled from `CLAUDE.md`). Request it on a PR, or have a branch ruleset on `master` request it automatically (**Settings → Rules → Rulesets → Automatically request Copilot code review**). It needs no repository secret, and it reviews fork PRs too. It only comments: no AI review satisfies a review requirement ([second-brain-spec.md](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) §9.3).

The **bicep** and **scripts** jobs need no setup: the parameter files compile with placeholder identity values set in the workflow. `bicepconfig.json` makes security-relevant linter findings errors, and the lint step fails on any warning too: Bicep exits 0 on a warning, and warnings like BCP245 or BCP037 mean a resource that fails at deploy time.

**PSRule** is a gate. Every finding must be fixed, or suppressed with a written justification in [`.ps-rule/Suppressions.Rule.yaml`](../.ps-rule/Suppressions.Rule.yaml); each suppression group's `# Synopsis:` line is the justification. Keep suppressions narrow (one rule, one resource type) so a new resource can't slip through an existing one.

## Azure access (OIDC, no stored secrets)

### 1. App registration and permissions

```bash
az ad app create --display-name avd-lz-cicd            # note appId
az ad sp create --id <appId>
az role assignment create --assignee <appId> --role Owner \
  --scope /subscriptions/<landing-zone-subscription-id>
```

**Owner** is needed because the deployment creates role assignments and policy assignments. If you prefer, use Contributor + Role Based Access Control Administrator + Resource Policy Contributor.
The pipeline makes no Microsoft Graph calls when `AVD_SERVICE_PRINCIPAL_ID` and the group IDs are provided as variables, so no Graph permission is needed.

### 2. Federated credentials

OIDC subjects are exact-match. Create one per context:

| Used by | Subject |
|---|---|
| what-if on PRs | `repo:<owner>/<repo>:pull_request` |
| deploy to dev | `repo:<owner>/<repo>:environment:dev` |
| deploy to prod | `repo:<owner>/<repo>:environment:prod` |

```bash
az ad app federated-credential create --id <appId> --parameters '{
  "name": "avd-lz-prod",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:environment:prod",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

### 3. Secrets and variables

Create GitHub Environments `dev` and `prod`, and add **required reviewers** to `prod`. Set these on each environment. For the PR what-if, which runs outside an environment, set them at repository level too.

| Kind | Name | Value |
|---|---|---|
| Secret | `AZURE_CLIENT_ID` | app registration appId |
| Secret | `AZURE_TENANT_ID` | tenant ID |
| Secret | `AZURE_SUBSCRIPTION_ID` | landing zone subscription |
| Secret | `AVD_LOCAL_ADMIN_PASSWORD` | Optional break-glass password; if unset, `deploy.sh` generates a random one |
| Variable | `AZURE_LOCATION` | The region the landing zone is deployed to, e.g. `northcentralus`. It overrides the parameter file's default through `AVD_LOCATION` |
| Variable | `AVD_USERS_GROUP_ID` | group object ID |
| Variable | `AVD_ADMINS_GROUP_ID` | group object ID |
| Variable | `AVD_SERVICE_PRINCIPAL_ID` | `az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv` |
| Variable | `AVD_ALERT_EMAIL` | optional |
| Variable | `AVD_MONTHLY_BUDGET` | optional |
| Variable (repo) | `AZURE_WHATIF_ENABLED` | `true` to enable the PR what-if |

## Running the checks locally

```bash
az bicep lint --file bicep/main.bicep
AVD_USERS_GROUP_ID=x AVD_ADMINS_GROUP_ID=x AVD_SERVICE_PRINCIPAL_ID=x AVD_LOCAL_ADMIN_PASSWORD=Placeholder-1234 \
  az bicep build-params --file parameters/prod.bicepparam --stdout > /dev/null
pwsh -c "Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
pwsh -c "Invoke-Pester ./tests"
shellcheck scripts/deploy/deploy.sh
gitleaks git --redact .
```
