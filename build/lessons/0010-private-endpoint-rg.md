# 0010. Private endpoints live in their target's resource group

- **Area:** Preflight
- **Found in / fixed by:** PR #13

## What happened
"Storage private endpoint with DNS zone group" and "AVD Private Link DNS zone" failed although both exist.

## Why
The lookup searched only the network resource group; AVM creates each private endpoint in its target's resource group (storage, avd, demo).

## Fix
Search the whole subscription for the endpoint whose connection targets the resource.

## Guard
Pester `Get-AvdPrivateEndpointDnsZoneId`; offline PostDeployment scenario.

## Rule
Don't assume where a module puts child resources; look them up by relationship (target ID), not by location.
