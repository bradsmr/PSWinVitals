# PSWinVitals workstation maintenance

One PowerShell script for audits and selected unattended workstation maintenance.
Derived from [ralish/PSWinVitals](https://github.com/ralish/PSWinVitals).

**Version: 1.0.0-rc1.** Deploy only
[Invoke-EndpointMaintenance.ps1](Invoke-EndpointMaintenance.ps1). The original
module remains under [legacy](legacy/README.md) for reference, with its original
defaults. It is not the new deployment entry point.

Requirements: Windows 10/11 x64, native **64-bit Windows PowerShell 5.1**, and
SYSTEM or an elevated administrator. No module, package, or configuration file
needs to be installed on endpoints.

## Audit

```powershell
.\Invoke-EndpointMaintenance.ps1

# Different profile-retention threshold in the report.
.\Invoke-EndpointMaintenance.ps1 -ProfileAgeDays 365

# Faster audit without profile file-tree size/safety inspection.
.\Invoke-EndpointMaintenance.ps1 -SkipProfileSizes

# Optional DISM ScanHealth, SFC verifyonly, and bare CHKDSK.
.\Invoke-EndpointMaintenance.ps1 -CheckIntegrity
```

Audit collects OS/hardware information, sampled CPU/RAM usage, disk space and
provider-reported disk health, device errors, recent error-event summaries,
security status, domain/network status, installed-program registry entries,
existing update history, crash-dump metadata, and **every registered profile**.
Unregistered profile directories are reported, not automatically removed.

Profile reports include activity evidence, logical size estimates, exclusions,
and removal candidates. The default threshold is **180 days**, approximately
six months. Audit requests no cleanup, repair, or configuration change. It
writes its own reports; Windows tools may write their normal diagnostic logs.
Profile enumeration and integrity checks can cause substantial I/O. CPU/RAM
values are a sample, not performance history or a diagnosis.

## Clean

`-Clean` alone cleans temporary files. Operation flags replace that default:
only the selected operations run. `-All` selects all four operations below.

| Switch | Operation |
| --- | --- |
| `-TempFiles` | Delete old files from Windows Temp and safe unloaded profiles' Local Temp. |
| `-RemoveStaleProfiles` | Remove every eligible complete profile older than the retention threshold. |
| `-ComponentStore` | DISM StartComponentCleanup without ResetBase. |
| `-RepairWindows` | DISM RestoreHealth with LimitAccess, then SFC scannow. |
| `-All` | Select all four maintenance operations. Requires `-Clean`. |

```powershell
# Standard cleanup: temporary files older than 7 days.
.\Invoke-EndpointMaintenance.ps1 -Clean

# Preview complete profile removal; selects profiles only.
.\Invoke-EndpointMaintenance.ps1 -Clean -RemoveStaleProfiles -WhatIf

# Remove ALL eligible profiles older than 180 days.
.\Invoke-EndpointMaintenance.ps1 -Clean -RemoveStaleProfiles -ProfileAgeDays 180

# Select two operations and retain named shared/service profiles.
.\Invoke-EndpointMaintenance.ps1 -Clean -TempFiles -RemoveStaleProfiles `
    -ExcludeProfiles 'kiosk,sharedaccount,serviceaccount'

# Preview every maintenance operation, then run it.
.\Invoke-EndpointMaintenance.ps1 -Clean -All -WhatIf
.\Invoke-EndpointMaintenance.ps1 -Clean -All

# Optional compatible repair-source directory staged locally beforehand.
.\Invoke-EndpointMaintenance.ps1 -Clean -RepairWindows `
    -RepairSource 'C:\RepairSource\Windows'
```

`-CheckIntegrity` is a separate diagnostic option. `-WhatIf` keeps cleanup
targets unchanged while writing the plan/reports. It does not bypass safety
prerequisites; a preview can still report Deferred. There is no profile-count
or work-budget cap. Allow the agent enough time to finish.

No operation installs Windows updates, initiates update scans, downloads
software, clears browser stores, purges the Recycle Bin/WER, stops applications,
repairs domain trust, schedules boot repair, or restarts Windows. Explicit
whole-profile removal does delete browser data and other local files inside
that selected profile.

## Profile safeguards

Age uses profile-service registry load/unload FILETIME evidence, with newer
valid CIM activity making the decision more conservative. It measures profile
activity, not proof of the exact last interactive sign-in. Missing, invalid,
or future evidence never makes a profile automatically stale.

The script retains:

- Loaded/referenced profiles, executing/system/built-in identities, and local accounts.
- Exact directory names or SIDs supplied through `-ExcludeProfiles`.
- Roaming, mandatory, temporary, corrupt, and known folder-redirection profiles.
- Profiles outside the registered local root, mismatched/duplicate registrations,
  mounted hives, and missing/unreadable directories.
- Profiles with incomplete safety inspection, EFS-encrypted files, cloud/offline
  placeholders, OneDrive directories, container evidence, or nonstandard links.
  Known legacy profile junctions are skipped only when their targets remain
  within that same profile; links are never traversed.

Add shared, domain service, kiosk, and emergency-access accounts to exclusions;
they cannot all be discovered automatically. A comma-separated exclusion
argument works through `powershell.exe -File` and Endpoint Central. Interactive
PowerShell arrays also work. Matching is exact and case-insensitive.

Removal defers while any interactive session is connected or disconnected.
Before each deletion, the script refreshes age, loaded state, registration,
path, exclusions, and session state. Windows' profile provider performs the
deletion through Remove-CimInstance. The provider instance, exact registry
key, and directory must all disappear. Leftovers are a failure requiring
review; there is no fallback recursive purge. `-SkipProfileSizes` does not
disable safety inspection for a removal candidate.

**Complete removal permanently deletes that profile's local Desktop, Downloads,
AppData, certificates, caches, browser data, and settings.** Age does not prove
that files are backed up, and there is no built-in undo. The domain account and
separate server home folders are not deletion targets.

## Temp cleanup and servicing

Both creation and last-write times must precede `-TempAgeDays` (default 7).
The temp root and empty directories remain. Recent/locked files are skipped;
links are not followed and old parent folders are not recursively purged.
Running users' loaded profile Temp folders are skipped. Access/enumeration
failures are reported rather than marked successful.

Repair/component cleanup defer for interactive sessions, low battery, pending
servicing reboot, or existing servicing work. The script never kills another
task or reboots. Native stdout/stderr go to separate files. SFC capture does
not change the host's console encoding.

DISM always uses `/LimitAccess` for repair, preventing Windows Update fallback.
Without `-RepairSource`, Windows uses available local or policy-configured
sources; missing compatible files can cause failure. The optional source must
be an existing local directory. Component cleanup uses `/NoRestart` and never
`/ResetBase`.

## Reports and exit codes

Runs are saved under
`C:\ProgramData\PSWinVitals\Runs\<UTC-time>-<run-id>\`.

| File | Contents |
| --- | --- |
| `summary.txt` | Task states/findings, profile totals/largest profiles, disk-space change, and report path. Also printed to the console. |
| `result.json` | Versioned structured results and effective selections. |
| `profiles.csv` | All profiles, activity evidence, eligibility, reasons, and removal outcomes. |
| `events.jsonl` | Flushed task/action start/end records and errors. |
| `*.log` | Native output and servicing logs, when selected. |

The report root permits SYSTEM/Administrators writes only. Unsafe existing
ownership/ACLs or linked paths are rejected. One exclusive file lock prevents
overlapping runs. Completed older logs expire after 30 days or approximately
200 MiB retained; current/unfinished evidence is retained. Reports remain local.

Execution state is separate from health findings. An audit can complete and
find corruption. Unsupported/inconclusive checks stay Unknown. Exit 0 does not
mean the workstation is healthy. Logical sizes are estimates; observed disk
free-space changes include concurrent activity.

| Exit | Meaning |
| --- | --- |
| 0 | Selected work completed, including valid no-op/preview runs; findings can still require attention. |
| 1 | An operation/report failed, or a PowerShell invocation error occurred. |
| 2 | A host, selection, path, or logging precheck failed. |
| 10 | Requested maintenance was deferred. |
| 1618 | Another run holds the lock. |

An interrupted cleanup leaves `C:\ProgramData\PSWinVitals\active.json` pointing
to its run directory. Later cleanup defers. Review those logs and any partial
profile deletion, confirm servicing has finished, then remove **that marker
file only** before rerunning. Audit remains available. Ambiguous destructive
work is not automatically retried.

## Deploy and validate

See [Endpoint Central deployment](docs/endpoint-central-deployment.md) and
[validation status](docs/validation.md). Start with Audit and WhatIf on a test
workstation before enabling destructive operations.

```powershell
.\tests\Invoke-Tests.ps1
```

The dependency-free workflow runs Windows PowerShell 5.1 and portable checks;
it does not install modules. A Windows 10/11 SYSTEM pilot is still required.

## License and history

MIT. The original notice is in [LICENSE](LICENSE) and embedded in the standalone
file. Upstream history and the original module are preserved. The superseded
DeepClean/five-profile proposal remains in Git history, not the supported CLI.
