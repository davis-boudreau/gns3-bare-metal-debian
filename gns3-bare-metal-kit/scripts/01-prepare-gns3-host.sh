#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      01-prepare-gns3-host.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Prompts for a primary NIC and provisions a STATIC IPv4 using Netplan
#   - Sets timezone to America/Halifax and enables NTP
#   - Updates packages and installs common network/admin utilities
#   - Installs and enables OpenSSH Server (lab-friendly defaults)
#   - Creates a dedicated runtime user: gns3 (optional passwordless sudo)
#   - Optionally sets a password for gns3 (prompt or env var)
#   - Installs KVM/libvirt baseline (virtualization readiness)
#   - Loads tun/br_netfilter modules and applies sysctl networking tuning
#   - Raises file descriptor limits for large labs
#
# Usage:
#   sudo bash scripts/01-prepare-gns3-host.sh
#
# Environment overrides:
#   GNS3_USER=gns3
#   TZ=America/Halifax
#   LAB_ENABLE_PASSWORD_SSH=yes|no      (default: yes)
#   GNS3_USER_PASSWORD=<string>         (if omitted, you will be prompted)
#   LAB_PASSWORDLESS_SUDO=yes|no         (default: yes)
#   NETPLAN_MODE=apply|try              (default: apply)
#   NETPLAN_TRY_TIMEOUT=120             (seconds, only for try)
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

GNS3_USER="${GNS3_USER:-gns3}"
TZ="${TZ:-America/Halifax}"

LAB_ENABLE_PASSWORD_SSH="${LAB_ENABLE_PASSWORD_SSH:-yes}"
LAB_PASSWORDLESS_SUDO="${LAB_PASSWORDLESS_SUDO:-yes}"

NETPLAN_MODE="${NETPLAN_MODE:-apply}"           # apply|try
NETPLAN_TRY_TIMEOUT="${NETPLAN_TRY_TIMEOUT:-120}"

SSH_DROPIN="/etc/ssh/sshd_config.d/99-gns3-lab.conf"
STATIC_NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"

need_root

init_logging
setup_traps
require_real_run
report_add "Script" "$(basename "$0")"
report_add "Netplan file" "/etc/netplan/01-static-ip.yaml"
report_add "SSH drop-in" "/etc/ssh/sshd_config.d/99-gns3-lab.conf"
report_add "Reboot required" "YES"
echo "=============================="
echo " GNS3 Host Pre-Req Setup (Ubuntu 24.04)"
echo " Runtime user: ${GNS3_USER}"
echo " Timezone:     ${TZ}"
echo " Version:      1.0.0"
echo " Author:       Davis Boudreau"
echo "=============================="

# Basic guardrails
require_cmd apt-get
require_cmd ip

OS_ID="$(os_release_id)"
if [[ "${OS_ID}" != "ubuntu" ]]; then
  echo "⚠ WARNING: Detected OS ID='${OS_ID}'. This script assumes Ubuntu + Netplan defaults."
  echo "           Proceeding only if netplan is present."
fi

#------------------------------------------------------------------------------
# STEP 1 — Static IPv4 Provisioning (SSH-safe)
#------------------------------------------------------------------------------
echo "[1/11] Provisioning static IPv4 (Netplan)..."

run apt-get update -y
run apt-get install -y netplan.io iproute2 iputils-ping

require_cmd netplan

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
    prompt_with_default NIC "Enter primary NIC name" "$GUESS"
  else
    prompt_with_default NIC "Enter primary NIC name" ""
  fi

  [[ -n "$NIC" ]] || { echo "Please enter a NIC name."; continue; }
  ip link show "$NIC" >/dev/null 2>&1 && break
  echo "Invalid NIC '$NIC'. Check with: ip -br link"
done

while true; do
  prompt_with_default IP_ADDR "IPv4 Address (ex: 172.16.184.10)" ""
  is_ipv4 "$IP_ADDR" && break
  echo "Invalid IPv4 format."
done

while true; do
  prompt_with_default CIDR "CIDR Prefix (ex: 24)" "24"
  [[ "$CIDR" =~ ^[0-9]+$ && "$CIDR" -ge 8 && "$CIDR" -le 30 ]] && break
  echo "CIDR must be between 8 and 30."
done

while true; do
  prompt_with_default GATEWAY "Default Gateway (ex: 172.16.184.250)" ""
  is_ipv4 "$GATEWAY" && break
  echo "Invalid gateway IPv4."
done

while true; do
  prompt_with_default DNS1 "DNS Server 1 (required, ex: 8.8.8.8)" ""
  is_ipv4 "$DNS1" && break
  echo "Invalid DNS IPv4."
done

prompt_with_default DNS2 "DNS Server 2 (optional, Enter to skip)" ""
DNS_LIST=("$DNS1")
if [[ -n "$DNS2" ]]; then
  if is_ipv4 "$DNS2"; then
    DNS_LIST+=("$DNS2")
  else
    echo "⚠ DNS2 is invalid, ignoring."
  fi
fi

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

write_file "${STATIC_NETPLAN_FILE}" <<EOF
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

echo "Validating netplan..."
run netplan generate

echo "Applying netplan (mode=${NETPLAN_MODE})..."
if [[ "${NETPLAN_MODE}" == "try" ]]; then
  echo "⚠ netplan try will rollback unless you confirm on console."
  netplan try --timeout "${NETPLAN_TRY_TIMEOUT}" || die "netplan try failed."
else
  netplan apply
fi

echo "Verification:"
ip -br addr show "${NIC}" || true
ip route | head -n 5 || true

echo "✔ Static IPv4 applied. You should be able to SSH using:"
echo "  ssh ${GNS3_USER}@${IP_ADDR}"
echo ""

#------------------------------------------------------------------------------
# STEP 2 — Timezone + NTP
#------------------------------------------------------------------------------
echo "[2/11] Configuring timezone and NTP..."
require_cmd timedatectl
run timedatectl set-timezone "${TZ}"
run timedatectl set-ntp true
run timedatectl status || true

#------------------------------------------------------------------------------
# STEP 3 — Update OS packages
#------------------------------------------------------------------------------
echo "[3/11] Updating system packages..."
run apt-get update -y
run apt-get upgrade -y

#------------------------------------------------------------------------------
# STEP 4 — Base utilities
#------------------------------------------------------------------------------
echo "[4/11] Installing base utilities..."
run apt-get install -y \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  apt-transport-https net-tools iproute2 iputils-ping tcpdump traceroute \
  vim nano htop bridge-utils

#------------------------------------------------------------------------------
# STEP 5 — OpenSSH Server
#------------------------------------------------------------------------------
echo "[5/11] Installing and enabling OpenSSH server..."
run apt-get install -y openssh-server
run systemctl enable --now ssh
run systemctl status ssh --no-pager || true

#------------------------------------------------------------------------------
# STEP 6 — Create dedicated gns3 user
#------------------------------------------------------------------------------
echo "[6/11] Ensuring user '${GNS3_USER}' exists..."
if id "${GNS3_USER}" >/dev/null 2>&1; then
  echo "✔ User '${GNS3_USER}' already exists."
else
  useradd -m -s /bin/bash "${GNS3_USER}"
  echo "✔ Created user '${GNS3_USER}'."
fi

if [[ "${LAB_PASSWORDLESS_SUDO}" == "yes" ]]; then
  if [[ ! -f "/etc/sudoers.d/${GNS3_USER}" ]]; then
    echo "${GNS3_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${GNS3_USER}"
    chmod 440 "/etc/sudoers.d/${GNS3_USER}"
    echo "✔ Configured passwordless sudo for '${GNS3_USER}' (lab mode)."
  else
    echo "✔ Sudoers file already present for '${GNS3_USER}'."
  fi
else
  echo "ℹ Passwordless sudo disabled (LAB_PASSWORDLESS_SUDO=no)."
fi

#------------------------------------------------------------------------------
# STEP 7 — Set SSH password for gns3 user (optional)
#------------------------------------------------------------------------------
echo "[7/11] Configuring password for '${GNS3_USER}' (optional)..."
GNS3_USER_PASSWORD="${GNS3_USER_PASSWORD:-}"

if [[ "${LAB_ENABLE_PASSWORD_SSH}" == "yes" ]]; then
  if [[ -z "${GNS3_USER_PASSWORD}" ]]; then
    read -rsp "Set password for '${GNS3_USER}' (lab use): " GNS3_USER_PASSWORD
    echo ""
  fi
  echo "${GNS3_USER}:${GNS3_USER_PASSWORD}" | chpasswd
  echo "✔ Password set for '${GNS3_USER}'."
else
  echo "ℹ LAB_ENABLE_PASSWORD_SSH=no; skipping password set."
fi

#------------------------------------------------------------------------------
# STEP 8 — SSH password authentication (drop-in)
#------------------------------------------------------------------------------
echo "[8/11] Writing SSH lab drop-in..."
if [[ "${LAB_ENABLE_PASSWORD_SSH}" == "yes" ]]; then
  cat > "${SSH_DROPIN}" <<'EOF'
# Managed by 01-prepare-gns3-host.sh (lab kit)
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
else
  cat > "${SSH_DROPIN}" <<'EOF'
# Managed by 01-prepare-gns3-host.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
fi
run systemctl restart ssh

#------------------------------------------------------------------------------
# STEP 9 — Install virtualization baseline
#------------------------------------------------------------------------------
echo "[9/11] Installing KVM/libvirt baseline..."
run apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst cpu-checker

run systemctl enable --now libvirtd

run groupadd -f netdev
run usermod -aG kvm,libvirt,netdev "${GNS3_USER}" || true

#------------------------------------------------------------------------------
# STEP 10 — Kernel modules + sysctl tuning
#------------------------------------------------------------------------------
echo "[10/11] Enabling kernel modules and sysctl settings..."

write_file /etc/modules-load.d/gns3.conf <<'EOF'
tun
br_netfilter
EOF

run modprobe tun || true
run modprobe br_netfilter || true

write_file /etc/sysctl.d/99-gns3.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
EOF

sysctl --system

write_file /etc/security/limits.d/99-gns3.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

#------------------------------------------------------------------------------
# STEP 11 — Summary
#------------------------------------------------------------------------------
echo "[11/11] Verification summary..."
echo ""
echo "Quick checks:"
echo " - timezone:           $(timedatectl show -p Timezone --value)"
echo " - ntp enabled:        $(timedatectl show -p NTP --value)"
echo " - ssh active:         $(systemctl is-active ssh || true)"
echo " - ssh pass auth:      $(sshd -T 2>/dev/null | awk '/passwordauthentication/{print $2; exit}' || echo 'unknown')"
echo " - libvirt active:     $(systemctl is-active libvirtd || true)"
echo " - gns3 user exists:   $(id -u "${GNS3_USER}" >/dev/null 2>&1 && echo yes || echo no)"
echo " - gns3 groups:        $(id -nG "${GNS3_USER}" 2>/dev/null || true)"
echo " - static netplan:     ${STATIC_NETPLAN_FILE}"
echo ""
echo "Done."
echo "Recommended next step: reboot now."
echo "Then run: scripts/02-install-docker.sh"
