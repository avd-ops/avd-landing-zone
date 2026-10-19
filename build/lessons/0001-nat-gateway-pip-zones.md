# 0001. AVM NAT Gateway public IP defaults to zones 1-3

- **Area:** Bicep
- **Found in / fixed by:** PR #12

## What happened
First real deployment to North Central US failed: `LocationNotSupportAvailabilityZones` on `pip-ng-vnet-avdlz-dev`.

## Why
`avm/res/network/nat-gateway` defaults each public IP to `availabilityZones: [1, 2, 3]` even when the NAT Gateway itself is non-zonal (`availabilityZone: -1`). The landing zone's `availabilityZones` never reached the network module, so the default applied in a region without zones.

## Fix
`network.bicep` takes `availabilityZones` and gives the IP no zones when it is empty, 1-3 otherwise.

## Guard
`build/tests/Template.Tests.ps1` (NAT Gateway public IP zones) compiles the template and fails if the IP stops following `availabilityZones`.

## Rule
When adding an AVM module, check its nested defaults for zones, SKUs and locations: compile the template and walk the nested deployments for parameters the parent does not set. Test in a region without zones (North Central US) as well as a zonal one.
