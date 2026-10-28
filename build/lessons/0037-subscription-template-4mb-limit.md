# 0037. A second Bicep module reference to the AVM virtual-machine module pushes the subscription template past ARM's 4 MB request limit

- **Area:** Bicep
- **Found in / fixed by:** sandbox batch run (2026-10-28) / this PR

## What happened
`deploy.sh -p parameters/dev.bicepparam` failed at `az deployment sub create` before Azure Resource Manager started the deployment:

```
ERROR: {"code": "RequestContentTooLarge", "message": "The request content size exceeds the maximum size of 4 MB."}
```

## Why
Azure Resource Manager rejects a deployment HTTP `PUT` request whose compiled template exceeds 4 MB (`4,194,304` bytes). `bicep build-params parameters/dev.bicepparam --stdout` emits pretty-printed JSON with 2-space indentation and every nested module's `@description` metadata inlined.

Each reference to `br/public:avm/res/compute/virtual-machine:0.22.3` inlines the AVM VM module, its nested AVM NIC module (`vm_nic`), and 11 extension sub-deployments (~676 KB per reference at `main.bicep`'s indentation depth). When multi-pool support added `module additionalSessionHosts 'modules/sessionHosts.bicep'` beside `module sessionHosts 'modules/sessionHosts.bicep'`, Bicep inlined a second full copy of `modules/sessionHosts.bicep` even when `extraHostPools` was empty (`count: 0`), pushing `templateJson` from ~3.55 MB to 4,316,352 bytes (4.12 MB).

## Fix
`bicep/modules/sessionHosts.bicep` now accepts `additionalPools` and creates and FSLogix-configures the VMs for both the primary pool and any additional pools inside its single `br/public:avm/res/compute/virtual-machine:0.22.3` loop. A small companion module, `bicep/modules/registerPoolHosts.bicep`, registers each additional pool's hosts using that pool's `@secure()` registration token without duplicating the AVM virtual-machine module.

## Guard
`build/tests/Template.Tests.ps1` (`Multi-pool topology, Private Link and per-zone Private DNS`) compiles `parameters/dev.bicepparam`, `parameters/test.bicepparam`, and `parameters/prod.bicepparam`, asserts that the UTF-8 byte length of `templateJson` is under `4,194,304` bytes (4 MB), and asserts that `vm_nic` appears at most twice (once for `sessionHosts` and once for `jumpbox`).

## Rule
Never reference a module that inlines `avm/res/compute/virtual-machine` more than once per role in `bicep/main.bicep`, even behind a loop that defaults to zero items. Check the compiled `templateJson` byte length against ARM's 4 MB limit in `Template.Tests.ps1`.
