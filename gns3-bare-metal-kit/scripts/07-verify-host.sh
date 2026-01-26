#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      07-verify-host.sh
# Version:     1.0.2
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Purpose:
#   Non-mutating health checks to confirm the host is "READY" for GNS3 labs.
#
# Checks:
#   - KVM availability (/dev/kvm + kvm-ok)
#   - Docker installed + service active
#   - gns3server systemd service active
#   - gns3-taps systemd service active
#   - Bridge (br0 by default) exists and has an IPv4
#   - TAPs (tap0/tap1 by default) exist, are UP, and are attached to bridge
#   - ubridge is executable for gns3 user
#
# Usage:
#   sudo bash scripts/07-verify-host.sh
#   sudo bash scripts/07-verify-host.sh --log-dir /tmp
#
# Notes:
#   - This script does NOT change system state.
#   - Exit code:
#       0 = READY
#       1 = NOT READY (one or more critical checks failed)
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_flags "$@"

# This is a verify script; DRY_RUN doesn't change anything but we keep it supported.
need_root
init_logging
setup_traps
report_add "Script" "$(basename "$0")"
report_add "Mode" "VERIFY (non-mutating)"

BR="${BR:-br0}"
TAP0="${TAP0:-tap0}"
TAP1="${TAP1:-tap1}"
GNS3_USER="${GNS3_USER:-gns3}"

FAILS=0
WARNS=0

ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; WARNS=$((WARNS+1)); }
fail() { echo "❌ $*"; FAILS=$((FAILS+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  echo ""
  echo "------------------------------------------------------------"
  echo "$*"
  echo "------------------------------------------------------------"
}

report_add "Bridge" "${BR}"
report_add "TAPs" "${TAP0},${TAP1}"
report_add "User" "${GNS3_USER}"

section "System"
echo "Hostname:  $(hostname)"
echo "Kernel:    $(uname -r)"
echo "OS:        $(. /etc/os-release && echo "${PRETTY_NAME}")"
echo "Uptime:    $(uptime -p 2>/dev/null || true)"
echo "Time:      $(date)"
echo "IP (best): $(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo '<unknown>')"

section "KVM / Virtualization"
if have kvm-ok; then
  if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
    ok "kvm-ok reports KVM acceleration available"
  else
    fail "kvm-ok reports KVM acceleration NOT available"
    kvm-ok || true
  fi
else
  warn "kvm-ok not found (install cpu-checker for this check)"
fi

if [[ -e /dev/kvm ]]; then
  ok "/dev/kvm exists: $(ls -l /dev/kvm)"
else
  fail "/dev/kvm not found (KVM not available)"
fi

section "Docker"
if have docker; then
  ok "docker present: $(docker --version 2>/dev/null || true)"
else
  fail "docker not found (run scripts/02-install-docker.sh)"
fi

if systemctl is-active --quiet docker 2>/dev/null; then
  ok "docker service is active"
else
  fail "docker service is NOT active"
  systemctl status docker --no-pager || true
fi

section "GNS3 Server"
if systemctl is-active --quiet gns3server 2>/dev/null; then
  ok "gns3server service is active"
else
  fail "gns3server service is NOT active (run scripts/03-install-gns3-server.sh)"
  systemctl status gns3server --no-pager || true
fi

if have ubridge; then
  ok "ubridge present: $(command -v ubridge)"
else
  fail "ubridge not found (GNS3 install incomplete)"
fi

if id "${GNS3_USER}" >/dev/null 2>&1; then
  ok "user exists: ${GNS3_USER}"
  echo "Groups: $(id -nG "${GNS3_USER}" 2>/dev/null || true)"
else
  fail "user missing: ${GNS3_USER} (run scripts/01-prepare-gns3-host.sh)"
fi

# Verify ubridge executable for gns3 user
if id "${GNS3_USER}" >/dev/null 2>&1 && have ubridge; then
  if sudo -u "${GNS3_USER}" -H bash -lc "ubridge -v >/dev/null" >/dev/null 2>&1; then
    ok "gns3 user can execute ubridge"
  else
    fail "gns3 user cannot execute ubridge (group/permissions issue; reboot may be required)"
  fi
fi

section "Bridge + TAPs"
# Bridge presence
if ip link show "${BR}" >/dev/null 2>&1; then
  ok "bridge exists: ${BR}"
  echo "Bridge link: $(ip -br link show "${BR}" 2>/dev/null || true)"
else
  fail "bridge missing: ${BR} (run scripts/04-bridge-tap-provision.sh)"
fi

# Bridge has IPv4
BR_IP="$(ip -4 -o addr show dev "${BR}" 2>/dev/null | awk '{print $4; exit}' || true)"
if [[ -n "${BR_IP}" ]]; then
  ok "bridge has IPv4: ${BR_IP}"
else
  fail "bridge has NO IPv4 (netplan bridge config may not be applied)"
fi

# TAP checks
for T in "${TAP0}" "${TAP1}"; do
  if ip link show "${T}" >/dev/null 2>&1; then
    ok "tap exists: ${T}"
    echo "  ${T}: $(ip -br link show "${T}" 2>/dev/null || true)"
    # is up?
    if ip -br link show "${T}" 2>/dev/null | awk '{print $2}' | grep -qi "UP"; then
      ok "  ${T} is UP"
    else
      fail "  ${T} is NOT UP"
    fi
    # attached to bridge?
    if ip -d link show "${T}" 2>/dev/null | grep -q "master ${BR}"; then
      ok "  ${T} is attached to ${BR}"
    else
      fail "  ${T} is NOT attached to ${BR}"
    fi
  else
    fail "tap missing: ${T}"
  fi
done

# TAP systemd service
if systemctl is-active --quiet gns3-taps 2>/dev/null; then
  ok "gns3-taps service is active"
else
  fail "gns3-taps service is NOT active"
  systemctl status gns3-taps --no-pager || true
fi

section "Summary"
echo "Warnings: ${WARNS}"
echo "Failures: ${FAILS}"

if [[ "${FAILS}" -eq 0 ]]; then
  ok "HOST READINESS: READY ✅"
  REPORT_STATUS="SUCCESS"
  report_add "Readiness" "READY"
  exit 0
else
  fail "HOST READINESS: NOT READY ❌"
  REPORT_STATUS="FAILED"
  report_add "Readiness" "NOT READY"
  exit 1
fi
