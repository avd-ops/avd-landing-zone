# Host security baseline profile

`host-baseline.json` is the reviewed list of security controls the landing zone checks inside its
session hosts ([decision 0018](../../build/decisions/0018-host-security-baseline.md)). It fills
avd-assess's gap `host-baseline-profile`: Microsoft publishes no security baseline for Windows
multi-session hosts, so the reference is Microsoft's baseline for the host's Windows release, and
this profile records the controls checked here and the landing zone's departures from it.

`scripts/ops/host/Get-SessionHostSecurity.ps1` reads the values (read-only, Run Command),
`Get-AvdHostBaselineResult` in `scripts/ops/AvdLandingZone.psm1` compares them, and
`Deploy-AvdDemo.ps1` reports each control as a pass or a warning.

| Control | Expected | Set by | Departure |
|---|---|---|---|
| `vbs-running` | VBS running (2) | Windows on Trusted Launch | |
| `credential-guard` | Credential Guard running | Windows | |
| `hvci` | Memory integrity running | Windows | |
| `app-control` | App Control policy enforced | Organization | No app policy ships with the landing zone |
| `defender-realtime` | Real-time protection on | Windows | |
| `defender-tamper` | Tamper protection on | Organization | Managed from Defender for Endpoint, onboarded by Defender for Servers |
| `lsa-protection` | `RunAsPPL` 1 or 2 | Windows | |
| `smb1-off` | SMB 1.0 server off | Windows | |
| `idle-limit` | An idle session limit | Organization | Depends on how people work; the landing zone limits disconnected sessions |
| `screen-lock` | Lock after 15 minutes or less | Organization | Usually the organization's device policy |
| `screen-capture-protection` | On | Organization | Blocks screen sharing in some meeting apps |
| `local-admins` | No extra local administrators | Image | |

**Outcomes:** pass; departure (the profile records why); gap (drift nobody recorded); unknown (the
host didn't report the value). Only a pass is green, and none of them fails the demo.

## Changing the profile

1. Edit the control, and the table above. A control set by the organization needs a `departure`;
   `build/tests/AvdLandingZone.Tests.ps1` checks it, and that every control's value is one the host
   script reports.
2. Cite the avd-assess claim it rests on in `refs` (`<reference>#<claim>`).
3. When a real run shows a control expecting the wrong value, fix it and write a lesson.
