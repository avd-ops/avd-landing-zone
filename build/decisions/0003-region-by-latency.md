# 0003. Region chosen by browser latency; parameter files default, `AVD_LOCATION` overrides

- **Status:** Accepted

## Context
Session latency matters most, it can only be measured from the user's device (lesson 0003), and the parameter files hardcoded the region.

## Decision
A static page measures latency from the browser and emits the preflight (`-Location`) and deploy (`-l`) commands. The parameter files read `AVD_LOCATION` with a default; `deploy.sh -l` and CI's `AZURE_LOCATION` set it. The preflight checks the region offers AVD host pools, VM size, quota and storage SKU.

## Consequences
No file edits to change region; zones default to none, which works everywhere (lesson 0001). Zone redundancy is an explicit file change.
