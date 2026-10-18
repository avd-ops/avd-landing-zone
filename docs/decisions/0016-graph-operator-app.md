# 0016. One delegated Microsoft Graph sign-in per session, through a dedicated public client app

- **Status:** Accepted

## Context
Each script asked Microsoft Graph for its own scope set (Read, Fix, PreDeployFix, Cleanup) and reused a sign-in only when it covered that set. A normal session (preflight, `-Fix`, demo, cleanup) therefore asked for a new device code at almost every step. A code left too long times out after 120 seconds, and on 2026-10-18 that left the demo's device objects behind ([lesson 0029](../lessons/0029-device-cleanup-rerun.md)). The scripts also signed in through Microsoft's shared "Microsoft Graph Command Line Tools" app, so every new scope could mean another consent prompt, and tenant-wide consents piled up on that shared app.

## Decision
- **One scope set** (`Get-AvdGraphScope` in `AvdLandingZone.psm1`), the union of the four: every purpose asks for it, so the first sign-in covers the session. The purpose only changes the message. `Connect-AvdLandingZone.ps1` signs in up front and checks the sign-in with a real request.
- **A dedicated app registration, "avd-opsbot"**, created once by `Initialize-AvdGraphApp.ps1`: a **public client** (no secret, no certificate) with **delegated** permissions, admin consent granted once (one `AllPrincipals` grant, including `openid profile offline_access` so nobody sees a prompt), and **Assignment required** on, with the operator and the operators group (default `AVD Admins`) assigned. Scripts use it when `AVD_GRAPH_CLIENT_ID` is set and fall back to Microsoft's default app when it isn't. No client ID is committed.
- **Delegated, not app-only.** Every change is made as a named person, limited by that person's Entra ID roles; there is no credential to store, rotate or leak (lesson 0002: never make operators remember secrets); sign-ins show the person and the app in the logs, and Conditional Access can require MFA or a compliant device for this app. App-only Graph would need a secret or certificate in Cloud Shell, and would let anyone holding it act with the app's full permissions. App-only automation (GitHub Actions with OIDC) belongs to the swarm repositories, not here.
- **Consent for assigned users only** is done with Assignment required, not with per-user grants: an `oauth2PermissionGrant` for a principal names one user and can't name a group, so a tenant-wide grant plus required assignment is the supported way to limit who can use the app.
- **No token storage of our own.** The Microsoft Graph SDK keeps the sign-in for the session; how long it lasts in Cloud Shell is recorded from real runs in `docs/operations.md`.

## Consequences
- One device code per Cloud Shell session instead of one per step; no consent prompts after the one-time setup.
- A read-only check now asks for ReadWrite scopes. Delegated scopes never exceed the person's roles, so a Global Reader still can't change anything, but through Microsoft's default app those scopes need an administrator's consent first. The operator app removes that.
- The setup needs a Global Administrator (or a Privileged Role Administrator with an Application Administrator), once per tenant. Assigning a group needs Microsoft Entra ID P1; without it, operators are assigned one by one.
- `Initialize-AvdGraphApp.ps1` keeps its own copy of the scopes so it runs in Windows PowerShell 5.1 without the module; a unit test keeps the two lists equal, and another fails when a script calls a Graph path no scope in the set covers.
