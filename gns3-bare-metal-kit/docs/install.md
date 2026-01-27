# ✅ UPDATED README.md (v1.0.4)

```markdown
# GNS3 Bare-Metal Server Kit (Ubuntu 24.04)

A production-grade, educationally safe installation framework for deploying a
**fully functional GNS3 Server on bare-metal Ubuntu 24.04 LTS**.

This project is designed for:

- Networking and security labs
- Academic environments (NSCC-aligned)
- Persistent Layer-2 bridging
- Clean separation of responsibilities
- Deterministic installation order
- Reproducible host readiness verification

---

## 🚀 What This Kit Provides

- ✅ Static IPv4 provisioning via Netplan
- ✅ Dedicated runtime user (`gns3`)
- ✅ Docker CE installation (official repo)
- ✅ GNS3 Server installation (official PPA)
- ✅ Verified ubridge execution model
- ✅ Linux bridge (`br0`) architecture
- ✅ Persistent TAP interfaces (`tap0`, `tap1`)
- ✅ Systemd-managed services
- ✅ Structured logging
- ✅ Dry-run support
- ✅ Host readiness verification report
- ✅ Safe optional root filesystem expansion

---

## 🧠 Architecture Overview

```

Physical NIC
│
▼
Linux Bridge (br0)
│
├── tap0  → GNS3 Cloud Node
└── tap1  → GNS3 Cloud Node

Docker + GNS3 Server sit ABOVE the OS
Bridge + TAP sit ABOVE Docker + GNS3

```

> The bridge layer must be created **after** Docker and GNS3  
> or Cloud node permissions will fail.

---

## 📦 Repository Structure

```

gns3-bare-metal-kit/
├── scripts/
│   ├── 01-prepare-gns3-host.sh
│   ├── 02-install-docker.sh
│   ├── 03-install-gns3-server.sh
│   ├── 04-bridge-tap-provision.sh
│   ├── 05-expand-root-lvm-ubuntu.sh
│   ├── 06-collect-logs.sh
│   └── 07-verify-host.sh
│
├── systemd/
│   └── gns3-taps.service
│
├── docs/
│   └── troubleshooting.md
│
├── install.md
├── CHANGELOG.md
└── README.md

````

---

## 🧭 Installation Flow (Do Not Deviate)

| Step | Description |
|------|-------------|
| 00 | Copy installer files to local system |
| 01 | Prepare host + static networking |
| 02 | Install Docker CE |
| 03 | Install GNS3 Server |
| 04 | Configure bridge + TAP interfaces |
| 05 | (Optional) Expand root filesystem |
| 06 | Verify host readiness |
| 07 | Connect from GNS3 GUI |

👉 **Full step-by-step instructions are documented in:**  
📄 **[`install.md`](install.md)**

---

## 🔍 Host Verification

After installation and reboot:

```bash
sudo bash scripts/07-verify-host.sh
````

The verifier performs **non-mutating checks** for:

* KVM acceleration
* Docker engine
* GNS3 server service
* Linux bridge (`br0`)
* TAP interfaces (`tap0`, `tap1`)
* `gns3-taps.service`

Exit code `0` means:

```
✅ HOST READY
```

---

## 📜 Logging

All scripts write structured logs to:

```
/var/log/gns3-bare-metal/
```

Each execution generates a timestamped file.

To collect all logs:

```bash
sudo bash scripts/06-collect-logs.sh
```

---

## 🧪 Dry-Run Mode (Advanced)

Most scripts support dry-run mode:

```bash
sudo bash scripts/02-install-docker.sh --dry-run
```

This shows intended actions without modifying the system.

---

## 🎓 Educational Design Notes

This project was built with:

* deterministic execution order
* explicit privilege boundaries
* visible infrastructure layers
* teachable Linux networking concepts
* long-term maintainability

It intentionally avoids:

* hidden automation
* opaque installers
* fragile network abstractions

---

## 📄 License

MIT License
Copyright © 2026 Davis Boudreau

---

## ✅ Current Release

**Version:** `v1.0.4`
See [`CHANGELOG.md`](CHANGELOG.md) for full release notes.

````

**Release Notes **

```
This release finalizes the GNS3 bare-metal installation architecture for Ubuntu 24.04.

Highlights:
- Fully verified Linux bridge + TAP persistence model
- systemd-native TAP service (no shell redirection bugs)
- deterministic install order
- structured logging and dry-run support
- unified host readiness verification report
- optional root filesystem expansion
- complete documentation rewrite

This release is considered the first stable, instructor-safe,
student-safe reference implementation for bare-metal GNS3 deployments.
```

---