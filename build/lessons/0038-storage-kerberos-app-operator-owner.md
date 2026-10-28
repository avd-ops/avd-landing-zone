# 0038. When an operator deploys the storage account with Entra Kerberos, Entra sets that operator as the storage app's owner

- **Area:** Preflight
- **Found in / fixed by:** sandbox batch run (2026-10-28) / this PR

## What happened
After `deploy.sh` deployed the landing zone under an interactive operator sign-in, `Test-AvdLandingZoneReadiness.ps1 -Fix` failed at Step 1:

```
[FAIL ] Storage account Entra app exists
        [Storage Account] stavdlzdev000000000000.file.core.windows.net: every app with this name has owners, which the app Azure creates never has: 5fa82297-8d8a-4b77-8089-dbc84ea5e340 (1 owner(s), created 10/28/2026 01:12:20). Steps 1 and 2 wait until this is settled.
```

## Why
To guard against a non-administrator registering a look-alike application named `[Storage Account] <account>.file.core.windows.net` so `-Fix` would grant it admin consent and exclude it from Conditional Access MFA (red team LZ-2), `Get-AvdStorageKerberosApp` rejected any application that had owners.

When `Microsoft.Storage` registers the `[Storage Account] <account>.file.core.windows.net` application during an ARM deployment initiated by a signed-in user (rather than a service principal), Entra ID records the deploying user as the application's owner. The offline mock (`AzMock.psm1`) returned an empty owner list for `app-obj`, so the offline scenario only tested the unowned case.

## Fix
`Get-AvdStorageKerberosApp` now checks application owners the same way `Resolve-AvdGroup` checks group owners: an application with no owners, or whose owners are all directory administrators (`Get-AvdDirectoryAdminId`) or the signed-in operator (`v1.0/me`), is accepted as a candidate, while any application with a non-administrator owner is rejected.

## Guard
- `build/tests/offline/AzMock.psm1` now gives `app-obj` an administrator owner (`admin-1`) by default, matching an interactive deployment, and `build/tests/offline/PostDeployment.Scenario.ps1` (`storage-app-imposter`) tests the administrator-owned, unowned (`storageAppUnowned`), imposter-beside, and imposter-only cases.
- `build/tests/AvdLandingZone.Tests.ps1` (`Get-AvdStorageKerberosApp`) unit-tests unowned, administrator-owned, operator-owned, imposter-beside, and imposter-only applications.

## Rule
When Azure creates an Entra application on behalf of a signed-in user during an ARM deployment, Entra sets that user as the application's owner. Distinguish a user-registered imposter by whether any owner is outside the directory administrators and the signed-in operator, not by whether the owner list is empty.
