# 0030. Microsoft Graph's service principal doesn't list every delegated permission it issues

- **Area:** Ops scripts (Graph sign-in)
- **Found in / fixed by:** PR #47

## What happened
The first real run of `Initialize-AvdGraphApp.ps1` (prignano.us, 2026-10-18) stopped before creating the app:

```
  [PASS ] Signed in as claude@prignano.us
  [FAIL ] Microsoft Graph publishes every permission the app needs
          Not found: Device.ReadWrite.All
```

In the same session, the Graph token from Microsoft's default app carried `Device.ReadWrite.All` (`Get-MgContext` listed it), and the demo cleanup used it to delete the host's Entra ID device object.

Also: that default-app sign-in already had every scope the scripts use (from consent given earlier), so `Connect-AvdLandingZone.ps1` reused it. Had `AVD_GRAPH_CLIENT_ID` been set, the operator app would never have been used.

## Why
The setup reads permission IDs from the `oauth2PermissionScopes` of Graph's service principal, so as not to hard-code IDs. That list doesn't include every delegated permission Entra ID issues for Graph: `Device.ReadWrite.All` was missing, yet it was consented and issued. The offline mock listed all of them, so it was more permissive than Azure (lesson 0020).

The reuse rule accepted any sign-in that covered the scopes, from whichever app.

## Fix
- The setup grants every scope **by name** in the `oauth2PermissionGrant`, which is what Entra ID uses to issue tokens. A scope Graph's service principal doesn't list is reported and left out of the app registration's permission list, which needs IDs.
- With a client ID set, `Connect-AvdGraph` reuses only a sign-in through that app. Otherwise it signs in again, once, through the operator app.
- The mock's Graph service principal leaves out `Device.ReadWrite.All`, as the real one does.

## Guard
In the GraphSignIn scenario, the setup must succeed and grant `Device.ReadWrite.All` by name. It fails against the old setup (`setup EXIT=1`). A default-app sign-in with every scope must switch to the operator app once its client ID is set. It fails against the old reuse rule (`default-to-operator connects=0`).

## Rule
Don't treat Graph's `oauth2PermissionScopes` as the full list of delegated permissions; grant by scope value. An explicit client ID beats a sign-in that merely has the scopes.
