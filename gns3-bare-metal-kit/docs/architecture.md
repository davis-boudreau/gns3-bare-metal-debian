# Architecture Overview — GNS3 Bare-Metal Server Kit (v1.0.5)

This document describes the **intended host architecture** for the GNS3 Bare-Metal Server Kit.
It explains how networking, virtualization, and container layers fit together to support
predictable student labs.

---

## High-Level Architecture

```text
                ┌──────────────────────────┐
                │   Student / Instructor   │
                │     GNS3 GUI Client      │
                └────────────┬─────────────┘
                             │ TCP 3080
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                    Ubuntu Server 24.04                        │
│                                                              │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐ │
│  │  Docker CE   │     │  libvirt/KVM │     │  GNS3 Server │ │
│  │ (Containers) │     │ (QEMU VMs)   │     │ (Controller)│ │
│  └──────┬───────┘     └──────┬───────┘     └──────┬───────┘ │
│         │                    │                    │         │
│         └────────────┬───────┴────────────┬───────┘         │
│                      │                    │                 │
│                ┌─────▼────────────────────▼─────┐           │
│                │        Linux Bridge (br0)        │           │
│                │  - Physical NIC (uplink)         │           │
│                │  - tap0, tap1 (persistent)       │           │
│                └─────┬────────────────────┬─────┘           │
│                      │                    │                 │
│              ┌───────▼───────┐    ┌───────▼───────┐         │
│              │ GNS3 Nodes /  │    │   Cloud Node   │         │
│              │ QEMU / Docker│    │ (NAT / LAN)    │         │
│              └───────────────┘    └────────────────┘         │
│                                                              │
│  libvirt default NAT (virbr0):                                │
│    - Network: 192.168.100.0/24                                │
│    - Gateway: 192.168.100.1                                   │
│    - DHCP:    192.168.100.129–190                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Key Design Principles

### 1. Deterministic Networking
- Static host IP via Netplan
- Deterministic bridge (`br0`) and TAP naming
- Deterministic libvirt NAT subnet and DHCP pool

This ensures labs behave the same across rebuilds and semesters.

### 2. Layered Responsibility
| Layer        | Responsibility |
|--------------|----------------|
| Ubuntu OS    | Hardware, kernel, NICs |
| KVM/libvirt  | VM virtualization |
| Docker       | Container-based appliances |
| GNS3 Server  | Topology orchestration |
| br0 + TAPs   | L2 connectivity into projects |
| virbr0 NAT  | Internet access for labs |

### 3. Bridge Comes Last (Critical)
The Linux bridge and TAP interfaces **must** be created after:
- Docker
- GNS3 Server
- libvirt

Creating the bridge earlier causes permission and Cloud-node failures.

### 4. Single Flat NAT Network (v1.0.5)
v1.0.5 intentionally uses:
- A **single /24 NAT network**
- No pre-provisioned routed/VLSM subnets

This avoids NAT edge cases and keeps student routing labs focused inside GNS3,
not on host policy routing.

---

## Why TAP Interfaces (tap0/tap1)?

- TAPs provide true Layer‑2 connectivity
- Cloud nodes can bridge directly into `br0`
- systemd ensures TAPs exist after reboot
- No manual recreation required

---

## What This Architecture Is NOT

- ❌ A production firewall or edge router
- ❌ A multi-tenant secure virtualization host
- ❌ A dynamic campus network fabric

It is an **instructional platform**, optimized for:
- clarity
- repeatability
- safe failure and rebuild

---

## Related Documents

- `docs/install.md` — step-by-step execution order
- `docs/security-notes.md` — hardening recommendations
- `docs/troubleshooting.md` — recovery and rollback scenarios
