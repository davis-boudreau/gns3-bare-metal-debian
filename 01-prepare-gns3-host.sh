#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      01-prepare-gns3-host.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary (What this script does):
#   - Prompts for a primary NIC and provisions a STATIC IPv4 using Netplan
#   - Sets timezone to America/Halifax and enables NTP
#   - Updates packages and installs common network/admin utilities
#   - Installs and enables OpenSSH Server (password login enabled for lab use)
#   - Creates a dedicated runtime user: gns3 (with optional passwordless sudo)
#   - Sets a fixed default SSH password for gns3 and prevents password changes
#   - Installs KVM/libvirt baseline (virtualization readiness)
#   - Loads tun/br_netfilter modules and applies sysctl networking tuning
#   - Raises file descriptor limits for large labs
#
# Usage:
#   sudo bash 01-prepare-gns3-host.sh
#
# Notes for students:
#   - This script is intentionally verbose with comments so you can learn.
#   - "Idempotent" goal: safe to rerun; many steps check first before changing.
#==============================================================================

#------------------------------------------------------------------------------
# MIT License
#
# Copyright (c) 2026 Davis Boudreau
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#------------------------------------------------------------------------------

set -euo pipefail
# -e: exit on error; -u: error on unset variables; -o pipefail: fail if any pipe command fails

GNS3_USER="gns3"
TZ="America/Halifax"

# Lab default password:
# NOTE: contains '$' so ALWAYS single-quote to prevent shell expansion.
DEFAULT_PASSWORD='3P7JDW2$'

SSH_DROPIN="/etc/ssh/sshd_config.d/99-gns3-lab.conf"
STATIC_NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
    echo "✔ Backup created: ${f}.bak.${ts}"
  fi
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

list_nics() {
  # Show likely physical NICs; exclude loopback and common virtual devices.
  ip -br link | awk '
    $1 !~ /^lo$/ &&
    $1 !~ /^(br|tap|tun|docker|veth|virbr|vnet|wg|zt|vxlan|gre|gretap|ip6gre|sit|dummy|bond|team)/ {
      print " - " $1
    }'
  echo ""
}

default_uplink_nic() {
  # Try to detect NIC used by the default route (most common uplink).
  ip route show default 0.0.0.0/0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

echo "=============================="
echo " GNS3 Host Pre-Req Setup (Ubuntu 24.04)"
echo " Runtime user: ${GNS3_USER}"
echo " Timezone: ${TZ}"
echo " Version: 1.0.0"
echo " Author: Davis Boudreau"
echo "=============================="

need_root

#------------------------------------------------------------------------------
# STEP 0 — Static IPv4 Provisioning (SSH-safe)
#------------------------------------------------------------------------------
echo "[0/10] Provisioning static IPv4 (SSH-safe)..."

apt-get update -y
apt-get install -y netplan.io iproute2 iputils-ping

echo ""
echo "=== Static IPv4 Configuration ==="
echo "Pick the interface connected to your LAN (so SSH stays predictable)."
echo ""

echo "Available NICs:"
list_nics

GUESS="$(default_uplink_nic || true)"
if [[ -n "$GUESS" ]]; then
  echo "Detected default-route uplink NIC: $GUESS"
  echo ""
fi

while true; do
  if [[ -n "$GUESS" ]]; then
    read -rp "Enter primary NIC name [${GUESS}]: " NIC
    NIC="${NIC:-$GUESS}"
  else
    read -rp "Enter primary NIC name: " NIC
  fi

  [[ -n "$NIC" ]] || { echo "Please enter a NIC name."; continue; }
  ip link show "$NIC" >/dev/null 2>&1 && break
  echo "Invalid NIC '$NIC'. Check with: ip -br link"
done

while true; do
  read -rp "IPv4 Address (ex: 172.16.184.10): " IP_ADDR
  is_ipv4 "$IP_ADDR" && break
  echo "Invalid IPv4 format."
done

while true; do
  read -rp "CIDR Prefix (ex: 24): " CIDR
  [[ "$CIDR" =~ ^[0-9]+$ && "$CIDR" -ge 8 && "$CIDR" -le 30 ]] && break
  echo "CIDR must be between 8 and 30."
done

while true; do
  read -rp "Default Gateway (ex: 172.16.184.250): " GATEWAY
  is_ipv4 "$GATEWAY" && break
  echo "Invalid gateway IPv4."
done

while true; do
  read -rp "DNS Server 1 (required, ex: 8.8.8.8): " DNS1
  is_ipv4 "$DNS1" && break
  echo "Invalid DNS IPv4."
done

read -rp "DNS Server 2 (optional, press Enter to skip): " DNS2

DNS_LIST=("$DNS1")
if [[ -n "$DNS2" ]]; then
  if is_ipv4 "$DNS2"; then
    DNS_LIST+=("$DNS2")
  else
    echo "⚠ DNS2 is invalid, ignoring."
  fi
fi

# Build YAML list safely: [8.8.8.8, 1.1.1.1]
DNS_YAML="[$(IFS=, ; echo "${DNS_LIST[*]}")]"

echo ""
echo "Static IPv4 summary:"
echo " - NIC:     ${NIC}"
echo " - IP/CIDR: ${IP_ADDR}/${CIDR}"
echo " - GW:      ${GATEWAY}"
echo " - DNS:     ${DNS_LIST[*]}"
echo ""

echo "Writing netplan static IP configuration: ${STATIC_NETPLAN_FILE}"
backup_if_exists "${STATIC_NETPLAN_FILE}"

# NOTE FOR STUDENTS:
# Netplan YAML is how Ubuntu Server defines network settings persistently.
# We use systemd-networkd renderer for server stability and consistency.
cat > "${STATIC_NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    ${NIC}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${IP_ADDR}/${CIDR}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: ${DNS_YAML}
      optional: true
EOF

echo "Applying netplan..."
netplan generate
netplan apply

echo "Verification:"
ip -br addr show "${NIC}" || true
ip route | head -n 5 || true

echo "✔ Static IPv4 applied. You should be able to SSH using:"
echo "  ssh ${GNS3_USER}@${IP_ADDR}"
echo ""

#------------------------------------------------------------------------------
# STEP 1 — Timezone + NTP
#------------------------------------------------------------------------------
echo "[1/11] Configuring timezone and NTP..."

timedatectl set-timezone "${TZ}"
timedatectl set-ntp true
timedatectl status

#------------------------------------------------------------------------------
# STEP 2 — Update OS packages
#------------------------------------------------------------------------------
echo "[2/11] Updating system packages..."
apt-get update -y
apt-get upgrade -y

#------------------------------------------------------------------------------
# STEP 3 — Base utilities
#------------------------------------------------------------------------------
echo "[3/11] Installing base utilities..."

apt-get install -y \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  apt-transport-https net-tools iproute2 iputils-ping tcpdump traceroute \
  vim nano htop bridge-utils

#------------------------------------------------------------------------------
# STEP 4 — OpenSSH Server
#------------------------------------------------------------------------------
echo "[4/10] Installing and enabling OpenSSH server..."

apt-get install -y openssh-server
systemctl enable --now ssh
systemctl status ssh --no-pager || true

#------------------------------------------------------------------------------
# STEP 5 — Create dedicated gns3 user
#------------------------------------------------------------------------------
echo "[5/10] Ensuring user '${GNS3_USER}' exists..."

if id "${GNS3_USER}" >/dev/null 2>&1; then
  echo "✔ User '${GNS3_USER}' already exists."
else
  useradd -m -s /bin/bash "${GNS3_USER}"
  echo "✔ Created user '${GNS3_USER}'."
fi

# Lab convenience: passwordless sudo (comment out if not desired)
if [[ ! -f "/etc/sudoers.d/${GNS3_USER}" ]]; then
  echo "${GNS3_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${GNS3_USER}"
  chmod 440 "/etc/sudoers.d/${GNS3_USER}"
  echo "✔ Configured passwordless sudo for '${GNS3_USER}' (lab mode)."
else
  echo "✔ Sudoers file already present for '${GNS3_USER}'."
fi

#------------------------------------------------------------------------------
# STEP 6 — Set fixed SSH password + prevent changes
#------------------------------------------------------------------------------
echo "[6/11] Setting fixed SSH password for '${GNS3_USER}' and preventing password changes..."

echo "${GNS3_USER}:${DEFAULT_PASSWORD}" | chpasswd

# Student note:
# chage controls password aging rules. Setting min/max to huge values effectively
# prevents required changes. We also explicitly deny passwd/chage via sudoers below.
chage -m 99999 -M 99999 "${GNS3_USER}"

PASSWD_DENY="/etc/sudoers.d/${GNS3_USER}-deny-passwd"
cat > "${PASSWD_DENY}" <<EOF
# Managed by 01-prepare-gns3-host.sh (NSCC lab kit)
Cmnd_Alias PASSWD_CMDS = /usr/bin/passwd, /usr/bin/chage
${GNS3_USER} ALL=(ALL) NOPASSWD:ALL, !PASSWD_CMDS
EOF
chmod 440 "${PASSWD_DENY}"

echo "✔ Password set for '${GNS3_USER}' and password changes denied."

#------------------------------------------------------------------------------
# STEP 7 — Enable SSH password authentication (drop-in)
#------------------------------------------------------------------------------
echo "[7/11] Enabling SSH password authentication..."

cat > "${SSH_DROPIN}" <<'EOF'
# Managed by 01-prepare-gns3-host.sh (NSCC lab kit)
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

systemctl restart ssh

#------------------------------------------------------------------------------
# STEP 8 — Install virtualization baseline
#------------------------------------------------------------------------------
echo "[8/11] Installing KVM/libvirt baseline..."

apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst cpu-checker

systemctl enable --now libvirtd

if getent group netdev >/dev/null 2>&1; then
  echo "✔ Group 'netdev' exists."
else
  groupadd -f netdev
  echo "✔ Created group 'netdev'."
fi

usermod -aG kvm,libvirt,netdev "${GNS3_USER}" || true

#------------------------------------------------------------------------------
# STEP 9 — Kernel modules + sysctl tuning
#------------------------------------------------------------------------------
echo "[9/11] Enabling kernel modules and sysctl settings..."

cat > /etc/modules-load.d/gns3.conf <<'EOF'
tun
br_netfilter
EOF

modprobe tun || true
modprobe br_netfilter || true

cat > /etc/sysctl.d/99-gns3.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
EOF

sysctl --system

#------------------------------------------------------------------------------
# STEP 10 — System limits + summary
#------------------------------------------------------------------------------
echo "[10/11] Setting limits and printing verification summary..."

cat > /etc/security/limits.d/99-gns3.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

echo ""
echo "Quick checks:"
echo " - timezone:           $(timedatectl show -p Timezone --value)"
echo " - ntp enabled:        $(timedatectl show -p NTP --value)"
echo " - ssh active:         $(systemctl is-active ssh || true)"
echo " - ssh pass auth:      $(sshd -T 2>/dev/null | awk '/passwordauthentication/{print $2; exit}' || echo 'unknown')"
echo " - libvirt active:     $(systemctl is-active libvirtd || true)"
echo " - gns3 user exists:   $(id -u "${GNS3_USER}" >/dev/null 2>&1 && echo yes || echo no)"
echo " - gns3 groups:        $(id -nG "${GNS3_USER}" 2>/dev/null || true)"
echo " - kvm device:         $(ls -l /dev/kvm 2>/dev/null || echo 'not found')"
echo " - passwd change deny: ${PASSWD_DENY}"
echo " - static netplan:     ${STATIC_NETPLAN_FILE}"
echo ""

echo "Done."
echo "Recommended next step: reboot now."
echo "Then run: 02-install-docker.sh"

#------------------------------------------------------------------------------
# STEP 11 — Extend root filesystem
#------------------------------------------------------------------------------
echo "[11/11] Extending root filesystem..."
# Extend the logical volume to use all free space
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
# Grow the filesystem
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv