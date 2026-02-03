#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      08-configure-libvirt-default-nat.sh
# Version:     1.1.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Reconfigures the libvirt "default" NAT network (virbr0) to a deterministic /26
#   - Sets:
#       IP      = 192.168.100.1
#       Netmask = 255.255.255.192  (/26)
#       DHCP    = 192.168.100.33 - 192.168.100.62
#   - Replaces the existing persistent libvirt network definition safely:
#       destroy (if active) -> undefine -> define -> start -> autostart
#   - Creates a timestamped backup of the previous XML
#
# IMPORTANT:
#   - Restarting the libvirt default network may disrupt running VMs briefly.
#   - Run during provisioning (before students build labs).
#
# Usage:
#   sudo bash scripts/08-configure-libvirt-default-nat.sh
#   sudo bash scripts/08-configure-libvirt-default-nat.sh --dry-run
#==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

need_root
init_logging
setup_traps
require_real_run

require_cmd virsh
require_cmd awk
require_cmd grep
require_cmd date

# -----------------------------
# Desired network configuration
# -----------------------------
NET_NAME="default"
BR_NAME="virbr0"

IP_ADDR="192.168.100.1"
NETMASK="255.255.255.0"     # /24
DHCP_START="192.168.100.129"
DHCP_END="192.168.100.190"

# -----------------------------
# Report header
# -----------------------------
report_add "Script" "$(basename "$0")"
report_add "Libvirt network" "${NET_NAME}"
report_add "Bridge" "${BR_NAME}"
report_add "Address" "${IP_ADDR}"
report_add "Netmask" "${NETMASK} (/24)"
report_add "DHCP range" "${DHCP_START}-${DHCP_END}"
report_add "Reboot required" "NO"

echo "=============================="
echo " Configure Libvirt Default NAT (virbr0)"
echo " Network: ${NET_NAME}"
echo " Bridge : ${BR_NAME}"
echo " IP     : ${IP_ADDR}"
echo " Mask   : ${NETMASK} (/24)"
echo " DHCP   : ${DHCP_START} - ${DHCP_END}"
echo "=============================="

# -----------------------------
# Helpers
# -----------------------------
net_is_active() {
  virsh net-info "${NET_NAME}" 2>/dev/null | awk -F': *' '/^Active:/ {print $2}' | grep -qi '^yes$'
}

net_is_autostart() {
  virsh net-info "${NET_NAME}" 2>/dev/null | awk -F': *' '/^Autostart:/ {print $2}' | grep -qi '^yes$'
}

# Best-effort: list VM names that have an interface connected to the given libvirt network.
# If virsh domiflist isn't supported/available for some reason, return empty.
vms_using_network() {
  local dom
  local out=""
  while IFS= read -r dom; do
    [[ -z "${dom}" ]] && continue
    # domiflist output has a "Source" column containing the network name for type=network
    if virsh domiflist "${dom}" 2>/dev/null | awk '{print $3}' | grep -qx "${NET_NAME}"; then
      out+="${dom}"$'\n'
    fi
  done < <(virsh list --all --name 2>/dev/null || true)

  printf '%s' "${out}" | sed '/^$/d' || true
}

# -----------------------------
# [1/7] Ensure network exists
# -----------------------------
echo "[1/7] Checking libvirt network exists..."
if ! virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
  die "Libvirt network '${NET_NAME}' not found. Is libvirt installed/enabled?"
fi

# -----------------------------
# [2/7] Warn if VMs appear attached
# -----------------------------
echo "[2/7] Checking for VMs attached to '${NET_NAME}' (informational)..."
USERS="$(vms_using_network || true)"
if [[ -n "${USERS}" ]]; then
  echo "⚠ Detected VMs that appear to reference network '${NET_NAME}':"
  echo "${USERS}" | sed 's/^/  - /'
  echo "⚠ Restarting '${NET_NAME}' may briefly disrupt these VMs."
else
  echo "✔ No attached VMs detected (or unable to detect)."
fi

# -----------------------------
# [3/7] Backup current XML
# -----------------------------
echo "[3/7] Backing up current network XML..."
BACKUP_DIR="/var/log/gns3-bare-metal/libvirt-backups"
run mkdir -p "${BACKUP_DIR}"
run chmod 750 "${BACKUP_DIR}" || true

TS="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_XML="${BACKUP_DIR}/${NET_NAME}-${TS}.xml"
run_bash "virsh net-dumpxml '${NET_NAME}' > '${BACKUP_XML}'"
echo "✔ Backup saved: ${BACKUP_XML}"

# Remember prior autostart state to preserve it.
WAS_AUTOSTART="no"
if net_is_autostart; then
  WAS_AUTOSTART="yes"
fi
echo "ℹ Autostart before change: ${WAS_AUTOSTART}"

# -----------------------------
# [4/7] Write desired XML
# -----------------------------
echo "[4/7] Writing desired network XML..."
TMP_XML="/tmp/${NET_NAME}-desired.xml"

write_file "${TMP_XML}" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BR_NAME}' stp='on' delay='0'/>
  <ip address='${IP_ADDR}' netmask='${NETMASK}'>
    <dhcp>
      <range start='${DHCP_START}' end='${DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF

echo "✔ Desired XML written: ${TMP_XML}"

# -----------------------------
# [5/7] Replace network definition (safe pattern)
# -----------------------------
echo "[5/7] Replacing existing network definition..."
if net_is_active; then
  echo " - Network is active; stopping it..."
  run virsh net-destroy "${NET_NAME}"
else
  echo " - Network is not active; no stop needed."
fi

echo " - Undefining existing persistent network..."
# If undefine fails for any reason, we want a clear message rather than a confusing net-define collision.
if ! run virsh net-undefine "${NET_NAME}"; then
  die "Failed to undefine '${NET_NAME}'. Ensure no policy/lock prevents changing libvirt networks."
fi

echo " - Defining desired XML (persistent)..."
run virsh net-define "${TMP_XML}"

# -----------------------------
# [6/7] Start + restore autostart state
# -----------------------------
echo "[6/7] Starting network to apply changes..."
run virsh net-start "${NET_NAME}"

if [[ "${WAS_AUTOSTART}" == "yes" ]]; then
  run virsh net-autostart "${NET_NAME}"
else
  # Make the resulting state explicit (some systems default to autostart on 'default').
  run virsh net-autostart --disable "${NET_NAME}" || true
fi

# -----------------------------
# [7/7] Verify applied configuration
# -----------------------------
echo "[7/7] Verifying applied configuration..."
APPLIED="$(virsh net-dumpxml "${NET_NAME}")"

echo "${APPLIED}" | grep -q "bridge name='${BR_NAME}'" || die "Bridge name not applied."
echo "${APPLIED}" | grep -q "ip address='${IP_ADDR}'" || die "IP address not applied."
echo "${APPLIED}" | grep -q "netmask='${NETMASK}'" || die "Netmask not applied."
echo "${APPLIED}" | grep -q "range start='${DHCP_START}'" || die "DHCP start not applied."
echo "${APPLIED}" | grep -q "end='${DHCP_END}'" || die "DHCP end not applied."

# Optional: show net-info after change
echo ""
echo "✔ Libvirt '${NET_NAME}' NAT network updated successfully."
echo ""
echo "Current status:"
virsh net-info "${NET_NAME}" || true
echo ""
echo "Inspect dnsmasq (optional):"
echo "  sudo cat /var/lib/libvirt/dnsmasq/${NET_NAME}.conf"
echo ""
report_add "Result" "Libvirt '${NET_NAME}' NAT network updated successfully"
report_add "Backup XML" "${BACKUP_XML}"