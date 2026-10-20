# Deploy with ManageEngine Endpoint Central

Deploy only `Invoke-EndpointMaintenance.ps1`.

## Configure

1. Upload the PS1 into the Script Repository.
2. Create a Windows Custom Script **Computer Configuration**.
3. Run as **System user**, using native **64-bit Windows PowerShell 5.1**.
4. Enable logging for troubleshooting. The summary is printed to execution
   output; full reports remain under ProgramData\PSWinVitals.
5. Accept exit **0** as success. Disable immediate automatic retries for cleanup;
   let a later scheduled execution handle ordinary deferral.
6. Allow enough execution time for all profile enumeration/removal and servicing.
   The script does not kill native/provider work to meet a timer.
7. Target a test computer and review Audit/WhatIf output first.

Host launch options vary by product version. A 32-bit process or PowerShell 7
exits 2. For command-line configurations, use the correct native host with
`-NoProfile -NonInteractive -File` and the copied script filename:

```text
%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -File "Invoke-EndpointMaintenance.ps1"
```

For a **32-bit launching agent** on x64 Windows, use the Sysnative alias to
reach 64-bit PowerShell instead:

```text
%windir%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -File "Invoke-EndpointMaintenance.ps1"
```

Sysnative is visible to a 32-bit caller; use System32 from a 64-bit caller.
No launcher script or module installation is required. Follow existing script
trust/signing policy; this release candidate is unsigned. Do not change machine
execution policy merely to deploy it.

## Reuse the same PS1 in separate configurations

| Configuration | Arguments |
| --- | --- |
| Audit | None; optionally `-SkipProfileSizes` if sizes are not needed. |
| Standard cleanup | `-Clean` |
| Profile preview | `-Clean -RemoveStaleProfiles -ProfileAgeDays 180 -WhatIf` |
| Profile cleanup | `-Clean -RemoveStaleProfiles -ProfileAgeDays 180` |
| Temp plus profiles | `-Clean -TempFiles -RemoveStaleProfiles -ProfileAgeDays 180` |
| Full preview | `-Clean -All -WhatIf` |
| Full maintenance | `-Clean -All` |

Append protected domain/shared account names or SIDs in one argument:

```text
-ExcludeProfiles "kiosk,sharedaccount,serviceaccount"
```

Use exact directory names or SIDs from the audit report. Local/system accounts
are already retained. There is no profile-count cap: all eligible profiles are
processed in one pass. No eligible candidates is a successful no-op.

Profile removal, Windows repair, and component cleanup defer while a user is
signed in, including disconnected sessions. Choose a suitable startup or
scheduled deployment time. No logoff is forced. Standard temp cleanup can run
with users present, skipping their loaded profiles. Do not run full maintenance
on every refresh cycle.

Standalone Custom Script does not offer all Software Deployment policy/reboot
controls. Use scheduling supported by the installed product; the PS1 has no
hardcoded clinic hours or separate scheduler.

## Interpret results

Endpoint Central normally marks nonzero exit codes Failed. This script uses 10
for Deferred and 1618 for Busy. You can explicitly accept those codes, but the
console may then say Success when maintenance did not occur. Local reports
retain the correct state. Keep update/reboot deployment in the existing patch
process; this script neither installs updates nor requests an agent reboot.

For failed deletion, inspect the SID/path and verification in `profiles.csv`
and `events.jsonl`. Do not blindly remove directories and ProfileList keys.
For interrupted work, reconcile the run referenced by `active.json`, then
remove that marker only once servicing/deletion has finished and been reviewed.

Collect reports through an approved management workflow if central retention
is needed. There is no embedded uploader or share credential. Reports contain
usernames, machine/software details, and profile paths; never publish actual
endpoint output in this source repository.

## Pilot checks

- Compare the full profile inventory with Windows; confirm shared/service/kiosk exclusions.
- Confirm recent, loaded, local, protected, and unknown-age profiles remain retained.
- Review every proposed deletion and confirm local data retention first.
- Test a Windows-created profile with default junctions in a disposable VM.
- Confirm OneDrive, EFS, folder redirection, and container profiles stay excluded.
- Execute through Endpoint Central as SYSTEM and inspect its output and local files.
- Test a repeated/no-op run, a deferred run, and overlap prevention.
- Verify the configured agent timeout permits long cleanup/servicing to finish.

Reference: [ManageEngine Windows Computer Custom Script configuration](https://www.manageengine.com/products/desktop-central/help/configuration-management/executing_custom_scripts-computer.html).
