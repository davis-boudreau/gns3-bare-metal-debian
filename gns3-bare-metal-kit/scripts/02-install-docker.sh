#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      02-install-docker.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Installs Docker CE from Docker's official apt repository
#   - Removes conflicting legacy packages (best-effort)
#   - Enables Docker service
#   - Adds user 'gns3' to docker group (so docker works without sudo)
#
# Supported:
#   - Ubuntu (primary)
#   - Debian (Docker install only; other scripts remain Ubuntu-first)
#
# Usage:
#   sudo bash scripts/02-install-docker.sh
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

GNS3_USER="${GNS3_USER:-gns3}"

need_root

init_logging
setup_traps
report_add "Script" "$(basename "$0")"
report_add "Docker service" "docker"
report_add "Reboot required" "YES"
echo "=============================="
echo " Installing Docker CE for GNS3"
echo " Runtime user: ${GNS3_USER}"
echo " Version:      1.0.0"
echo " Author:       Davis Boudreau"
echo "=============================="

echo "[1/6] Verifying user '${GNS3_USER}' exists..."
id "${GNS3_USER}" >/dev/null 2>&1 || die "User '${GNS3_USER}' not found. Run 01-prepare-gns3-host.sh first."

echo "[2/6] Removing old/conflicting container packages (best effort)..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "${pkg}" >/dev/null 2>&1 || true
done

echo "[3/6] Adding Docker official repository..."
run install -m 0755 -d /etc/apt/keyrings

OS_ID="$(os_release_id)"
CODENAME="$(os_release_codename)"

case "${OS_ID}" in
  ubuntu) DOCKER_DISTRO="ubuntu" ;;
  debian) DOCKER_DISTRO="debian" ;;
  *) die "Unsupported distro ID='${OS_ID}'. Supported for Docker: ubuntu, debian." ;;
esac

if [[ -z "${CODENAME}" ]]; then
  die "Could not detect VERSION_CODENAME from /etc/os-release."
fi

if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "✔ Docker GPG key installed."
else
  echo "✔ Docker GPG key already present."
fi

DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
write_file "${DOCKER_LIST}" <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable
EOF

run apt-get update -y

echo "[4/6] Installing Docker Engine (CE)..."
run apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

echo "[5/6] Enabling Docker service and configuring user access..."
run systemctl enable --now docker
run usermod -aG docker "${GNS3_USER}" || true

echo "[6/6] Verification summary..."
echo ""
echo "Quick checks:"
echo " - docker binary:      $(command -v docker || echo 'not found')"
echo " - docker version:     $(docker --version 2>/dev/null || true)"
echo " - docker active:      $(systemctl is-active docker || true)"
echo " - gns3 in docker grp: $(id -nG "${GNS3_USER}" | tr ' ' '\n' | grep -qx docker && echo yes || echo no)"
echo ""
echo "Done."
echo "IMPORTANT: reboot (or log out/in) so '${GNS3_USER}' gains docker group permissions."
echo "Next: run scripts/03-install-gns3-server.sh"
