# PSWinVitals: Endpoint Central change proposal

Date: 2026-10-20

Status: proposed implementation. The example commands below describe the new
interface; `Invoke-EndpointMaintenance.ps1` has not been implemented in this
proposal branch. Existing upstream commands still have their original behavior.

## 1. Resulting product

Create one deployable file, `Invoke-EndpointMaintenance.ps1`, derived from
PSWinVitals. It will run locally under Endpoint Central's SYSTEM account and
use only Windows components. It will not need a module installation, package
download, credentials, or an interactive desktop.

Use three modes, with separately selected profile deletion and Windows repair:

| Operation | Audit, the default | Clean | DeepClean |
| --- | --- | --- | --- |
| Collect workstation health and storage information | Yes | Before and after relevant changes | Before and after relevant changes |
| Inventory profiles, age evidence, size estimates, and cleanup candidates | Yes | Yes | Yes |
| Delete eligible files from Windows Temp | No | Yes, older than 7 days by default | Same age rule |
| Delete eligible files from unloaded profiles' Local Temp | No | Yes, older than 7 days by default | Same age rule |
| DISM component store cleanup | No | No | Yes, when servicing prerequisites pass |
| Delete complete stale profiles | No | No | Only with `-RemoveStaleProfiles` |
| Run detailed Windows integrity verification | Only with `-CheckIntegrity` | Only with `-CheckIntegrity` | Only with `-CheckIntegrity` |
| Repair Windows with DISM, then SFC | No | Only with `-RepairWindows` | Only with `-RepairWindows` |

Audit writes its own reports and logs, and Windows diagnostics may write their
normal diagnostic logs. It does not request repairs, cleanup, or configuration
changes. DeepClean does not lower the temporary-file age threshold or delete
additional types of personal data.

## 2. Public parameters and defaults

| Parameter | Contract |
| --- | --- |
| `-Mode` | `Audit`, `Clean`, or `DeepClean`. Default `Audit`. |
| `-ProfileAgeDays` | Integer 1-3650. Default 90 for reporting. Must be explicitly supplied when removing profiles. Eligibility is strictly older than the UTC cutoff. |
| `-TempAgeDays` | Integer 1-3650. Default 7. No zero-day purge. |
| `-RemoveStaleProfiles` | Valid only in DeepClean. Enables deletion of profiles that pass every eligibility check. |
| `-ProtectedProfileSids` | Additional exact SIDs to retain, including shared, kiosk, service, and emergency-access accounts. |
| `-ProtectedProfileNames` | Additional exact profile directory names to retain. SID exclusions take precedence over names. No wildcard matching. |
| `-MaxProfilesPerRun` | Default 5; range 1-100. Delete the oldest eligible profiles first. Report candidates left for a later run. |
| `-CheckIntegrity` | Adds DISM ScanHealth, SFC verify-only, and a read-only CHKDSK run for selected volumes. |
| `-Volume` | Local fixed drive letters for CHKDSK, default the Windows volume. Inventory still covers all local fixed volumes. |
| `-RepairWindows` | Valid in Clean or DeepClean; requires `-RepairSource`. DISM RestoreHealth runs before SFC scannow. No filesystem repair. |
| `-RepairSource` | Explicit locally staged, compatible Windows repair source. No automatic network or Windows Update fallback. |
| `-MaxRunMinutes` | Soft work budget: default 15 for Audit/Clean, 120 for DeepClean or repair. Do not start another task when the budget is exhausted. |
| `-OutputRoot` | Default `%ProgramData%\SJCH\EndpointMaintenance`. Must be a protected local directory outside every cleanup target. |
| `-WhatIf` | Build the same plan, write reports, and log intended actions without changing cleanup targets. |

Reject contradictory flags before any cleanup. Use
`[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]`.
Every mutation of a cleanup target or Windows servicing state must pass through
`ShouldProcess`; the explicit mode and switches provide unattended intent.
Endpoint Central uses `-NonInteractive` and must never receive a prompt.
Reports and normal log retention are management artifacts and remain writable
under WhatIf; document that exception explicitly.

Keep one clearly labeled policy hashtable near the top of the file for values
that belong to the organization rather than each invocation:

- Approved profile domain SID prefixes. Default empty; automatic profile
  removal stays unavailable until SJCH's real domain SID is configured.
- Permanent protected SIDs and exact profile directory names. Default empty
  for organization-specific entries; built-in system protections remain active.
- Expected security/management service names, once confirmed on a test PC.
- Disk warnings: less than 15% free OR less than 20 GiB free; critical below
  5 GiB. These are proposed operational thresholds, not Microsoft standards.
- Event lookback: 7 days, maximum 50 recent records per selected log.
- Profile size sampling: 30 seconds per profile; separate safety inspection
  budget of 300 seconds per proposed deletion, both limited by the run budget.
- Log retention: 30 days and 200 MiB, deleting oldest completed runs first.

Determine the domain SID once from an authorized admin workstation, for example
with `Get-ADDomain -Identity sjch.org | Select-Object DomainSID`. Copy the actual
returned SID into the policy before signing a deployment release. The endpoint
script itself will not require the ActiveDirectory module or contact AD to
authorize deletion. Never put actual workstation reports or an organization's
configured policy values in a public upstream pull request.

## 3. Profile inventory and removal

### Age evidence

Enumerate registered profiles with `Get-CimInstance Win32_UserProfile`.
Read each corresponding ProfileList registry key through the native registry
view. Record the raw CIM LastUseTime plus valid LocalProfileLoadTime and
LocalProfileUnLoadTime high/low DWORD pairs.

Use Windows' registry-based profile age evidence as the primary input [1].
Combine high/low parts as unsigned FILETIME and convert with FromFileTimeUtc.
Reject missing pairs, zero, invalid, and future timestamps. Use the latest
valid load/unload time; a more recent valid CIM LastUseTime makes the decision
more conservative. If registry evidence is missing, mark age unknown and
report the profile without deleting it. Do not turn missing dates into an
arbitrarily large age.

Name the derived field `LastProfileActivityUtc`, not `LastSignIn`: profile use
and unload timestamps are evidence of profile activity, not proof of the exact
last interactive sign-in. Do not base deletion on folder creation/write times,
NTUSER.DAT timestamps, domain lastLogonTimestamp, or missing account-name
resolution. Use UTC comparisons rather than rounded display-day values.

### Report fields

| Field | Meaning |
| --- | --- |
| SID, AccountName, LocalPath | Stable identity, best-effort display name, and canonical local path. Name resolution failure is explicit. |
| Loaded, Special, Status, RoamingConfigured | Provider state and profile type [2]. |
| CimLastUseUtc, RegistryLoadUtc, RegistryUnloadUtc | Collected evidence, with validity/rejection reasons. |
| LastProfileActivityUtc, AgeSource, AgeDays | Conservative comparison date and displayed age. |
| LogicalSizeBytes, SizeComplete, EnumerationErrors | Local size estimate and whether enumeration finished. |
| EligibleForRemoval, SkipReasons | The exact same factual eligibility decision used by the deletion path, independent of whether deletion was enabled. |
| PlannedAction, ActualAction, Verification | Proposed or completed action, with post-deletion checks. |

Sort profiles by size in the human report; sort removal candidates by age for
execution. Show eligible profile count, ineligible/unknown count, estimated
eligible bytes, and candidate count left by the per-run limit. Also list
unregistered directories under the approved profiles root as report-only
orphans; never silently delete them.

Size traversal is streamed and bounded to 30 seconds per profile and the run's
overall budget. A separate, bounded safety inspection runs before an actual
profile removal; a partial size estimate is not a complete safety inspection.
Do not follow directory junctions, symbolic links, mounted
volumes, redirected locations, or cloud placeholders; do not open file content
or hydrate files. Count accessible local metadata and mark incomplete sizes
as partial estimates. Logical file sizes are not exact reclaimable disk space:
compression, sparse files, placeholders, hard links, and concurrent work affect
the result. Report actual volume free-space change separately without claiming
the script caused every byte of the change.

### Eligibility for unattended deletion

A profile is a removal candidate only when all of the following facts are true.
This evaluator does not inspect Mode or RemoveStaleProfiles: Audit must report
the same candidates that an equivalent removal pass would consider.

1. The approved domain SID policy is configured. With no policy, report
   potentially stale profiles as requiring policy setup, not as authorized
   deletion candidates.
2. It is a normal account profile whose SID matches an approved domain SID
   prefix followed by a valid account RID. Local accounts and accounts from
   other domains remain report-only in the first release.
3. It is not Special, Loaded, the executing identity, a protected SID/name,
   a built-in/service profile, or a profile with temporary, mandatory, or
   corrupted status. Protect Default, Public, defaultuser0, WDAGUtilityAccount,
   systemprofile, LocalService, NetworkService, and Administrator independently
   of account-name resolution. Do not assume this list discovers every kiosk
   or application identity; configure those exact SIDs before deployment.
4. There are no connected or disconnected interactive user sessions when
   destructive profile cleanup begins. Query Windows Terminal Services APIs;
   do not parse localized quser text. A session-query error defers deletion.
5. The canonical registered path agrees with ProfileList and is an immediate
   child of the approved local ProfilesDirectory. Neither the root nor profile
   root is a reparse point. Reject a share, volume root, ambiguous path,
   duplicate SID/path registration, or inconsistent registry registration.
6. Valid registry age evidence is older than the specified cutoff; no valid
   activity source reports more recent use.
7. Roaming/mandatory profiles, mounted profile containers, and redirected or
   cloud-managed profile configurations remain report-only in the first
   release. Known evidence of EFS-encrypted files also blocks automatic
   deletion. Incomplete prerequisite checks block removal rather than implying
   that no risk exists. Incomplete size alone does not prove age is unknown,
   but an incomplete safety traversal blocks deletion.

The caller separately authorizes execution only for DeepClean with
RemoveStaleProfiles and an explicitly supplied ProfileAgeDays. Audit uses its
selected age threshold, including the default 90, for informational candidates.
Without deletion authorization, PlannedAction is Retain or Preview; it is not
mistaken for an executed removal.

Account-name lookup is display-only. An unresolved SID can still qualify when
its approved domain prefix and every other prerequisite are verified; a
deleted account or unavailable DC alone is never evidence of staleness.

Immediately before each deletion, requery the CIM instance, registry age and
path, loaded state, SID exclusions, mounted hive, and interactive sessions.
Reapply the same eligibility function. Never reuse the audit's cached decision
without these checks. This reduces races but does not make sign-in and profile
deletion atomic; provider rejection is a skip/failure, never a reason to force
unload or terminate a session.

Delete through `Remove-CimInstance -InputObject $Profile -ErrorAction Stop`,
using Windows' profile provider, instead of deleting the directory and
ProfileList key manually. Log the SID and path before calling it. Verify that
the CIM instance, exact ProfileList key, and registered profile directory are
gone. Any leftovers or provider errors produce a partial/failed action with
the evidence retained; no fallback recursive purge.

This intentionally deletes a whole local profile, including local Desktop,
Downloads, AppData, browser data, mail caches, certificates, and settings.
Age does not prove that data is backed up or synchronized. There is no built-in
undo, and a restore point is not a backup of those files. The script does not
delete the domain account or separately target server home folders, redirected
shares, or cloud data. Profiles using those special configurations are excluded
from automatic removal until their behavior has been validated separately.
The explicit deletion switch expresses that local data removal is intended.

## 4. Changes to every upstream task

This mapping is against upstream commit
`ff133b76a1b8b444c46f5bdb3e9118d9b0ad83b5` [6].

| Existing task or helper | Exact disposition in the deployed script |
| --- | --- |
| Get-VitalInformation | Replace the public entry point with Audit and a stable result schema. Retain selected collectors as named internal functions. |
| ComputerInfo | Collect selected identity, model, serial, OS/build, boot time, CPU, memory, and membership properties. Avoid exporting every available property. |
| HypervisorInfo / Get-HypervisorInfo | Keep manufacturer/model detection; omit invoking VMware Toolbox. Optional metadata, not a health failure. |
| DevicesWithBadStatus | Keep present-device problem reporting. Include PnP error codes; unavailable provider means unknown. |
| DevicesNotPresent | Keep only as optional detail; an absent device is not automatically a fault. |
| StorageVolumes | Keep all fixed-volume inventory; add free-space thresholds and supported physical-disk health/reliability information. |
| CrashDumps / Get-*CrashDumps | Preserve dumps. Report counts, locations, timestamps, and sizes; never copy their contents into reports. Fix path handling described below. |
| ComponentStoreAnalysis | Run only for DeepClean planning or detailed verification, with raw output and an honest unknown estimate when output cannot be interpreted. |
| InstalledFeatures / Get-WindowsProductType | Remove server-feature collection. Use ProductType to reject server/DC execution. |
| InstalledPrograms / Get-InstalledPrograms | Preserve registry-based inventory in native and WOW64 views. Remove exported uninstall command strings and the native last-write-time fallback; an unknown install date stays null. Never use Win32_Product. |
| EnvironmentVariables | Remove raw environment-variable inventory. Record only approved runtime metadata such as identity SID, process bitness, and PowerShell version. |
| WindowsUpdates / WUParameters / PSWindowsUpdate | Remove update searching, installing, module detection/import, and parameter forwarding. No update configuration changes. Read existing local history only, if available. |
| SysinternalsSuite / Update-Sysinternals / Expand-ZipFile | Remove inventory tied to the custom installation scheme, downloading, extraction, installation, and PATH changes. |
| Invoke-VitalChecks | Replace default repair behavior with explicitly selected verification or repair. No automatic repair from a health finding. |
| Invoke-VitalMaintenance | Replace the opt-out task bundle with the fixed Clean/DeepClean allowlists and explicit operation switches. No unrestricted all-tasks path or arbitrary parameter forwarding. |
| Invoke-CHKDSK / FileSystemScans | Rework for selected local volumes. CheckIntegrity uses CHKDSK without repair switches; no /f, /r, /x, /b, /scan, or scheduled boot repair. Remove the hardcoded volume GUID exception. |
| Invoke-DISM / ComponentStoreScan | Use built-in DISM typed health state for verification when supported. Preserve operation output and native codes. RestoreHealth requires RepairWindows, a staged compatible source, LimitAccess, and NoRestart. |
| Invoke-SFC / SystemFileChecker | Preserve verify/repair distinction and output decoding. Rework for a noninteractive child process; do not change the agent host's console encoding. Restore resources in finally. |
| ComponentStoreCleanup | DeepClean only: DISM /Online /Cleanup-Image /StartComponentCleanup /NoRestart, with its own log. Never /ResetBase. Defer for servicing contention or pending servicing reboot. |
| DotNetQueuedItems / Invoke-NGEN | Remove from this workstation-maintenance scope. |
| PowerShellHelp / Update-Help | Remove. No help downloads or module modifications. |
| ClearInternetExplorerCache | Remove. No browser data deletion in any preset. |
| DeleteErrorReports | Remove. Preserve Windows Error Reporting queues/archives and crash evidence. |
| DeleteTemporaryFiles | Replace blanket recursion with the bounded, age-filtered, path-validated cleanup described below. |
| EmptyRecycleBin | Remove. No Recycle Bin purging in any preset. |
| Add-NativeMethods | Drop obsolete archive/registry-date/console methods. Add only small, documented native helpers actually needed, such as WTS session enumeration. |
| Test-IsAdministrator | Keep the intent; explicitly support SYSTEM and elevated local admins. Fail rather than request elevation. |
| Test-IsWindows64bit | Replace string matching with Environment.Is64BitOperatingSystem and Is64BitProcess. Reject an incorrect host architecture. |

Two additional source findings affect reuse. Get-KernelCrashDumps assigns the
Minidump directory fallback to DumpFile, and some missing-registry branches
leave expected variables unset under strict mode. Initialize both default
paths first, expand supported environment variables in configured paths, and
override each independently. Its SFC wrapper changes global console state
without a finally block; the new child-process capture must isolate that state.

The upstream manifest remains at 0.7.0, but main has commits dated 2025-11-17.
Release age alone does not establish abandonment or incompatibility. Also,
StartComponentCleanup is not equivalent to ResetBase: it skips the scheduled
task's normal 30-day grace period, while ResetBase adds stronger restrictions
on uninstalling existing update packages [3]. Neither operation installs updates.

## 5. Temporary-file cleanup rules

Allow only the canonical Windows Temp directory and AppData\Local\Temp under
unloaded ordinary profiles from approved domain SID prefixes that pass the
identity, protected-account, and path checks. A profile need not be stale for
its old temp files to qualify; full-profile removal authorization and age are
separate. An empty domain SID policy disables per-profile temp cleanup but
still allows approved Windows Temp cleanup. Never use SYSTEM's TEMP or
LOCALAPPDATA as a way to infer an employee's profile. Inventory all profiles
through the provider and resolve each approved path explicitly.

Enumerate one directory level at a time without following reparse points.
For each file, require both creation and last-write timestamps to precede the
cutoff, recheck the path and metadata immediately before deletion, and call
Remove-Item with LiteralPath. Never recursively delete an old parent directory
that might contain a new child. Only remove empty directories afterward, and
retain the temp root. Skip links, placeholders, recent files, loaded profiles,
locked files, and paths outside the allowlist. Do not take ownership, reset
ACLs, unload hives, stop applications, or force handles closed.

Deletion age reduces risk; it does not prove a file is unused. Keep counters
for eligible files, removed files/bytes, recent files, locked files, changed
files, and actual access/enumeration failures. A missing optional directory is
a skip. A locked file is an expected skip. A directory that cannot be
enumerated produces an incomplete result, not successful cleanup.

Exclude Downloads, Desktop, Documents, PST/OST files, browser stores, printer
spool data, Defender/SentinelOne stores, application install caches, Windows
Installer, SoftwareDistribution, WinSxS manual deletion, Windows.old,
Delivery Optimization, Offline Files/CSC, pagefile/hiberfil, and clinical
application directories from file cleanup. Whole-profile deletion is the
separate explicit operation described above, with its own broader data scope.

## 6. Health information to add

Use small, independent collectors with bounded queries:

- Uptime and pending-reboot indicators, including CBS, Windows Update,
  pending file renames, and a pending computer-name change. Keep the reasons;
  a pending file rename alone is not conclusive proof of a servicing reboot.
- CPU sampled over 5 seconds and current RAM pressure. Describe these as
  samples, not historical performance measurements.
- Disk free space, supported physical disk health, and reliability counters.
  Missing/unsupported SMART information is unknown, never a passing result.
- Recent System/Application critical/error counts grouped by provider/event
  ID, capped and time-bounded. Default output omits raw event messages and
  process command lines, which can contain patient or credential information.
- Local servicing/update history already recorded on the endpoint, where
  available. This is historical evidence, not patch compliance. Do not initiate
  an update scan or change WSUS/WUfB/Endpoint Central settings.
- Firewall profiles, BitLocker protection state without recovery keys,
  Defender operating mode/status, and configured management/security service
  presence. Defender passive mode is not automatically a fault when another
  product is expected. Service presence alone cannot establish agent health.
- Read-only domain secure-channel test on a joined workstation, configured
  DNS/default-gateway information, and bounded DNS resolution tests against
  the joined domain. No Repair switch, external public connectivity test, or
  assumptions that ICMP must succeed. Offline/VPN conditions can be unknown.
- An allowlist of important service checks. Do not flag every stopped
  automatic/trigger-start service or restart services automatically.

Detailed verification is deliberately opt-in. Read-only CHKDSK on an active
volume can report transient/inconclusive findings; do not turn that into an
automatic repair request [4]. DISM uses ImageHealthState when available [5].
SFC interpretation must preserve raw output and tested, locale-aware results;
an exit code alone must not produce a clean bill of health. Unrecognized
language/output is unknown and requires review.

## 7. Unattended execution and servicing controls

Support Windows PowerShell 5.1 x64 on Windows 10/11 x64 clients initially.
Reject servers, DCs, unsupported architectures, PowerShell 7, and a 32-bit host
with a clear prerequisite result. Do not silently relaunch with fragile
argument reconstruction. No UAC, Read-Host, credential prompt, pause, GUI,
Write-Progress dependency, or interactive confirmation is allowed.

Use a protected machine-wide exclusive FileStream lock with FileShare.None.
Store run ID, PID, and start time as metadata; the open handle, not an old
file's existence, establishes ownership. Release in finally. A second run
reports busy and performs no maintenance. Before servicing, also check for
existing DISM/SFC/Windows servicing activity and unfinished prior task records;
do not kill another deployment's work or treat an old InProgress record as
proof that the operation finished.

Audit runs with users signed in. Clean may perform conservative temp cleanup
while employees are signed in, but their loaded profile temp roots are skipped.
DeepClean and RepairWindows defer their mutations while any connected or
disconnected interactive session exists. Before each expensive operation,
recheck session state, power/battery state when relevant, pending servicing
reboot, servicing contention, and the remaining budget. Respect Endpoint
Central targeting and schedule; do not hardcode clinic operating hours into
the script.

Use separate stdout/stderr files, exit-code capture, and start/end records for
native commands. Avoid Invoke-Expression and arbitrary command-text options.
Safely construct arguments, including paths with spaces. For Windows repair,
require a local compatible repair source; use LimitAccess to prevent a Windows
Update source fallback and NoRestart to suppress servicing reboot behavior.
Do not stop Windows Update, BITS, TrustedInstaller, or clinical applications.

The work budget is a soft limit. Bound inventory/file enumeration and stop
starting new work when it expires. Do not abruptly terminate DISM, SFC,
TrustedInstaller, or an in-progress profile-provider deletion to meet a timer.
Those operations can overrun the budget; the Endpoint Central timeout must
allow for that. If the parent is externally terminated, an already-flushed
InProgress record remains and a subsequent run must reconcile it before
performing more servicing. Never label a timed-out or unverified task as
successful. No automatic reboot, boot-repair scheduling, or AD/GPO changes.

## 8. Logs, results, and Endpoint Central exit codes

Default report location:

`C:\ProgramData\SJCH\EndpointMaintenance\Runs\<UTC-time>-<RunId>\`

Create the directory with SYSTEM/Administrators access, validate existing ACLs
and every path component against reparse-point redirection, and fail closed
before mutations if logging cannot be secured and written. Do not put logs in
a user's temp directory or the agent's disposable script working directory.
Do not copy all data to a share as SYSTEM or embed credentials in the script.

Write:

| File | Purpose |
| --- | --- |
| events.jsonl | Append and flush task start/end, actions, skip reasons, exceptions, and interruption evidence. |
| result.json | Versioned machine-readable result, written through a temp file and atomic rename. |
| summary.txt | Compact technician-readable report, also printed to standard output. |
| profiles.csv | Profile inventory, evidence, eligibility, and outcomes. |
| native-*.log | Per-command raw stdout/stderr and servicing log references. |

The task result schema has separate ExecutionState and Finding fields.
ExecutionState is Succeeded, Failed, Skipped, Deferred, Planned, or InProgress.
Finding is Pass, Warn, Fail, Unknown, or NotApplicable. Include schema/script
version, script SHA-256, run ID, computer, executing identity SID, mode,
sanitized effective parameters, task/target, UTC timestamps, duration,
native exit code, reboot flag, counters, error code/message, and evidence path.
An unhealthy PC is different from a script that failed to collect evidence.

The summary reports execution outcome, findings, omitted/unsupported checks,
disk space before/after, profile candidates/removals/skips, remaining candidates,
pending reboot reasons, and the report directory. Do not claim overall health
from unperformed checks or invent a weighted health score. Print the run ID
and a bounded completion summary to Endpoint Central rather than full JSON or
thousands of file paths. Default file-cleanup logging is aggregated by target
directory, with error types/counts rather than every potentially sensitive
temporary filename. No environment dump or unfiltered transcript by default.

| Process exit code | Meaning |
| --- | --- |
| 0 | Selected work completed. Health warnings/failures can still be present. No eligible files/profiles is a valid completed result. |
| 1 | A selected operation failed, verification was incomplete, or an unhandled runtime error occurred. |
| 2 | Invalid parameters, unsupported host, unsafe policy/path, or logging/preflight failure. |
| 10 | The requested maintenance pass was deferred by a prerequisite such as logged-on users or active servicing. |
| 1618 | Another script instance already holds the machine-wide lock. |

Native DISM 3010, when applicable, becomes RebootRequired in the result, not a
script-initiated restart. Other native exit codes need task-specific mapping.
More severe errors take precedence over deferred status. An intentionally
excluded protected profile is a documented skip; candidates left by the
configured per-run cap are reported, not treated as deletion failures.

Endpoint Central ordinarily treats a nonzero exit as Failed [7]. Initially
configure only 0 as success and disable immediate automatic retries for
destructive configurations. Deferred/busy runs should retry on the next
scheduled execution. Adding 10/1618 as accepted codes is an optional console
choice that would make those runs appear successful there; it does not mean
maintenance happened. Persistent logs retain the accurate distinction.

Prune only this tool's completed run directories, oldest first, using the
30-day/200-MiB policy. Never prune the current run, follow links, clear Windows
event logs, or discard evidence of an unresolved interrupted operation. If
space cannot be kept within the cap, stop optional verbose output and report
the condition. Healthy reporting must not become the cause of disk exhaustion.

## 9. Code organization and repository changes

Keep the upstream function-oriented style, four-space indentation, descriptive
names, comment-based help, parameter validation, strict mode, and PSCustomObject
results. Use explicit function calls in the orchestrator. Avoid a generic plugin
engine, large dynamic scriptblock dictionaries, classes for every result type,
an embedded binary payload, or a second configuration-file dependency.

Use this order within the one deployment file:

1. MIT attribution, help, public parameters, script version, and policy.
2. Result and logging helpers.
3. Preflight, path validation, lock, and session helpers.
4. Inventory and health collectors, including profile age/size.
5. A single Test-ProfileEligibility function shared by reporting and deletion.
6. Temp cleanup, profile removal, and Windows servicing helpers.
7. A short top-level try/catch/finally orchestrator and explicit exit mapping.

Proposed repository edits:

| Path | Change |
| --- | --- |
| Invoke-EndpointMaintenance.ps1 | Add the standalone supported entry point, with all necessary functions embedded. |
| README.md | Make standalone deployment primary; show modes, prerequisites, limits, and safe defaults. |
| docs/endpoint-central-proposal.md | Keep this proposal as the original design and update status after implementation. |
| docs/endpoint-central-deployment.md | Add exact console settings, collection workflow, examples, and troubleshooting. |
| tests/ | Add focused Pester tests and disposable-Windows integration fixtures. Never run destructive fixtures on real employee profiles. |
| PSScriptAnalyzerSettings.psd1 | Target Windows PowerShell 5.1. Keep formatting rules; require explicit documented reasons for safety-rule suppression. |
| .github/workflows/validate.yml | Add Windows parser/lint/Pester checks with pinned development dependencies. No runtime downloads on endpoints. |
| CHANGELOG.md | Document the fork's first release, removed behaviors, and breaking CLI changes. |
| LICENSE | Preserve upstream MIT notice and attribution. Include it in standalone distribution too. |
| PSWinVitals.psm1, PSWinVitals.psd1, PSWinVitals.format.ps1xml | Move to an explicitly labeled legacy/upstream reference area when the standalone implementation lands, so they are not mistaken for the supported deployment artifact. |

The repository can contain documentation and tests; Endpoint Central receives
one PS1. Retain upstream history and commit focused changes in this order:
standalone structure, logging/preflight, audit/profile inventory, safe cleanup,
profile deletion, optional servicing, then Windows validation/deployment docs.
There is no runtime module dependency and no need for a build/merge step to
produce the monolith.

## 10. Proposed invocation examples

These examples will work after implementation; they are not commands provided
by upstream PSWinVitals today.

```powershell
# Inventory and profile-removal candidates older than 90 days.
.\Invoke-EndpointMaintenance.ps1 -Mode Audit -ProfileAgeDays 90

# Same inventory plus detailed Windows integrity verification.
.\Invoke-EndpointMaintenance.ps1 -Mode Audit -ProfileAgeDays 90 -CheckIntegrity

# Preview standard cleanup without changing cleanup targets.
.\Invoke-EndpointMaintenance.ps1 -Mode Clean -TempAgeDays 7 -WhatIf

# Standard age-filtered cleanup.
.\Invoke-EndpointMaintenance.ps1 -Mode Clean -TempAgeDays 7

# Preview component cleanup and whole-profile removal.
# Requires the real approved domain SID and protected accounts in the policy.
.\Invoke-EndpointMaintenance.ps1 -Mode DeepClean -RemoveStaleProfiles `
    -ProfileAgeDays 90 -MaxProfilesPerRun 5 -WhatIf

# Run that same intended cleanup after reviewing the pilot reports.
.\Invoke-EndpointMaintenance.ps1 -Mode DeepClean -RemoveStaleProfiles `
    -ProfileAgeDays 90 -MaxProfilesPerRun 5

# Separately requested Windows repair from an example staged source path.
# Stage a matching source first; this example path is not an existing SJCH source.
.\Invoke-EndpointMaintenance.ps1 -Mode Clean -RepairWindows `
    -RepairSource 'C:\ProgramData\SJCH\RepairSource\Windows'
```

In Endpoint Central: Windows Custom Script, Computer Configuration, System
user, native x64 Windows PowerShell, logging enabled, and success exit code 0.
Use the uploaded PS1 from the repository and pass only the desired arguments.
The host should be started with NoProfile and NonInteractive. Do not change
machine execution policy; a signed/pinned release should follow the existing
organization's script-trust policy. Set the agent timeout above the tested
worst-case runtime, particularly for servicing.

Use separate configurations that reference the same script: recurring Audit,
scheduled conservative Clean, and an explicitly targeted DeepClean. Do not
deploy DeepClean on every refresh cycle. Standalone Custom Script does not
provide Software Deployment's full deployment-policy/reboot controls [7]; use
the scheduling available in the installed product and let script prerequisites
defer destructive work when an endpoint is still in use. The script reports
paths locally; central report collection is a separate Endpoint Central
configuration, not an embedded upload service.

## 11. Acceptance criteria before unattended rollout

| Scenario | Required result |
| --- | --- |
| Default invocation | Audit only; no update, cleanup, repair, or configuration change. |
| All mutation entry points under WhatIf | Plan/log/report only; no target mutation or native servicing repair/cleanup. |
| Invalid/missing profile age or domain policy on removal | Exit 2 before maintenance. |
| Boundary age, UTC/DST, zero/future/missing dates | Correct strict cutoff; unknown evidence never causes deletion. |
| Loaded, special, local, protected, service, kiosk, mandatory, roaming, container, or unsafe profile | Explicit exclusion/defer reason, no forced deletion. |
| Unresolved old SID from approved domain | Name resolution failure alone neither authorizes nor blocks removal; full safety evidence decides. |
| User logs on between audit and removal | Fresh checks/provider rejection stop deletion; no force logoff/unload. |
| Provider reports success but leaves a registration or directory | Partial/failed result, no fallback Remove-Item recursion. |
| New/locked temp file inside an old directory | File retained; no recursive parent deletion. |
| Junction to share, mount point, root, or another profile | No traversal/deletion outside approved paths. |
| Cloud placeholders, EFS evidence, incomplete safety traversal | No hydration; profile removal blocked where prerequisites cannot be established. |
| Huge profile, inaccessible path, millions of files | Bounded enumeration, honest partial size, no unbounded memory growth. |
| Second instance, active servicing, external termination | No overlap; durable InProgress evidence; reconciliation on next run. |
| Non-English Windows and non-console SYSTEM run | Correct output capture; unknown interpretation never marked healthy. |
| Pending servicing reboot, low power, active/disconnected sessions | Appropriate work deferred; reason visible. |
| Missing repair source or Windows Update access unavailable | No fallback network download or update installation. |
| Native failure, partial cleanup, unsupported health provider | Correct per-task execution/finding status and process exit. |
| Unwritable log destination, reparse path, nearly full disk | No destructive work without durable evidence. |
| Report expiry/cap reached | Only this tool's eligible completed logs are pruned; current/interrupted evidence survives. |
| Two consecutive successful cleanup runs | Second run is a valid no-op where nothing else became eligible. |

Run parser/PSScriptAnalyzer/Pester checks on Windows PowerShell 5.1. Test
destructive paths in a disposable Windows VM using synthetic profiles and
file trees. Then compare Audit and WhatIf reports on a small set of clinical
workstations under Endpoint Central SYSTEM, confirm domain/protected-account
policy, and pilot standard cleanup before allowing profile removal. Verify
Windows-created profile cleanup behavior for that build, including default
legacy junctions and redirected/synced folder exclusions. A source proposal
and unit tests alone cannot certify those platform behaviors.

## Sources

1. [Microsoft: Scripts to retrieve profile age and optionally delete aged copies](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/scripts-retrieve-profile-age-delete-aged-copies).
2. [Microsoft: Win32_UserProfile properties](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/legacy/ee886409(v=vs.85)).
3. [Microsoft: Clean up the WinSxS folder](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11).
4. [Microsoft: CHKDSK reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/chkdsk).
5. [Microsoft: Repair-WindowsImage](https://learn.microsoft.com/en-us/powershell/module/dism/repair-windowsimage?view=windowsserver2025-ps).
6. [PSWinVitals source at the reviewed commit](https://github.com/ralish/PSWinVitals/blob/ff133b76a1b8b444c46f5bdb3e9118d9b0ad83b5/PSWinVitals.psm1).
7. [ManageEngine: Windows Computer Custom Script configuration](https://www.manageengine.com/products/desktop-central/help/configuration-management/executing_custom_scripts-computer.html).

Sources support platform behavior. Mode names, thresholds, limits, exclusions,
logging format, and deployment defaults above are proposed engineering choices
for this fork, not vendor guarantees or an industry standard.
