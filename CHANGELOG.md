# Changelog

All notable changes to this project will be documented in this file.

---

## [1.0.4] - 2026-01-26

### Added
- Step 00 installation workflow for copying files from USB or local media
- Optional root filesystem expansion script:
  - `05-expand-root-lvm-ubuntu.sh`
- Host readiness verification script:
  - `07-verify-host.sh`
- Structured install report summary output
- Formal install flow documentation in `install.md`

### Fixed
- Critical systemd TAP service failure caused by shell redirection (`2>/dev/null`)
- Replaced with systemd-native error-tolerant syntax (`ExecStartPre=-`)
- Ensured persistent creation of:
  - `tap0`
  - `tap1`
- Verified clean bridge attachment to `br0`

### Improved
- Documentation clarity and execution order enforcement
- Logging consistency across all scripts
- Separation between OS preparation and networking abstraction layers
- Improved student and lab safety during Netplan operations

---

## [1.0.3] - 2026-01-25
- Logging framework introduced
- Dry-run mode added
- Trap-based failure handling
- Structured install summaries

---

## [1.0.2]
- Initial verification tooling
- Early systemd service support

---

## [1.0.1]
- Baseline installer release

---

## [1.0.0]
- Initial bare-metal GNS3 deployment framework