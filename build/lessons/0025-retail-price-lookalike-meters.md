# 0025. The price list gains lookalike meters; match the product, not just the SKU

- **Area:** Preflight (cost estimate)
- **Found in / fixed by:** after #32 (pre-deployment preflight for `test.bicepparam`, 2026-09-30)

## What happened
The pre-deployment preflight priced only the profile share and the public IP. The session hosts and OS disks came back unpriced, even though the API returned the meters the preflight looks for:

```
[WARN ] Session hosts (1 x Standard_E4as_v5)
        No matching price. Meters returned: E4as v5 / E4as v5 (1 Hour)
[WARN ] OS disks (1 x Premium SSD P10)
        No matching price. Meters returned: P10 LRS / P10 LRS Disk (1/Month)
```

The deployment portal's Cost step reprices from the compute unit price, so it had nothing to show.

## Why
Each line must match exactly one meter (decision 0010), and the Retail Prices API now returns two for each:
- **Compute:** `Easv5 Series CloudServices` (effective 2026-01-01) uses the same SKU and meter name, `E4as v5`, at the Windows rate ($0.41), next to `Virtual Machines Easv5 Series` at the base rate ($0.226). The filter excluded only products named `Windows`.
- **OS disk:** `Premium Page Blob` has a `P10 LRS Disk` meter, as `Premium SSD Managed Disks` does.

The warning listed SKU and meter but not the product, so the two lookalikes printed as one line and the cause wasn't visible. A second query that printed the product name showed it.

## Fix
- Compute matches only `Virtual Machines …` products (still not Windows, Spot or Low Priority).
- The OS disk matches only `Premium SSD Managed Disks`.
- An unpriced line now names the product of each meter it saw.

## Guard
The offline price mock returns the lookalikes as the real API does: a `CloudServices` product with the same SKU, and a `Premium Page Blob` P10 meter at a different price. The PreDeployment scenario asserts that compute and the OS disk come from the right product.

## Rule
Match a price on the product as well as the SKU and meter. Print everything that tells candidates apart (product, SKU, meter, unit) when a match fails; when the list gains a lookalike, the message should show the difference.

## Follow-up: Private Link and NAT Gateway are listed under "Global" (2026-10-05)
The dev pre-deployment preflight left private endpoints and the NAT Gateway unpriced, with no meters returned. A query without the region showed why: the API lists both only under `armRegionName` `Global` (`location` `Global`), never per region. Next to them are lookalike hourly meters: `Fixed Private Endpoint T1` ($14/hour) and `Standard Service Endpoint Virtual Network` for Private Link, and `StandardV2` meters for the NAT Gateway.

- Both lines now query `armRegionName eq 'Global'` and match the exact meter: `Standard` / `Standard Private Endpoint` and `Standard` / `Standard Gateway`, per hour.
- **Guard:** the offline price mock returns these products only for a `Global` filter, with the lookalikes. The PreDeployment scenario asserts the meter of each line. Querying the region again brings back the warnings this run saw.
- **Rule:** when a lookup returns no meters at all, query the product without the region before deciding it isn't sold there.
