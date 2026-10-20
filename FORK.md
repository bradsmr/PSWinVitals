# PSWinVitals Endpoint Central fork

This fork starts from [ralish/PSWinVitals](https://github.com/ralish/PSWinVitals).
The proposed deployment target is unattended Windows 10/11 workstation
maintenance through ManageEngine Endpoint Central.

Current status: **design proposal, not an implemented maintenance release**.
The original module remains unchanged and retains its original defaults.
Do not deploy it as if the safeguards in the proposal already exist.

Read [the exact change proposal](docs/endpoint-central-proposal.md).

Upstream baseline:

- Branch: `main`.
- Commit: `ff133b76a1b8b444c46f5bdb3e9118d9b0ad83b5`.
- Commit date: 2025-11-17.
- Manifest version: 0.7.0.
- Release tag `v0.7.0`: `978c25cd4b82248fa9e3199c3930c8914ca507b3`.
- Proposal branch: `sjch/unattended-proposal`.
- License: MIT. Preserve the original [LICENSE](LICENSE) and attribution in
  the eventual standalone script.

The implementation proposal deliberately keeps a single deployment file while
using named functions internally. Development documentation and tests stay in
the repository and do not need to be copied to endpoints.
