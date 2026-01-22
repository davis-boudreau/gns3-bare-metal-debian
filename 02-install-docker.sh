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
# Usage:
#   sudo bash 02-install-docker.sh
#==============================================================================

# SPDX-License-Identifier: MIT
set -euo pipefail

GNS3_USER="gns3"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

echo "=============================="
echo " Installing Docker CE (Ubuntu 24.04) for GNS3"
echo " Runtime user: ${GNS3_USER}"
echo " Version: 1.0.0"
echo " Author: Davis Boudreau"
echo "=============================="

need_root

echo "[1/6] Verifying user '${GNS3_USER}' exists..."
id "${GNS3_USER}" >/dev/null 2>&1 || die "User '${GNS3_USER}' not found. Run 01-prepare-gns3-host.sh first."

echo "[2/6] Removing old/conflicting container packages (best effort)..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "${pkg}" >/dev/null 2>&1 || true
done

echo "[3/6] Adding Docker official repository..."
install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "✔ Docker GPG key installed."
else
  echo "✔ Docker GPG key already present."
fi

DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

# Student note:
# This writes the repository entry in the modern "signed-by=..." style.
cat > "${DOCKER_LIST}" <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update -y

echo "[4/6] Installing Docker Engine (CE)..."
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

echo "[5/6] Enabling Docker service and configuring user access..."
systemctl enable --now docker
usermod -aG docker "${GNS3_USER}" || true

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
echo "Next: run 03-install-gns3-server.sh"