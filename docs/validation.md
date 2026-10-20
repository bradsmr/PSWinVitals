# Validation status

Version: 1.0.0-rc1. Date: 2026-10-20.

## Completed during development

- PowerShell parser: passed in PowerShell 7.6.6 on Linux.
- Dependency-free portable tests: **40 passed, 0 failed**.
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

## Included Windows checks

The workflow runs `tests/Invoke-Tests.ps1` in **Windows PowerShell 5.1** on a
Windows runner. Additional cases exercise WTS enumeration, file locks, actual
native argv parsing, and audit orchestration/secure logging with synthetic
collectors. They do not repair Windows or remove employee profiles.

Until a workflow run is recorded, the Windows-specific cases are **included but
not yet executed**. A Linux parser check is not Windows 5.1/SYSTEM certification.

An optional linter installation was blocked by automatic approval review after
outbound telemetry was attempted. It was not retried or bypassed. No linter
success is claimed. Tests and the workflow install no modules.

## Required before broad deployment

Run Audit, WhatIf, and an approved cleanup pilot on Windows 10/11 through
Endpoint Central as SYSTEM. Validate profile age evidence, deployed languages'
native SFC/DISM output, provider deletion/leftovers, default junction handling,
and security-agent coexistence. Use synthetic Windows-created profiles in a
disposable VM for destructive provider checks before employee data is eligible.

This is an implemented release candidate, with production/SYSTEM validation
still outstanding.
