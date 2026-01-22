#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      04-bridge-tap-provision.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Prompts for the physical NIC to attach to the bridge (shows available NICs)
#   - Uses 01's netplan (/etc/netplan/01-static-ip.yaml) as defaults:
#       NIC, IP/CIDR, gateway, DNS
#   - Writes netplan bridge config so:
#       * NIC has no IP
#       * br0 owns the static IP + default route + DNS
#   - Creates persistent TAPs (tap0/tap1) owned by gns3 and attaches to br0
#   - Installs a systemd oneshot service so TAPs exist after reboot
#
# Usage:
#   sudo bash 04-bridge-tap-provision.sh
#==============================================================================

set -euo pipefail

BR="br0"
GNS3_USER="gns3"
TAPS=("tap0" "tap1")

# IMPORTANT:
# We use the same file path as 01 so we can "pre-fill" values for students.
NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"
SYSTEMD_SERVICE="/etc/systemd/system/gns3-taps.service"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

backup_file_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

valid_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip="${cidr%/*}" maskbits="${cidr#*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$maskbits" -ge 0 && "$maskbits" -le 32 ]] || return 1
  return 0
}

list_nics() {
  ip -br link | awk '
    $1 !~ /^lo$/ &&
    $1 !~ /^(br|tap|tun|docker|veth|virbr|vnet|wg|zt|vxlan|gre|gretap|ip6gre|sit|dummy|bond|team)/ {
      print " - " $1
    }'
  echo ""
}

default_uplink_nic() {
  ip route show default 0.0.0.0/0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

prompt_with_default() {
  # prompt_with_default VAR "Prompt text" "DefaultValue"
  local __var="$1" __prompt="$2" __default="$3" __val=""
  if [[ -n "$__default" ]]; then
    read -rp "${__prompt} [${__default}]: " __val
    __val="${__val:-$__default}"
  else
    read -rp "${__prompt}: " __val
  fi
  # trim whitespace
  __val="${__val#"${__val%%[![:space:]]*}"}"
  __val="${__val%"${__val##*[![:space:]]}"}"
  printf -v "$__var" "%s" "$__val"
}

#------------------------------------------------------------------------------
# Parse defaults from 01 netplan file (best effort, no extra dependencies)
#------------------------------------------------------------------------------
read_defaults_from_netplan() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # Student note:
  # This is "lightweight parsing" of YAML. It's best-effort and relies on the
  # consistent format produced by our scripts (01 writes it predictably).
  DEFAULT_NIC="$(awk '
    $1=="ethernets:" {in_eth=1; next}
    in_eth && $1 ~ /^[a-zA-Z0-9._:-]+:$/ {gsub(":","",$1); print $1; exit}
  ' "$f" 2>/dev/null || true)"

  DEFAULT_ADDR="$(awk '
    $1=="addresses:" {in_addr=1; next}
    in_addr && $1=="-" {print $2; exit}
  ' "$f" 2>/dev/null || true)"

  DEFAULT_GW="$(awk '
    $1=="via:" {print $2; exit}
  ' "$f" 2>/dev/null || true)"

  # nameservers: addresses: [a, b] OR addresses: [a]
  DEFAULT_DNS_LIST="$(awk '
    $1=="addresses:" && $2 ~ /^\[/ {print $2; for(i=3;i<=NF;i++) print $i; exit}
  ' "$f" 2>/dev/null | tr -d '[],' | tr '\n' ' ' | xargs || true)"

  DEFAULT_DNS1="$(echo "${DEFAULT_DNS_LIST}" | awk '{print $1}')"
  DEFAULT_DNS2="$(echo "${DEFAULT_DNS_LIST}" | awk '{print $2}')"
}

# Globals filled by parser:
DEFAULT_NIC=""
DEFAULT_ADDR=""
DEFAULT_GW=""
DEFAULT_DNS1=""
DEFAULT_DNS2=""

echo "=============================="
echo " GNS3 Bridge + TAP Provision (Ubuntu 24.04)"
echo " Bridge: ${BR}"
echo " TAPs: ${TAPS[*]}  |  Owner: ${GNS3_USER}"
echo " Version: 1.0.0"
echo " Author: Davis Boudreau"
echo "=============================="

need_root

echo "[1/9] Validating prerequisites..."
id "${GNS3_USER}" >/dev/null 2>&1 || die "User '${GNS3_USER}' not found. Run 01-prepare-gns3-host.sh first."
command -v netplan >/dev/null 2>&1 || die "netplan not found."
command -v ip >/dev/null 2>&1 || die "ip command not found."

echo "[2/9] Loading defaults from ${NETPLAN_FILE} (if present)..."
read_defaults_from_netplan "${NETPLAN_FILE}" || true

echo ""
echo "Defaults detected from 01 (if available):"
echo " - NIC:     ${DEFAULT_NIC:-<none>}"
echo " - IP/CIDR: ${DEFAULT_ADDR:-<none>}"
echo " - GW:      ${DEFAULT_GW:-<none>}"
echo " - DNS1:    ${DEFAULT_DNS1:-<none>}"
echo " - DNS2:    ${DEFAULT_DNS2:-<none>}"
echo ""

echo "[3/9] Selecting the physical NIC to attach to ${BR}..."
echo "Available NICs:"
list_nics

GUESS="$(default_uplink_nic || true)"
if [[ -n "$GUESS" ]]; then
  echo "Detected uplink NIC (default route): $GUESS"
  echo ""
fi

# Choose default: prefer netplan's NIC, else default-route guess
NIC_DEFAULT="${DEFAULT_NIC:-$GUESS}"

while true; do
  prompt_with_default NIC "Enter NIC to attach to ${BR}" "${NIC_DEFAULT}"
  [[ -n "$NIC" ]] || { echo "Please enter a NIC name."; continue; }
  ip link show "$NIC" >/dev/null 2>&1 || { echo "Invalid NIC '$NIC'."; continue; }
  [[ "$NIC" != "$BR" ]] || { echo "NIC cannot be the bridge name (${BR})."; continue; }
  break
done
echo "✔ Selected NIC: ${NIC}"

echo "[4/9] Collecting static network settings for bridge ${BR}..."
echo ""
echo "Press Enter to accept defaults from 01 (recommended)."
echo ""

while true; do
  prompt_with_default BR_ADDR_CIDR "Bridge IP/CIDR (ex: 172.16.184.254/24)" "${DEFAULT_ADDR}"
  valid_cidr "${BR_ADDR_CIDR}" && break
  echo "  Invalid CIDR (expected x.x.x.x/yy). Try again."
done

while true; do
  prompt_with_default DEFAULT_GW "Default gateway (IPv4)" "${DEFAULT_GW}"
  valid_ipv4 "${DEFAULT_GW}" && break
  echo "  Invalid IPv4. Try again."
done

while true; do
  prompt_with_default DNS1 "DNS server #1 (IPv4)" "${DEFAULT_DNS1}"
  valid_ipv4 "${DNS1}" && break
  echo "  Invalid IPv4. Try again."
done

while true; do
  prompt_with_default DNS2 "DNS server #2 (IPv4)" "${DEFAULT_DNS2}"
  valid_ipv4 "${DNS2}" && break
  echo "  Invalid IPv4. Try again."
done

CURRENT_IPS="$(ip -4 -o addr show dev "${NIC}" | awk '{print $4}' | tr '\n' ' ')"
if [[ -n "${CURRENT_IPS// }" ]]; then
  echo ""
  echo "Note: ${NIC} currently has IPv4: ${CURRENT_IPS}"
  echo "      After applying netplan, ${NIC} will have NO IP. ${BR} will own the IP."
fi

echo ""
echo "Summary:"
echo " - NIC:       ${NIC}"
echo " - Bridge:    ${BR}"
echo " - IP/CIDR:   ${BR_ADDR_CIDR}"
echo " - Gateway:   ${DEFAULT_GW}"
echo " - DNS:       ${DNS1}, ${DNS2}"
echo " - TAPs:      ${TAPS[*]} (owner: ${GNS3_USER})"
echo ""

echo "[5/9] Writing netplan bridge configuration: ${NETPLAN_FILE}"
backup_file_if_exists "${NETPLAN_FILE}"

# Student note:
# We replace the old "NIC has IP" model with "bridge has IP".
# This is required so Linux bridge passes traffic between physical + tap ports.
cat > "${NETPLAN_FILE}" <<EOF
#------------------------------------------------------------------------------
# Generated by: 04-bridge-tap-provision.sh
# Version: 1.0.0 | Author: Davis Boudreau
#
# Goal:
#   - Physical NIC (${NIC}) is a bridge port (no IP)
#   - Bridge (${BR}) owns the static IP and default route
#   - DNS configured on bridge
#
# Renderer: systemd-networkd (recommended for Ubuntu Server)
#------------------------------------------------------------------------------

network:
  version: 2
  renderer: networkd

  ethernets:
    ${NIC}:
      dhcp4: false
      dhcp6: false

  bridges:
    ${BR}:
      interfaces: [${NIC}]
      dhcp4: false
      dhcp6: false
      addresses:
        - ${BR_ADDR_CIDR}
      routes:
        - to: default
          via: ${DEFAULT_GW}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
      parameters:
        stp: false
        forward-delay: 0
      optional: true
EOF

chmod 600 "${NETPLAN_FILE}"

echo "Validating netplan syntax..."
netplan generate

echo "[6/9] Applying netplan (network may briefly interrupt)..."
netplan apply

echo "[7/9] Creating persistent TAP systemd service: ${SYSTEMD_SERVICE}"
backup_file_if_exists "${SYSTEMD_SERVICE}"

cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Persistent TAP interfaces for GNS3 (${TAPS[0]}/${TAPS[1]}) attached to ${BR}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# Create TAPs owned by ${GNS3_USER}, then attach to bridge.
# Student note: "ip tuntap" creates kernel TAP interfaces; "master" attaches to bridge.
ExecStart=/usr/sbin/ip tuntap add dev ${TAPS[0]} mode tap user ${GNS3_USER}
ExecStart=/usr/sbin/ip tuntap add dev ${TAPS[1]} mode tap user ${GNS3_USER}
ExecStart=/usr/sbin/ip link set ${TAPS[0]} up
ExecStart=/usr/sbin/ip link set ${TAPS[1]} up
ExecStart=/usr/sbin/ip link set ${TAPS[0]} master ${BR}
ExecStart=/usr/sbin/ip link set ${TAPS[1]} master ${BR}

ExecStop=/usr/sbin/ip link set ${TAPS[0]} nomaster
ExecStop=/usr/sbin/ip link set ${TAPS[1]} nomaster
ExecStop=/usr/sbin/ip link del ${TAPS[0]}
ExecStop=/usr/sbin/ip link del ${TAPS[1]}

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${SYSTEMD_SERVICE}"

echo "[8/9] Enabling and starting TAP service..."
systemctl daemon-reload
systemctl enable --now gns3-taps.service

echo "[9/9] Verification summary..."
echo ""
echo "Quick checks:"
echo " - bridge link:        $(ip -br link show "${BR}" 2>/dev/null || echo 'not found')"
echo " - bridge address:     $(ip -br addr show "${BR}" 2>/dev/null || echo 'not found')"
echo " - tap0 link:          $(ip -br link show "${TAPS[0]}" 2>/dev/null || echo 'not found')"
echo " - tap1 link:          $(ip -br link show "${TAPS[1]}" 2>/dev/null || echo 'not found')"
echo " - tap service active: $(systemctl is-active gns3-taps.service || true)"
echo ""

echo "Bridge membership:"
if command -v brctl >/dev/null 2>&1; then
  brctl show "${BR}" || true
else
  echo " - brctl not installed; showing master relationships:"
  ip -d link show "${TAPS[0]}" | grep -E "master|${BR}" -n || true
  ip -d link show "${TAPS[1]}" | grep -E "master|${BR}" -n || true
fi

echo ""
echo "Service status:"
systemctl status gns3-taps.service --no-pager || true

echo ""
echo "Done."
echo "Recommended: reboot now (ensures clean boot + persistent TAP validation)."
echo ""
echo "After reboot:"
echo "  - Log in as: ${GNS3_USER}"
echo "  - In GNS3 GUI: add a Cloud node and bind to ${TAPS[0]} / ${TAPS[1]}"
echo ""
echo "Rollback hints (if connectivity is lost):"
echo "  - Restore a prior netplan backup:"
echo "      ls -1 ${NETPLAN_FILE}.bak.*"
echo "      sudo cp -a <backup_file> ${NETPLAN_FILE}"
echo "      sudo netplan apply"
echo ""