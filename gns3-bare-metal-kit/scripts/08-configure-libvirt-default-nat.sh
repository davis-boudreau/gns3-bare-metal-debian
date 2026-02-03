#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      08-configure-libvirt-default-nat.sh
# Version:     1.0.0
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
#   - Applies by defining a new persistent XML and restarting the network
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

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

need_root
init_logging
setup_traps
require_real_run

require_cmd virsh

NET_NAME="default"
BR_NAME="virbr0"

IP_ADDR="192.168.100.1"
NETMASK="255.255.255.0"
DHCP_START="192.168.100.129"
DHCP_END="192.168.100.190"

report_add "Script" "$(basename "$0")"
report_add "Libvirt network" "${NET_NAME}"
report_add "Bridge" "${BR_NAME}"
report_add "Address" "${IP_ADDR}"
report_add "Netmask" "${NETMASK}"
report_add "DHCP range" "${DHCP_START}-${DHCP_END}"
report_add "Reboot required" "NO"

echo "=============================="
echo " Configure Libvirt Default NAT (virbr0)"
echo " Network: ${NET_NAME}"
echo " Bridge : ${BR_NAME}"
echo " IP     : ${IP_ADDR}"
echo " Mask   : ${NETMASK} (/26)"
echo " DHCP   : ${DHCP_START} - ${DHCP_END}"
echo "=============================="

echo "[1/6] Checking libvirt network exists..."
if ! virsh net-info "${NET_NAME}" >/dev/null 2>&1; then
  die "Libvirt network '${NET_NAME}' not found. Is libvirt installed/enabled?"
fi

echo "[2/6] Backing up current network XML..."
BACKUP_DIR="/var/log/gns3-bare-metal/libvirt-backups"
run mkdir -p "${BACKUP_DIR}"
run chmod 750 "${BACKUP_DIR}" || true

TS="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_XML="${BACKUP_DIR}/${NET_NAME}-${TS}.xml"
run_bash "virsh net-dumpxml '${NET_NAME}' > '${BACKUP_XML}'"
echo "✔ Backup saved: ${BACKUP_XML}"

echo "[3/6] Writing desired network XML..."
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

echo "[4/6] Defining network from XML (persistent)..."
run virsh net-define "${TMP_XML}"

echo "[5/6] Restarting network to apply changes..."
if virsh net-info "${NET_NAME}" 2>/dev/null | grep -q "Active:.*yes"; then
  run virsh net-destroy "${NET_NAME}"
fi
run virsh net-start "${NET_NAME}"
run virsh net-autostart "${NET_NAME}"

echo "[6/6] Verifying applied configuration..."
APPLIED="$(virsh net-dumpxml "${NET_NAME}")"

echo "${APPLIED}" | grep -q "bridge name='${BR_NAME}'" || die "Bridge name not applied."
echo "${APPLIED}" | grep -q "ip address='${IP_ADDR}'" || die "IP address not applied."
echo "${APPLIED}" | grep -q "netmask='${NETMASK}'" || die "Netmask not applied."
echo "${APPLIED}" | grep -q "range start='${DHCP_START}'" || die "DHCP start not applied."
echo "${APPLIED}" | grep -q "end='${DHCP_END}'" || die "DHCP end not applied."

echo ""
echo "✔ Libvirt default NAT network updated successfully."
echo ""
echo "Inspect dnsmasq (optional):"
echo "  sudo cat /var/lib/libvirt/dnsmasq/default.conf"
echo ""
