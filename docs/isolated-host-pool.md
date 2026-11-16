# Isolated Host Pool Flavor

`avd-landing-zone` supports deploying a standalone, single-session **isolated host pool** alongside standard human pooled or personal pools using `bicep/modules/additionalPool.bicep`. It works on its own from Cloud Shell with no dependency on `avd-swarm`, `avd-second-brain`, or any external executor.

## When to use it

- Workloads that require single-session ephemeral isolation, strict RDP device-redirection lockdown, and separate Intune policy targeting (`avd-isolated` assignment filter in `avd-intune`).
- Environments that want an AVD-native isolated desktop pool for bounded UI automation or high-isolation tasks when custom VNet, custom image, or sovereign-cloud control is required.

## Recommended `topology.hostPools` entry

Add a dedicated `Personal` pool entry to `topology.hostPools`:

```json
{
  "name": "isolated",
  "friendlyName": "Isolated Single-Session Pool",
  "hostPoolType": "Personal",
  "personalDesktopAssignmentType": "Automatic",
  "loadBalancerType": "Persistent",
  "preferredAppGroupType": "Desktop",
  "maxSessionLimit": 1,
  "startVmOnConnect": true,
  "deployScalingPlan": false,
  "rdpProperties": "targetisaadjoined:i:1;enablerdsaadauth:i:1;drivestoredirect:s:;redirectclipboard:i:0;redirectprinters:i:0;usbdeviceredirect:s:;redirectsmartcards:i:0;audiomode:i:2;",
  "enablePrivateEndpoint": true
}
```

## Isolation controls

1. **Single-session only:** `hostPoolType: "Personal"` ensures one session per host so tasks never share OS processes or user windows.
2. **Redirection off:** Clipboard, drive, printer, USB, and smartcard redirection are disabled in `rdpProperties`.
3. **Separate Intune targeting:** Name session hosts with the `avd-iso-` prefix so `avd-intune`'s `avd-isolated` assignment filter isolates their Settings Catalog, WDAC/App Control, and compliance policies from human AVD pools.
4. **Ephemeral lifecycle:** Deallocate or reimage hosts at task end so no compute meter runs idle.
