#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      03-install-gns3-server.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Installs GNS3 Server from the official GNS3 PPA on Ubuntu
#   - Installs ubridge and ensures gns3 user can run it
#   - Installs KVM/libvirt and console tools (VNC/SPICE)
#   - Writes an authoritative gns3_server.conf with explicit tool paths
#   - Installs and enables a locked systemd service for gns3server
#   - Performs a hard verification gate (fails if ubridge unusable)
#
# Usage:
#   sudo bash scripts/03-install-gns3-server.sh
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

GNS3_USER="${GNS3_USER:-gns3}"

SERVICE_DST="/etc/systemd/system/gns3server.service"
GNS3_CFG_DIR="/home/${GNS3_USER}/.config/GNS3/2.2"
GNS3_CFG_FILE="${GNS3_CFG_DIR}/gns3_server.conf"

need_root

init_logging
setup_traps
require_real_run
report_add "Script" "$(basename "$0")"
report_add "Service installed" "gns3server.service"
report_add "Config file" "/home/${GNS3_USER}/.config/GNS3/2.2/gns3_server.conf"
report_add "Reboot required" "YES"
echo "=============================="
echo " Installing GNS3 Server (Ubuntu 24.04)"
echo " Runtime user: ${GNS3_USER}"
echo " Version:      1.0.0"
echo " Author:       Davis Boudreau"
echo "=============================="

OS_ID="$(os_release_id)"
[[ "${OS_ID}" == "ubuntu" ]] || die "This script uses the Ubuntu GNS3 PPA and requires Ubuntu."

echo "[1/12] Verifying gns3 user exists..."
id "${GNS3_USER}" >/dev/null 2>&1 || die "User '${GNS3_USER}' not found. Run 01-prepare-gns3-host.sh first."

echo "[2/12] Checking for CPU virtualization support (KVM)..."
run apt-get update -y
run apt-get install -y cpu-checker

if ! kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
  echo "✖ KVM acceleration NOT available."
  kvm-ok || true
  exit 1
fi
echo "✔ KVM acceleration detected."

echo "[3/12] Verifying Docker installation..."
command -v docker >/dev/null 2>&1 || die "Docker not found. Run 02-install-docker.sh first."
run systemctl is-active --quiet docker || die "Docker service not running."

echo "[4/12] Installing base dependencies..."
run apt-get install -y software-properties-common ca-certificates curl gnupg lsb-release

echo "[5/12] Adding GNS3 official PPA (idempotent)..."
if ! grep -Rhs "ppa.launchpadcontent.net/gns3/ppa" /etc/apt/sources.list* >/dev/null 2>&1; then
  add-apt-repository -y ppa:gns3/ppa
fi
run apt-get update -y

echo "[6/12] Installing GNS3 Server and core components..."
run apt-get install -y \
  gns3-server ubridge \
  qemu-kvm libvirt-daemon-system libvirt-clients \
  bridge-utils \
  tigervnc-standalone-server tigervnc-common

run systemctl enable --now libvirtd

echo "[7/12] Installing VNC/SPICE console tools..."
run apt-get install -y \
  qemu-system-x86 qemu-utils \
  tigervnc-viewer spice-client-gtk virt-viewer

echo "[8/12] Adding '${GNS3_USER}' to required runtime groups..."
run usermod -aG kvm,libvirt,docker,ubridge "${GNS3_USER}"

echo "[9/12] Enforcing safe /dev/kvm permissions..."
write_file /etc/udev/rules.d/99-kvm.rules <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
run udevadm control --reload-rules
run udevadm trigger /dev/kvm || true

echo "[10/12] Writing authoritative GNS3 server configuration..."
UBRIDGE_PATH="$(command -v ubridge 2>/dev/null || true)"
QEMU_PATH="$(command -v qemu-system-x86_64 2>/dev/null || true)"
DYNAMIPS_PATH="$(command -v dynamips 2>/dev/null || true)"
[[ -x "${UBRIDGE_PATH}" ]] || die "ubridge not executable."

run sudo -u "${GNS3_USER}" -H mkdir -p "${GNS3_CFG_DIR}"

run sudo -u "${GNS3_USER}" -H bash -lc "cat > '${GNS3_CFG_FILE}' <<EOF
[Server]
ubridge_path = ${UBRIDGE_PATH}
qemu_path = ${QEMU_PATH}
dynamips_path = ${DYNAMIPS_PATH}

allow_console_from_anywhere = true
allow_remote_console = true

docker_enabled = true
local = true

maximum_projects = 0
maximum_nodes_per_project = 0
maximum_links_per_node = 0

log_level = INFO
EOF"

run chown -R "${GNS3_USER}:${GNS3_USER}" "/home/${GNS3_USER}/.config"

echo "[11/12] Installing systemd service for GNS3 Server..."
SRC_SERVICE="${SCRIPT_DIR}/../systemd/gns3server.service"
if [[ -f "${SRC_SERVICE}" ]]; then
  cp -a "${SRC_SERVICE}" "${SERVICE_DST}"
else
  die "Missing systemd unit template: ${SRC_SERVICE}"
fi

run systemctl daemon-reload
run systemctl enable --now gns3server
run systemctl restart gns3server

echo "[12/12] Final verification (hard gate)..."
run sudo -u "${GNS3_USER}" -H bash -lc "command -v ubridge >/dev/null" \
  || die "ubridge not found in PATH for gns3 user."

run sudo -u "${GNS3_USER}" -H bash -lc "ubridge -v >/dev/null" \
  || die "gns3 user cannot execute ubridge (group permissions issue)."

run systemctl is-active --quiet gns3server || die "gns3server service not active."

echo ""
echo "✔ GNS3 Server installation COMPLETE and VERIFIED"
echo ""
echo "IMPORTANT:"
echo "  - Reboot NOW to refresh group memberships"
echo "  - Then run: scripts/04-bridge-tap-provision.sh"
echo ""
