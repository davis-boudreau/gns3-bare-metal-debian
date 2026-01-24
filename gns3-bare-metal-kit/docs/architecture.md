# Architecture Notes

## Why the execution order matters

The Linux bridge + TAP interfaces are the *last* physical abstraction layer.

If you create `br0` and TAPs too early (before Docker + GNS3):
- you can hit permission errors
- GNS3 Cloud nodes may fail to bind to TAPs
- group membership changes don’t propagate cleanly

## High-level stack

- OS baseline: time, SSH, KVM/libvirt, kernel tuning
- Container runtime: Docker CE
- GNS3 server runtime: `gns3server` systemd service + ubridge
- L2 integration: `br0` and persistent TAP interfaces (tap0/tap1)

## Ubuntu vs Debian

This repo is Ubuntu-first for two reasons:
1) Netplan is the default Ubuntu server network configuration system.
2) The official GNS3 PPA workflow used here is Ubuntu-specific.

Docker can be installed on Debian, but GNS3 installation varies by distro and is not included yet.
