# 0031. Every field of a pasted state line is input, not only its settings

- **Area:** Deployment portal
- **Found in / fixed by:** a design review of the shared portal engine (avd-ops `docs/portal-engine-spec.md`, section 14); #111

## What happened
Red team PH-4 made the portal check the settings a pasted state line carries (`validSettings()`), and the settings test sent a crafted `namePrefix` through it. Reading the engine for the shared portal engine design found what that left out. `validSettings()` passes every key it doesn't know straight through, and `analyze()` merged the whole context into the config the next commands are built from. A context carrying `repoUrl` or `ref` changed the clone and checkout in every block of that analysis, and `sizing` and `power` went into flags without quotes. Check data went into commands with no check either: regions from `hostpool-region` and `lz-region` as `-Location`, quota items into a REST path and a comment line, a `lz-missing` entry merged whole into the config, and `deploymentName`, a recovery `runId` and the `verify` user quoted but unchecked.

No real paste did this. The operator pastes their own output, but the paste box takes text from anywhere (a forum answer, a chat, an issue), and the blocks run as subscription Owner.

## Why
The check sat where the first known path was (settings typed or pasted), not where the trust boundary is (anything parsed from the paste). Every fixture is real output, so every test passed: nothing sent a hostile field other than the settings.

## Fix
- `contextSettings()` lets only the settings and `sizing`, `power` and `launch` from a context reach the config, each checked field by field in the scripts' own ranges (`validSizing()`, `validPower()`, `launchTarget()`). A null field (`deploy.sh` writes one for a flag it wasn't given) is left out, not rejected. Every other key is dropped, and `analyze()` returns only the checked sizing and power.
- `pasted()`, `pastedList()`, `pastedQuota()` and `pastedLandingZone()` check the values read from check data and from context fields the decisions use, where they are read.
- `preamble()` clones this repo when the config's URL isn't a plain GitHub repo.
- The page checks sizing and power on load and on paste the same way.

## Guard
`portal-core.test.mjs`, "crafted paste": a crafted state line for each of those fields, and then every string field of every `state-*` fixture replaced by the crafted value one at a time, must produce no command that carries it outside a single-quoted string, and no clone of another repo. Fuzzing every field, not only the ones read today, is what covers the next field a decision starts reading. It fails against the old engine (`error: 'context'`). Every existing fixture gives the same actions as before.
