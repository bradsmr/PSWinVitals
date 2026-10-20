# Validation status

Version: 1.0.0-rc1. Date: 2026-10-20.

## Completed during development

- PowerShell parser: passed in PowerShell 7.6.6 on Linux.
- Dependency-free portable tests: **40 passed, 0 failed**.
- GitHub Actions: **44 passed, 0 failed** in Windows PowerShell 5.1;
  **40 passed, 0 failed** in PowerShell 7.6.6 on Ubuntu.
  [Recorded run](https://github.com/bradsmr/PSWinVitals/actions/runs/39507533784)
  at implementation commit `70c1b782ac43e391add5f1d842b2a9059d91478d`.
- Unsupported-host execution: exited 2 with a clear message on Linux.
- Reviewed source: no update installation/scan, module download, browser clearing,
  Recycle Bin purge, process termination, forced logoff, or automatic reboot.

Tests cover operation selection, comma-separated exclusions, the 180-day
default, processing eight profiles in one pass, exact age cutoff, signed
FILETIME DWORDs, UTC normalization, missing/invalid/future evidence, newer
activity, loaded/shared/local/special profiles, external links, old/new temp
files, WhatIf, repeated cleanup, provider leftovers, cloud/EFS exclusions,
native argument strings, output decoding, and empty/nonempty reports.

Provider mutations are simulated against new disposable test directories.
This does not validate real Win32_UserProfile deletion semantics on Windows.

## Windows checks

The workflow runs `tests/Invoke-Tests.ps1` in **Windows PowerShell 5.1** on a
Windows runner. Additional cases exercise WTS enumeration, file locks, actual
native argv parsing, and audit orchestration/secure logging with synthetic
collectors. They do not repair Windows or remove employee profiles.

All included Windows cases passed. The hosted runner used Windows Server 2025
and Windows PowerShell 5.1.26100.33438. The audit orchestration case substitutes
the workstation identity and synthetic collectors; production execution still
rejects servers. These checks are not Windows 10/11 SYSTEM certification.

PSScriptAnalyzer was not run. Tests and the workflow install no modules.

## Required before broad deployment

Run Audit, WhatIf, and an approved cleanup pilot on Windows 10/11 through
Endpoint Central as SYSTEM. Validate profile age evidence, deployed languages'
native SFC/DISM output, provider deletion/leftovers, default junction handling,
and security-agent coexistence. Use synthetic Windows-created profiles in a
disposable VM for destructive provider checks before employee data is eligible.

This is an implemented release candidate, with production/SYSTEM validation
still outstanding.
