# Changelog

All notable changes to this project will be documented in this file.

## [1.0.3] - 2026-01-25
### Fixed
- Dry-run mode now exits early for install scripts to prevent partial runs and false failures
- Robust binary path detection under 'set -e' (ubridge/qemu/dynamips)

## [1.0.2] - 2026-01-23
### Added
- 07-verify-host.sh non-mutating host readiness report (KVM/Docker/GNS3/bridge/TAPs)

## [1.0.1] - 2026-01-23
### Added
- Automatic file logging to /var/log/gns3-bare-metal (all scripts)
- --dry-run flag across scripts (prints commands; skips mutating actions)
- Install report summary at end of each script
- Failure trap with line number + summary
- 06-collect-logs.sh helper script

## [1.0.0] - 2026-01-22
### Added
- Ubuntu 24.04 bare-metal install scripts (01–04) for:
  - host preparation (static IP via Netplan, SSH, KVM baseline)
  - Docker CE install
  - GNS3 server install (PPA), systemd service, verification gate
  - Linux bridge + persistent TAPs (systemd oneshot service)
- Optional Ubuntu default-LVM root expansion script (05)
- Docs: install / architecture / troubleshooting / security notes
- Repo hygiene files: LICENSE, SECURITY.md, .editorconfig, .gitignore
