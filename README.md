# PSWinVitals

`Invoke-EndpointMaintenance.ps1` audits Windows workstations and performs selected cleanup and repair operations. Deploy this PS1 only.

- Audit: hardware, CPU/RAM, disks, device errors, recent error events, security/network status, installed programs, existing update history, crash-dump metadata, and all registered profiles with age, size, and removal eligibility.
- Clean: temporary files, stale profiles, Windows component-store cleanup, and Windows repair.
- No Windows Update scans/installations, software downloads, forced logoff, or automatic restart.

## Requirements

- Windows 10/11 x64.
- Native 64-bit Windows PowerShell 5.1. PowerShell 7, 32-bit PowerShell, Windows Server, and ARM64 are unsupported.
- SYSTEM or an elevated administrator.
- No additional modules or configuration files. The script is unsigned; follow the existing script-signing/execution policy.

## Switches and examples

No switches runs an audit. `-Clean` alone selects temp cleanup. Explicit operation switches replace that default and require `-Clean`. `-All` selects all four maintenance operations; `-CheckIntegrity` is separate.

```powershell
# Audit
.\Invoke-EndpointMaintenance.ps1

# Standard cleanup
.\Invoke-EndpointMaintenance.ps1 -Clean

# Preview stale-profile removal
.\Invoke-EndpointMaintenance.ps1 -Clean -RemoveStaleProfiles -WhatIf
```

Examples below are arguments to append to `.\Invoke-EndpointMaintenance.ps1`.

| Switch | Behavior / default | Example arguments |
| --- | --- | --- |
| `-Clean` | Enable maintenance; temp cleanup if no operations are selected. | `-Clean` |
| `-TempFiles` | Delete old files from Windows Temp and eligible unloaded profiles' Local Temp. | `-Clean -TempFiles` |
| `-RemoveStaleProfiles` | Permanently remove every eligible complete profile older than `ProfileAgeDays`, including its local files and settings. No profile-count limit. | `-Clean -RemoveStaleProfiles -ProfileAgeDays 180` |
| `-ComponentStore` | DISM StartComponentCleanup; no ResetBase or restart. | `-Clean -ComponentStore` |
| `-RepairWindows` | DISM RestoreHealth with LimitAccess, then SFC scannow; no Windows Update fallback. | `-Clean -RepairWindows` |
| `-All` | Select TempFiles, RemoveStaleProfiles, RepairWindows, and ComponentStore. | `-Clean -All` |
| `-CheckIntegrity` | Run DISM ScanHealth, SFC verifyonly, and read-only CHKDSK on the Windows volume. | `-CheckIntegrity` |
| `-ProfileAgeDays <days>` | Profile inactivity threshold. Default `180`; range `1-3650`. Also applies to audit eligibility. | `-ProfileAgeDays 365` |
| `-TempAgeDays <days>` | Minimum age of both creation and last-write timestamps. Default `7`; range `1-3650`. | `-Clean -TempAgeDays 14` |
| `-ExcludeProfiles <names/SIDs>` | Retain additional exact profile directory names or SIDs. Case-insensitive; accepts one comma-separated argument. | `-Clean -RemoveStaleProfiles -ExcludeProfiles "kiosk,sharedaccount"` |
| `-RepairSource <path>` | Existing compatible local repair-source directory; requires RepairWindows. Without it, use available local/policy sources. | `-Clean -RepairWindows -RepairSource "C:\RepairSource\Windows"` |
| `-SkipProfileSizes` | Skip profile tree inspection for inventory; removal candidates are still fully inspected. | `-SkipProfileSizes` |
| `-WhatIf` | Preview maintenance and write reports without changing cleanup targets. Safety checks still apply. | `-Clean -All -WhatIf` |
| `-Confirm` | Prompt before maintenance actions. Omit for unattended runs. | `-Clean -TempFiles -Confirm` |

Combine operation switches to select only those operations:

```powershell
.\Invoke-EndpointMaintenance.ps1 -Clean -TempFiles -RemoveStaleProfiles -ProfileAgeDays 180 -ExcludeProfiles "kiosk,sharedaccount"
```

Profile age uses registry profile load/unload evidence and newer valid CIM activity, not an exact interactive sign-in record. Missing, invalid, or future activity evidence prevents removal. Local/system, loaded/referenced, excluded, roaming/redirected, encrypted/cloud/container, unsafe-path, and incompletely inspected profiles are retained. Removal uses the Windows profile provider and verifies that registration and directory are gone.

Profile removal and servicing defer while any interactive session is connected or disconnected. Servicing also defers for low battery, a pending servicing reboot, or existing servicing work. Temp cleanup skips recent/locked files, links, and loaded profiles' Temp folders.

## Reports

Location: `%ProgramData%\PSWinVitals\Runs\<UTC-time>-<run-id>\`.

| File | Contents |
| --- | --- |
| `summary.txt` | Task results, findings, profile totals, disk-space change, and report path. Also printed to the console. |
| `result.json` | Structured results and effective options. |
| `profiles.csv` | All profiles, activity evidence, size estimates, eligibility/exclusions, and removal outcomes. |
| `events.jsonl` | Flushed task/action records and errors. |
| `*.log` | Native stdout/stderr and servicing logs when selected. |

Reports stay local. SYSTEM/Administrators can write to the report root; unsafe ownership, permissions, or linked paths are rejected. One exclusive lock prevents overlapping runs. Completed older logs expire after 30 days or approximately 200 MiB retained; current/unfinished evidence is kept.

Interrupted cleanup leaves `%ProgramData%\PSWinVitals\active.json` and blocks later cleanup. Review the referenced run and any partial profile deletion, confirm servicing has finished, then remove that marker file only before rerunning. Audit remains available.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Selected work completed, including a valid no-op or preview. Health findings can still require attention. |
| `1` | Operation/report failure or PowerShell invocation error. |
| `2` | Host, selection, path, or logging precheck failed. |
| `10` | Maintenance deferred. |
| `1618` | Another run holds the lock. |

Exit codes describe execution, not workstation health. Review findings in the reports.

## Endpoint Central deployment

1. Upload `Invoke-EndpointMaintenance.ps1` to the Script Repository.
2. Create a Windows Custom Script **Computer Configuration**. Run as **System user** using native **64-bit Windows PowerShell 5.1**.
3. Set arguments from the examples above. Leave arguments empty for Audit. Add shared/service/kiosk names or SIDs to `-ExcludeProfiles` when removing profiles.
4. Enable execution logging. Accept exit `0` as success. Codes `10` and `1618` mean work did not run; accepting them as success hides that distinction in the console.
5. Allow enough execution time for all profiles and servicing. Disable immediate automatic cleanup retries. Schedule profile removal/servicing when no users are signed in, including disconnected sessions.
6. Pilot Audit, WhatIf, and cleanup on a Windows 10/11 test workstation through Endpoint Central as SYSTEM before broad deployment. Confirm profile exclusions and local data retention first.

For a command-line configuration launched by a 64-bit process:

```text
%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -File "Invoke-EndpointMaintenance.ps1" -Clean
```

From a 32-bit launching process on x64 Windows, replace `System32` with `Sysnative`. Use the copied script's path and the desired arguments. Do not pass `-Confirm` for unattended runs.

The console receives the summary; full reports remain under ProgramData. Collect them separately if central retention is needed. Keep Windows updates and reboots in the existing patch process.

MIT license: [LICENSE](LICENSE). Based on [ralish/PSWinVitals](https://github.com/ralish/PSWinVitals).
