# 🔐 GNS3 Server Installation Bare Metal Execution Order (Do Not Deviate)

This is the order you should execute the GNS3 Server Installation on Bare Metal.

| Step | Script                       | Must Run As | Reboot After                 |
| ---- | ---------------------------- | ----------- | ---------------------------- |
| 01   | `01-prepare-gns3-host.sh`    | root        | ✅ YES                        |
| 02   | `02-install-docker.sh`       | root        | ✅ YES                        |
| 03   | `03-install-gns3-server.sh`  | root        | ❌ (recommended but optional) |
| 04   | `04-bridge-tap-provision.sh` | root        | ❌                            |
| 05   | GNS3 GUI connects            | user `gns3` | —                            |

> **Note:**
> If the bridge exists before Docker + GNS3 → you will hit permission and Cloud-node failures.

---

# 🧠 Conceptual Dependency Graph

```
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

# 📌 Execution Flow (Safe Instructions)

This is how you should **Install GNS3 on bare metal**:

```bash
# Step 1 – OS preparation
sudo bash 01-prepare-gns3-host.sh
sudo reboot

# Step 2 – Docker
sudo bash 02-install-docker.sh
sudo reboot

# Step 3 – GNS3 Server
sudo bash 03-install-gns3-server.sh

# Step 4 – Bridge + TAP
sudo bash 04-bridge-tap-provision.sh
```