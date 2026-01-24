# Security Notes (Lab vs Production)

This kit is designed for **learning labs**. Review and adjust for any production-like use.

## SSH

- Lab mode may enable password authentication.
- Recommended hardening:
  - Disable password auth and use SSH keys
  - Restrict SSH to management VLAN
  - Enable fail2ban / rate limits if appropriate

## Runtime user (`gns3`)

- The `gns3` user may be granted passwordless sudo for lab convenience.
- In production-like environments, remove passwordless sudo and use least privilege.

## Bridging + TAP interfaces

- `br0` + TAPs create an L2 extension from the host into GNS3 projects.
- Treat `tap0/tap1` as untrusted edges and apply segmentation:
  - host firewall rules
  - VLAN separation
  - explicit GNS3 project policies

## Docker

- Docker group membership gives root-equivalent capabilities on many systems.
- Use it only in trusted lab contexts.

## Logs and configuration

- Systemd services:
  - `gns3server.service`
  - `gns3-taps.service`
- GNS3 config is written under:
  - `/home/gns3/.config/GNS3/2.2/gns3_server.conf`
