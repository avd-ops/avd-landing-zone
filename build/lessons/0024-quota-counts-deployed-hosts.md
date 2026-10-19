# 0024. A deployed host's vCPUs are already in "used"; the quota check must not count them twice

- **Area:** Preflight
- **Found in / fixed by:** after #29 (post-deployment preflight on 2026-09-30)

## What happened
Right after a successful deployment of one `Standard_E4as_v5` host, the post-deployment preflight failed:

```
[FAIL ] standardEASv5Family vCPU quota
        0 free, 4 needed
```

The data was `limit 4, used 4, needed 4`. Everything else passed, including the three tenant steps.

## Why
`Test-AvdVmCapacity` compared the vCPUs for the requested hosts with `limit − used`. But `used` already includes the landing zone's own deployed hosts, so a deployed landing zone was measured as if it needed its hosts all over again. Before deployment, where the check was written, nothing is deployed and the comparison holds. The offline mock's quota limit of 10 was generous enough to hide this.

## Fix
`Test-AvdVmCapacity -DeployedSizes` takes the sizes of the landing zone's own hosts (`Get-AvdDeployedHostSize`), counts their vCPUs per quota family and for the regional total, and requires only the difference. The detail says so: `0 free, 4 needed (4 already used by this landing zone's hosts, so 0 more)`. The quota request the portal builds asks for the difference too. Both the post-deployment and the pre-deployment preflight pass the deployed sizes (a redeploy had the same double count).

## Guard
The `PostDeployQuota` offline scenario uses the real numbers (Easv5 limit 4, used 4, one E4as_v5 host deployed). The deployed landing zone passes. A scale-out to two hosts fails and asks for 4 more vCPUs.

## Rule
A check that compares a request with current usage must ask whether the usage already includes the thing being requested, and test with a mock whose limits are tight enough to show it.
