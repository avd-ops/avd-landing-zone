# Releases

A release is a tagged commit of this repo (`vMAJOR.MINOR.PATCH`) with notes saying what changed and what was proven on a real deployment. Nothing has been released yet: until the first tag, use `master`.

> [!WARNING]
> Personal project, research and learning only, not for production, provided as is under the [MIT License](../LICENSE). See the [README](../README.md).

## What a release holds

The **Source code (zip)** on each [GitHub release](https://github.com/avd-ops/avd-landing-zone/releases) holds only what you need to deploy and run the landing zone:

| Folder | What it is |
|---|---|
| `bicep/`, `bicepconfig.json` | the templates |
| `parameters/` | the parameter files (tenant values come from environment variables) |
| `scripts/` | `deploy.sh`, the Cloud Shell ops scripts, the auto shutdown runbook, the image steps |
| `contracts/` | the avd-second-brain contracts the scripts read |
| `.ps-rule/`, `ps-rule.yaml` | the accepted PSRule suppressions the `-WellArchitected` review reads |
| `docs/` | how to deploy, operate and understand it |
| `README.md`, `LICENSE`, `CONTRIBUTING.md`, `releases/` | |

The website (`site/`), the tests, lessons, decisions and specs (`build/`), and the CI and editor configuration are left out by `export-ignore` lines in [`.gitattributes`](../.gitattributes). They are still in the repo, and links from `docs/` to `build/` point there.

## Use a release

In [Azure Cloud Shell](https://shell.azure.com), clone the repo and check out the tag, so every command runs the released code:

```bash
git clone https://github.com/avd-ops/avd-landing-zone.git ~/avd-landing-zone
cd ~/avd-landing-zone && git checkout v1.0.0
```

Use a full clone, not `--depth 1 --branch <tag>` or the zip. `deploy.sh` pins the auto shutdown runbook to the commit being deployed only when it can see that commit on a GitHub branch; from a tag-only shallow clone or a zip it falls back to the runbook on `master`.

Then follow [docs/deploy.md](../docs/deploy.md) and [docs/operations.md](../docs/operations.md) from that folder, **without their first lines**: each block starts by cloning or updating the repo (`git checkout -q master; git pull -q --ff-only` or `git pull --ff-only`), which would move you off the release. Run only the lines after it. The [deployment portal](https://avd-ops.github.io/avd-landing-zone/portal/) adds the same preamble to every command, so use the portal with `master`, not with a release.

## Notes for each release

One file per release, `vX.Y.Z.md`, copied from [TEMPLATE.md](TEMPLATE.md) in the pull request that prepares the release. The same text goes into the GitHub release body.
