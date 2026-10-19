# 0003. Latency measured from Cloud Shell says nothing about users

- **Area:** Region choice
- **Found in / fixed by:** PR #8

## What happened
Picking the closest region was proposed as a Cloud Shell preflight step.

## Why
Cloud Shell runs in an Azure datacenter; the user's latency has to be measured from the user's device.

## Fix
A static page (`site/region-latency/`) measures from the browser and builds the preflight and deploy commands with `-Location`.

## Guard
None automated; the page's region list was checked against DNS (each endpoint resolves to its own region).

## Rule
Measure where the user is. Keep endpoint lists to ones verified to be regional.
