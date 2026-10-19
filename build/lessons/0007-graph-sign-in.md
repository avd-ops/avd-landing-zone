# 0007. Microsoft Graph sign-in in Cloud Shell

- **Area:** Ops scripts
- **Found in / fixed by:** PR #6 #10 #11

## What happened
The device code was invisible (hung waiting); later a sign-in that succeeded could not produce tokens (`DeviceCodeCredential authentication failed: Object reference not set`); the account check always warned.

## Why
`Connect-MgGraph` writes the device-code prompt to the output stream, so `| Out-Null` hid it. A Graph context can exist but be unable to issue tokens. The device code is completed in whatever account the browser uses. In Cloud Shell the Az context account reads `MSI@<port>`.

## Fix
Show the prompt with `Write-Host`; `Test-AvdGraphToken` checks a sign-in before reuse and reconnects once; `Test-AvdSignInMatch` compares the Graph account with `Get-AzADUser -SignedIn`.

## Guard
Pester `Test-AvdGraphToken`; offline scenarios sign in through the mock.

## Rule
Never pipe `Connect-MgGraph` to `Out-Null`. Verify a sign-in with a real request before trusting it. Identify the Azure user with `Get-AzADUser -SignedIn`, not the context account.
