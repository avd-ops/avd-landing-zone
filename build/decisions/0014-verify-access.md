# 0014. Verify access from the operator's device in three layers, each claiming only what it measures

- **Status:** Proposed

## Context
After a deployment the portal says "sign in" and stops. Nothing confirms that the operator's network reaches AVD, that the desktop opens for the right person, or that a connection happened. A test account with stored credentials would answer some of that, but it costs a license and a secret, and it tests a device that isn't the user's (lesson 0003: only the user's device says anything about the user's experience). Details and sources: [verify-access-spec.md](../specs/verify-access-spec.md).

## Decision
A *Verify access* step in the portal, after *Sign in*, with three layers, run by the operator as themselves:
- **Reachability:** the latency step's browser method (warm-up, `no-cors`, median) against concrete end-user hosts. It's a warning, never a stop. It proves DNS, TCP and TLS, nothing more.
- **Launch:** the post-deployment state line carries the workspace and desktop `objectId`, read through REST. The portal builds the web client's direct launch link. The Windows App `ms-avd:` link waits until its parameters are confirmed.
- **Confirmation:** `Test-AvdUserConnection.ps1` queries `WVDConnections`, `WVDErrors` and `WVDCheckpoints` for the user, polls through ingestion lag, and fails closed.
  - Outcomes: *verified*, *failed* or *not verified*. A missing row is never a pass.
  - It reports connection setup time (Started→Connected), named as such: not AVD Insights' time to connect, and not time to a usable desktop.

## Alternatives considered
- **A stored test account signing in from Cloud Shell or CI:** a license and a secret to manage. It tests an Azure client, not the user's. That's Track B's job, as an option (decision 0015).
- **Timing from the browser or the client:** not measurable from a static page. The telemetry is objective, and it's already collected.
- **A hard stop on a failed probe:** a corporate proxy or content blocker would block people who can actually connect.

## Consequences
- No new resources and no new cost: the diagnostics already send `allLogs` to Log Analytics. A template test keeps it that way.
- The default deployment and its 30 minutes are unchanged.
- The portal makes one more kind of network request (the probe) and still sends nothing it measures or reads.
- The proof is honest and partial. The portal shows what each layer doesn't prove, beside the result.
