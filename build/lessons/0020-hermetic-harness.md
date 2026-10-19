# 0020. The offline harness must not depend on the machine's tools

- **Area:** Tests
- **Found in / fixed by:** the deployment portal PR

## What happened
The pre-deployment scenario passed for weeks, then failed four times in a row ("az available (used by deploy.sh)") in a session whose PATH had no `az`.

## Why
The preflight's tooling check looks for `az`. The earlier runs happened to have a stub `az` on PATH from an ad-hoc scratch folder, and CI runners have the real one. The harness never provided it, so its results depended on the machine.

## Fix
`build/tests/offline/bin/az` is a stub the harness puts first on PATH (`Initialize-OfflineScenario.ps1`).

## Guard
The scenarios now pass with only the tools the session hook installs, and in CI.

## Rule
Offline tests provide every external tool they touch. When a test passes locally, check what on your machine made it pass.
