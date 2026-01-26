# Install Guide (Ubuntu 24.04)

> **Run steps 01 and 04 from a local console if possible.**  
> Netplan changes can momentarily interrupt networking and drop SSH.

## Prereqs

- Ubuntu Server 24.04 LTS installed
- You have console access (recommended)
- You know the IP settings for your lab network

## Execution Order (Do Not Deviate)

| Step | Script                          | Must Run As | Reboot After |
|------|---------------------------------|------------|--------------|
| 01   | `scripts/01-prepare-gns3-host.sh`    | root       | ✅ YES        |
| 02   | `scripts/02-install-docker.sh`       | root       | ✅ YES        |
| 03   | `scripts/03-install-gns3-server.sh`  | root       | ✅ YES        |
| 04   | `scripts/04-bridge-tap-provision.sh` | root       | ✅ YES        |
| 05   | Connect from GNS3 GUI                | user `gns3`| —            |

## Step 01 — Prepare Host

```bash
sudo bash scripts/01-prepare-gns3-host.sh
sudo reboot
```

What it does:
- Prompts for NIC + static IPv4 and writes Netplan (`/etc/netplan/01-static-ip.yaml`)
- Sets timezone and enables NTP
- Installs admin/network utilities
- Installs and enables OpenSSH server
- Creates `gns3` user (optional passwordless sudo)
- Installs KVM/libvirt baseline + kernel/sysctl tuning

## Step 02 — Install Docker CE

```bash
sudo bash scripts/02-install-docker.sh
sudo reboot
```

What it does:
- Installs Docker CE from official Docker repo
- Enables Docker
- Adds `gns3` user to `docker` group

## Step 03 — Install GNS3 Server (Ubuntu PPA)

```bash
sudo bash scripts/03-install-gns3-server.sh
sudo reboot
```

What it does:
- Installs GNS3 Server + ubridge + KVM/libvirt deps
- Writes `gns3_server.conf` with explicit tool paths
- Installs and enables `gns3server` systemd service
- Verifies `ubridge` is executable for `gns3` user

## Step 04 — Bridge + TAP Provision

```bash
sudo bash scripts/04-bridge-tap-provision.sh
sudo reboot
```

What it does:
- Creates Netplan bridge config (`br0` owns the IP; NIC becomes bridge port)
- Creates `tap0` and `tap1` owned by `gns3`
- Installs and enables `gns3-taps.service` so TAPs persist after reboot

## Step 05 — Connect from GNS3 GUI

- Add remote server: the host’s IP
- Add a Cloud node and bind to `tap0` / `tap1`

## References

- Docker Engine install (Ubuntu): https://docs.docker.com/engine/install/ubuntu/
- Docker Engine install (Debian): https://docs.docker.com/engine/install/debian/
- GNS3 Linux install: https://docs.gns3.com/docs/getting-started/installation/linux/


## Logging

All scripts write logs to:

- `/var/log/gns3-bare-metal/`

Each script run creates a timestamped log file.

To package logs for support/submission:

```bash
sudo bash scripts/06-collect-logs.sh
```

## Dry-run (advanced)

Preview what each script will do:

```bash
sudo bash scripts/02-install-docker.sh --dry-run
```


## Verify host readiness

After Step 04 (and reboot), run:

```bash
sudo bash scripts/07-verify-host.sh
```

This performs non-mutating checks for:
- KVM
- Docker
- gns3server
- br0 + tap0/tap1 + gns3-taps service

Exit code `0` means READY.
