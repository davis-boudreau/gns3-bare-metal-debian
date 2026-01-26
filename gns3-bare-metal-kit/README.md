# GNS3 Bare‑Metal Server Kit (Ubuntu 24.04)

A reproducible, **scripted** install for a bare‑metal GNS3 Server host with Docker + KVM + a Linux bridge + persistent TAP interfaces.

This kit is designed for **learning labs** and predictable rebuilds.

## Supported OS

- ✅ **Ubuntu Server 24.04 LTS** (primary / tested)
- ⚠️ Debian is *not* supported for the full stack **yet** (GNS3 PPA is Ubuntu‑only). Docker install is compatible with Debian, but scripts **01/03/04** assume Ubuntu defaults (Netplan + PPA). See `docs/architecture.md`.

## ⚠️ Safety & Security Notes (Read First)

- **Networking changes can drop SSH**. Steps 01 and 04 rewrite Netplan and may interrupt connectivity.
  - Prefer running from a **local console / iDRAC / IPMI**.
  - The scripts create timestamped backups for rollback.
- SSH **password authentication** can be enabled for labs. Disable for production.
- A Linux bridge exposes L2 connectivity to TAP interfaces — treat the host like an edge device.

See `docs/security-notes.md` for recommended hardening steps.

---

## Install Instructions — Execution Order (Do Not Deviate)

| Step | Script                          | Must Run As | Reboot After |
|------|---------------------------------|------------|--------------|
| 01   | `scripts/01-prepare-gns3-host.sh`    | root       | ✅ YES        |
| 02   | `scripts/02-install-docker.sh`       | root       | ✅ YES        |
| 03   | `scripts/03-install-gns3-server.sh`  | root       | ✅ YES        |
| 04   | `scripts/04-bridge-tap-provision.sh` | root       | ✅ YES        |
| 05   | Connect from GNS3 GUI                | user `gns3`| —            |

> **Note:** If the bridge exists before Docker + GNS3 → you will hit permission and Cloud‑node failures.

---

## Conceptual Dependency Graph

```text
Ubuntu OS
   │
   ├── Time / NTP
   ├── SSH
   ├── KVM / Kernel
   │
Docker Runtime
   │
GNS3 Server
   │
Linux Bridge (br0)
   │
TAP Interfaces (tap0, tap1)
   │
GNS3 Complete Installation
```

> **Bridge + TAP is the LAST physical abstraction layer**  
> It must sit *above* Docker + GNS3, not beside them.

---

## Execution Flow (Safe Instructions)

```bash
# Step 1 – OS preparation
sudo bash scripts/01-prepare-gns3-host.sh
sudo reboot

# Step 2 – Docker
sudo bash scripts/02-install-docker.sh
sudo reboot

# Step 3 – GNS3 Server
sudo bash scripts/03-install-gns3-server.sh
sudo reboot

# Step 4 – Bridge + TAP
sudo bash scripts/04-bridge-tap-provision.sh
sudo reboot
```

---

## Optional: Expand Root Filesystem (Ubuntu LVM Default Only)

If you installed Ubuntu with default LVM and your root LV is small (common on some installs), you can run:

```bash
sudo bash scripts/05-expand-root-lvm-ubuntu.sh
```

This script **only** operates on Ubuntu’s default LV path and safely exits if it is not present.

---

## Files / Layout

```text
gns3-bare-metal-kit/
├─ scripts/
│  ├─ 01-prepare-gns3-host.sh
│  ├─ 02-install-docker.sh
│  ├─ 03-install-gns3-server.sh
│  ├─ 04-bridge-tap-provision.sh
│  ├─ 05-expand-root-lvm-ubuntu.sh
│  ├─ 06-collect-logs.sh
│  ├─ 07-verify-host.sh
│  └─ lib/
│     └─ common.sh
├─ systemd/
│  ├─ gns3server.service
│  └─ gns3-taps.service
└─ docs/
   ├─ install.md
   ├─ architecture.md
   ├─ troubleshooting.md
   └─ security-notes.md
```

---
---

## Logging

All scripts automatically log to:

- **Directory:** `/var/log/gns3-bare-metal/`
- **Files:** `<scriptname>-YYYY-MM-DD_HH-MM-SS.log`

Logs mirror to the console and are written to disk for troubleshooting and student submissions.

To collect logs for support/submission:

```bash
sudo bash scripts/06-collect-logs.sh
```

---

## Dry-run (advanced)

All scripts support dry-run mode to preview actions **without executing mutating commands**:

```bash
sudo bash scripts/01-prepare-gns3-host.sh --dry-run
```

Notes:
- Dry-run prints commands and prompts.
- Package installs, file writes, service changes, and network changes are skipped.

---

## Verify host readiness

Run a non-mutating readiness check (KVM, Docker, GNS3, bridge, TAPs) and produce a single report:

```bash
sudo bash scripts/07-verify-host.sh
```

Exit codes:
- `0` = READY
- `1` = NOT READY


## License

MIT — see `LICENSE`.

## References

- Docker Engine install docs (Ubuntu / Debian).  
- GNS3 Linux installation docs.

(Links are included in `docs/install.md`.)
