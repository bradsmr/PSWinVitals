# PSWinVitals Endpoint Central fork

This fork starts from [ralish/PSWinVitals](https://github.com/ralish/PSWinVitals).
The proposed deployment target is unattended Windows 10/11 workstation
maintenance through ManageEngine Endpoint Central.

Current status: **implemented standalone release candidate, 1.0.0-rc1**.
Use [Invoke-EndpointMaintenance.ps1](Invoke-EndpointMaintenance.ps1) and the
[current README](README.md). The original module is preserved under `legacy/`
with its original defaults. It is not the new deployment entry point.

The earlier proposal is superseded and retained in Git history. The current
interface has Audit by default, one Clean switch, explicit operation flags,
All, 180-day profile retention, and no per-run profile cap.

Upstream baseline:

- Branch: `main`.
- Commit: `ff133b76a1b8b444c46f5bdb3e9118d9b0ad83b5`.
- Commit date: 2025-11-17.
- Manifest version: 0.7.0.
- Release tag `v0.7.0`: `978c25cd4b82248fa9e3199c3930c8914ca507b3`.
- Supported branch: `main` in [bradsmr/PSWinVitals](https://github.com/bradsmr/PSWinVitals).
- License: MIT. The original [LICENSE](LICENSE) and attribution are preserved
  in the standalone script.

Deploy one PS1. Documentation and tests stay in the repository. See
[validation status](docs/validation.md) for completed checks and Windows/SYSTEM
pilot work still needed.
