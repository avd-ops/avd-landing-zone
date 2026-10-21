# CI / CD

Workflows:

| Workflow | Trigger | Jobs |
|---|---|---|
| [`validate.yml`](../.github/workflows/validate.yml) | PRs and pushes to `master` touching Bicep, parameters, scripts or config | **bicep** (lint + build template and param files) · **snapshot** (offline what-if against the base branch, advisory) · **scripts** (PSScriptAnalyzer over `scripts/`, Pester: unit tests, offline end-to-end scenarios (`build/tests/offline`) and template guards, with a standalone Bicep CLI; shellcheck) · **psrule** (Well-Architected rules, a gate) · **what-if** (opt-in) |
| [`secret-scan.yml`](../.github/workflows/secret-scan.yml) | Every PR and push to `master` | **gitleaks** over the full history. Accepted false positives live in [`.gitleaksignore`](../.gitleaksignore); the same scan runs before each commit through `.githooks/pre-commit` ([CONTRIBUTING.md](../CONTRIBUTING.md#secret-scanning)) |
| [`lanes.yml`](../.github/workflows/lanes.yml) | Every PR and push to `master` | **no-hcl**: fails on any Terraform, Packer or other HCL file, which belongs to nerdio-hcl ([out-of-scope.md](out-of-scope.md#another-projects-lane)) |
| [`deploy.yml`](../.github/workflows/deploy.yml) | Manual (`workflow_dispatch`) | Deploys `parameters/<env>.bicepparam` to the matching GitHub Environment, with optional what-if only |
| [`image-build.yml`](../.github/workflows/image-build.yml) | Third Monday of the month (a daily cron on days 15–21 that skips all but Monday), and manual with `force` and `emergency` | Builds the month's golden image with Azure Image Builder through `scripts/ops/Start-AvdImageBuild.ps1`, keeps the customization log as an artifact and opens an `image-build` issue. Signs in through the `images` GitHub Environment's federated identity. Setup: [images.md](images.md) |
| [`pages.yml`](../.github/workflows/pages.yml) | Pushes to `master` touching `site/`, and manual | Publishes `site/` (the deployment portal, the region latency page) to GitHub Pages. One-time setup: **Settings → Pages → Source: GitHub Actions**. Until that is set, the last published site stays up |

**Advisory AI review** comes from GitHub Copilot code review, not a workflow: Copilot follows [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) (the review checklist, distilled from `CLAUDE.md`). Request it on a PR, or have a branch ruleset on `master` request it automatically (**Settings → Rules → Rulesets → Automatically request Copilot code review**). It needs no repository secret, and it reviews fork PRs too. It only comments: no AI review satisfies a review requirement ([second-brain-spec.md](https://github.com/nickprignano/avd-second-brain/blob/main/docs/operations-spec.md) §9.3).

The **bicep** and **scripts** jobs need no setup: the parameter files compile with placeholder identity values set in the workflow. `bicepconfig.json` makes security-relevant linter findings errors, and the lint step fails on any warning too: Bicep exits 0 on a warning, and warnings like BCP245 or BCP037 mean a resource that fails at deploy time.

**Tool versions are pinned** in `validate.yml`'s `env` (Bicep, PSRule, PSRule for Azure, PSScriptAnalyzer, Pester), and the session hook, `image-build.yml`, `ps-rule.yaml` and the live `-WellArchitected` review use the same ones (a template test checks it). A new release changes nothing until a PR bumps the pin and CI passes on it.

**The snapshot job** runs `bicep snapshot` on each parameter file at the base commit and at the PR, with placeholder subscription and tenant IDs, and writes the difference to the job summary in what-if's format: which resources and properties the PR would change in dev, test, prod and the image files. It needs no Azure sign-in and never fails on a difference. Expressions that need a live subscription (`reference()`, `list*()`) stay unevaluated, so the opt-in what-if job still has the last word. Run it locally with `build/snapshot-diff.sh origin/master` (identity variables set as for `build-params`).

**PSRule** is a gate. Every finding must be fixed, or suppressed with a written justification in [`.ps-rule/Suppressions.Rule.yaml`](../.ps-rule/Suppressions.Rule.yaml); each suppression group's `# Synopsis:` line is the justification. Keep suppressions narrow (one rule, one resource type) so a new resource can't slip through an existing one.

### Offline checks we chose, and the ones we left out

Checked 2026-10-20 against the current Bicep and PSRule releases. Everything here runs on the GitHub runner with no Azure calls.

| Tool | Status | Why |
|---|---|---|
| Bicep linter (`bicepconfig.json`) | **Gate**, any diagnostic fails | Security rules are errors. `no-hardcoded-location`, `no-loc-expr-outside-parameters`, `no-hardcoded-outputs` and `secure-parameters-in-parameters-file` are errors too: the templates already pass them, so they only guard. Left off: `use-recent-api-versions` and `use-recent-module-versions` (results change with each Bicep release, not with our code), `no-module-name` (129 findings: deployment names are deliberate), `use-description-*` (hundreds of findings, no deploy-time signal), `use-user-defined-types` (86, a refactor), `what-if-short-circuiting` (22 module parameters that hide resources from what-if; worth a separate change) |
| PSRule for Azure | **Gate** | Expands nested AVM deployments and checks every resource against the Well-Architected rules; the same rules run on the live landing zone (decision 0009) |
| `bicep snapshot` | **Advisory** | Offline what-if diff per parameter file (above) |
| ARM-TTK | Not used | Microsoft took the Bicep linter's default rules from ARM-TTK's test cases; on compiled Bicep it mostly flags generated code |
| Checkov 3.3 | Not used | Its Bicep parser failed on 11 of our files, and on the compiled ARM JSON it saw only the top-level deployments, so it checked nothing PSRule doesn't |

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
pwsh -c "Invoke-Pester ./build/tests"
shellcheck scripts/deploy/deploy.sh
build/snapshot-diff.sh origin/master   # offline what-if against master
gitleaks git --redact .
```
