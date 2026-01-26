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
#   - Uses 01's netplan (/etc/netplan/01-static-ip.yaml) as defaults (best effort)
#   - Writes netplan bridge config so:
#       * NIC has no IP
#       * br0 owns the static IP + default route + DNS
#   - Installs a systemd oneshot service so TAPs exist after reboot
#
# Usage:
#   sudo bash scripts/04-bridge-tap-provision.sh
#
# Environment overrides:
#   BR=br0
#   GNS3_USER=gns3
#   TAP0=tap0
#   TAP1=tap1
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

BR="${BR:-br0}"
GNS3_USER="${GNS3_USER:-gns3}"
TAP0="${TAP0:-tap0}"
TAP1="${TAP1:-tap1}"

NETPLAN_FILE="/etc/netplan/01-static-ip.yaml"
SYSTEMD_DST="/etc/systemd/system/gns3-taps.service"

need_root
init_logging
setup_traps
require_real_run
report_add "Script" "$(basename "$0")"
report_add "Bridge" "${BR}"
report_add "TAPs" "${TAP0},${TAP1}"
report_add "Netplan file" "${NETPLAN_FILE}"
report_add "Service installed" "gns3-taps.service"
report_add "Reboot required" "YES"
require_cmd netplan
require_cmd ip

echo "=============================="
echo " GNS3 Bridge + TAP Provision (Ubuntu 24.04)"
echo " Bridge: ${BR}"
echo " TAPs:   ${TAP0} ${TAP1}  |  Owner: ${GNS3_USER}"
echo " Version: 1.0.0"
echo " Author: Davis Boudreau"
echo "=============================="

#------------------------------------------------------------------------------
# Parse defaults from 01 netplan file (best effort)
#------------------------------------------------------------------------------
DEFAULT_NIC=""
DEFAULT_ADDR=""
DEFAULT_GW=""
DEFAULT_DNS1=""
DEFAULT_DNS2=""

read_defaults_from_netplan() {
  local f="$1"
  [[ -f "$f" ]] || return 0

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

  DEFAULT_DNS_LIST="$(awk '
    $1=="addresses:" && $2 ~ /^\[/ {print $2; for(i=3;i<=NF;i++) print $i; exit}
  ' "$f" 2>/dev/null | tr -d '[],' | tr '\n' ' ' | xargs || true)"

  DEFAULT_DNS1="$(echo "${DEFAULT_DNS_LIST}" | awk '{print $1}')"
  DEFAULT_DNS2="$(echo "${DEFAULT_DNS_LIST}" | awk '{print $2}')"
}

valid_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip="${cidr%/*}" maskbits="${cidr#*/}"
  is_ipv4 "$ip" || return 1
  [[ "$maskbits" -ge 0 && "$maskbits" -le 32 ]] || return 1
  return 0
}

echo "[1/8] Validating prerequisites..."
id "${GNS3_USER}" >/dev/null 2>&1 || die "User '${GNS3_USER}' not found. Run 01-prepare-gns3-host.sh first."

echo "[2/8] Loading defaults from ${NETPLAN_FILE} (if present)..."
read_defaults_from_netplan "${NETPLAN_FILE}" || true

echo ""
echo "Defaults detected from 01 (if available):"
echo " - NIC:     ${DEFAULT_NIC:-<none>}"
echo " - IP/CIDR: ${DEFAULT_ADDR:-<none>}"
echo " - GW:      ${DEFAULT_GW:-<none>}"
echo " - DNS1:    ${DEFAULT_DNS1:-<none>}"
echo " - DNS2:    ${DEFAULT_DNS2:-<none>}"
echo ""

echo "[3/8] Selecting the physical NIC to attach to ${BR}..."
echo "Available NICs:"
list_nics

GUESS="$(default_uplink_nic || true)"
if [[ -n "$GUESS" ]]; then
  echo "Detected uplink NIC (default route): $GUESS"
  echo ""
fi

NIC_DEFAULT="${DEFAULT_NIC:-$GUESS}"

while true; do
  prompt_with_default NIC "Enter NIC to attach to ${BR}" "${NIC_DEFAULT}"
  [[ -n "$NIC" ]] || { echo "Please enter a NIC name."; continue; }
  ip link show "$NIC" >/dev/null 2>&1 || { echo "Invalid NIC '$NIC'."; continue; }
  [[ "$NIC" != "$BR" ]] || { echo "NIC cannot be the bridge name (${BR})."; continue; }
  break
done
echo "✔ Selected NIC: ${NIC}"

echo "[4/8] Collecting static network settings for bridge ${BR}..."
echo "Press Enter to accept defaults from 01 (recommended)."
echo ""

while true; do
  prompt_with_default BR_ADDR_CIDR "Bridge IP/CIDR (ex: 172.16.184.254/24)" "${DEFAULT_ADDR}"
  valid_cidr "${BR_ADDR_CIDR}" && break
  echo "  Invalid CIDR (expected x.x.x.x/yy). Try again."
done

while true; do
  prompt_with_default GW "Default gateway (IPv4)" "${DEFAULT_GW}"
  is_ipv4 "${GW}" && break
  echo "  Invalid IPv4. Try again."
done

while true; do
  prompt_with_default DNS1 "DNS server #1 (IPv4)" "${DEFAULT_DNS1}"
  is_ipv4 "${DNS1}" && break
  echo "  Invalid IPv4. Try again."
done

prompt_with_default DNS2 "DNS server #2 (optional, Enter to skip)" "${DEFAULT_DNS2}"
if [[ -n "$DNS2" ]] && ! is_ipv4 "${DNS2}"; then
  die "Invalid IPv4 for DNS2."
fi

if [[ -n "$DNS2" ]]; then
  DNS_YAML="[${DNS1}, ${DNS2}]"
else
  DNS_YAML="[${DNS1}]"
fi

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
echo " - Gateway:   ${GW}"
echo " - DNS:       ${DNS_YAML}"
echo " - TAPs:      ${TAP0}, ${TAP1} (owner: ${GNS3_USER})"
echo ""

echo "[5/8] Writing netplan bridge configuration: ${NETPLAN_FILE}"
backup_if_exists "${NETPLAN_FILE}"

write_file "${NETPLAN_FILE}" <<EOF
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
          via: ${GW}
      nameservers:
        addresses: ${DNS_YAML}
      parameters:
        stp: false
        forward-delay: 0
      optional: true
EOF

run chmod 600 "${NETPLAN_FILE}"

echo "Validating netplan syntax..."
run netplan generate

echo "[6/8] Applying netplan (network may briefly interrupt)..."
run netplan apply

echo "[7/8] Installing persistent TAP systemd service..."
SRC_SERVICE="${SCRIPT_DIR}/../systemd/gns3-taps.service"
if [[ -f "${SRC_SERVICE}" ]]; then
  cp -a "${SRC_SERVICE}" "${SYSTEMD_DST}"
else
  die "Missing systemd unit template: ${SRC_SERVICE}"
fi

# Patch service file with runtime values (bridge/user/tap names)
# Safe token replacements:
run sed -i \
  -e "s/User=gns3/User=${GNS3_USER}/g" \
  -e "s/Group=gns3/Group=${GNS3_USER}/g" \
  -e "s/tap0/${TAP0}/g" \
  -e "s/tap1/${TAP1}/g" \
  -e "s/br0/${BR}/g" \
  "${SYSTEMD_DST}"

run chmod 644 "${SYSTEMD_DST}"

run systemctl daemon-reload
run systemctl enable --now gns3-taps.service

echo "[8/8] Verification summary..."
echo ""
echo "Quick checks:"
echo " - bridge link:        $(ip -br link show "${BR}" 2>/dev/null || echo 'not found')"
echo " - bridge address:     $(ip -br addr show "${BR}" 2>/dev/null || echo 'not found')"
echo " - tap0 link:          $(ip -br link show "${TAP0}" 2>/dev/null || echo 'not found')"
echo " - tap1 link:          $(ip -br link show "${TAP1}" 2>/dev/null || echo 'not found')"
echo " - tap service active: $(systemctl is-active gns3-taps.service || true)"
echo ""

echo "Bridge membership:"
if command -v brctl >/dev/null 2>&1; then
  brctl show "${BR}" || true
else
  echo " - brctl not installed; showing master relationships:"
  ip -d link show "${TAP0}" | grep -E "master|${BR}" -n || true
  ip -d link show "${TAP1}" | grep -E "master|${BR}" -n || true
fi

echo ""
echo "Service status:"
run systemctl status gns3-taps.service --no-pager || true

echo ""
echo "Done."
echo "Recommended: reboot now (ensures clean boot + persistent TAP validation)."
echo ""
echo "After reboot:"
echo "  - Log in as: ${GNS3_USER}"
echo "  - In GNS3 GUI: add a Cloud node and bind to ${TAP0} / ${TAP1}"
echo ""
