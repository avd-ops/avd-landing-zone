# Releases

A release is a tagged commit of this repo (`vMAJOR.MINOR.PATCH`) with notes saying what changed and what was proven on a real deployment. Nothing has been released yet: until the first tag, use `master`.

> [!WARNING]
> Personal project, research and learning only, not for production, provided as is under the [MIT License](../LICENSE). See the [README](../README.md).

## What a release holds

The **Source code (zip)** on each [GitHub release](https://github.com/nickprignano/avd-landing-zone/releases) holds only what you need to deploy and run the landing zone:

| Folder | What it is |
|---|---|
| `bicep/`, `bicepconfig.json` | the templates |
| `parameters/` | the parameter files (tenant values come from environment variables) |
| `scripts/` | `deploy.sh`, the Cloud Shell ops scripts, the auto shutdown runbook, the image steps |
| `contracts/` | the avd-second-brain contracts the scripts read |
| `docs/` | how to deploy, operate and understand it |
| `README.md`, `LICENSE`, `CONTRIBUTING.md`, `releases/` | |

The website (`site/`), the tests, lessons, decisions and specs (`build/`), and the CI and editor configuration are left out by `export-ignore` lines in [`.gitattributes`](../.gitattributes). They are still in the repo, and links from `docs/` to `build/` point there.

## Use a release

In [Azure Cloud Shell](https://shell.azure.com), clone at the tag so every command runs the released code:

```bash
git clone --branch v1.0.0 --depth 1 https://github.com/nickprignano/avd-landing-zone.git ~/avd-landing-zone
cd ~/avd-landing-zone
```

Then follow [docs/deploy.md](../docs/deploy.md) and [docs/operations.md](../docs/operations.md), running their commands from that folder but skipping any clone/update preamble that checks out `master` or pulls. Keep the checkout at the release tag. The [deployment portal](https://nickprignano.github.io/avd-landing-zone/portal/) also switches to `master` and pulls, so use it only with `master`, not with a release.

## Notes for each release

One file per release, `vX.Y.Z.md`, copied from [TEMPLATE.md](TEMPLATE.md) in the pull request that prepares the release. The same text goes into the GitHub release body.
