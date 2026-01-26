#!/usr/bin/env bash
#==============================================================================
# Project:     GNS3 Bare-Metal Server Kit (Ubuntu 24.04)
# Script:      05-expand-root-lvm-ubuntu.sh
# Version:     1.0.0
# Author:      Davis Boudreau
# License:     MIT
# SPDX-License-Identifier: MIT
#
# Summary:
#   - Extends Ubuntu's default root logical volume to consume all FREE space
#   - Grows the filesystem (ext* via resize2fs)
#
# IMPORTANT:
#   - This is ONLY for Ubuntu installs using the default LV path:
#       /dev/mapper/ubuntu--vg-ubuntu--lv
#   - If that path does not exist, the script exits safely.
#
# Usage:
#   sudo bash scripts/05-expand-root-lvm-ubuntu.sh
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
report_add "Script" "$(basename "$0")"
report_add "Target LV" "/dev/mapper/ubuntu--vg-ubuntu--lv"
report_add "Reboot required" "NO"
LV="/dev/mapper/ubuntu--vg-ubuntu--lv"

echo "=============================="
echo " Expand Root LV (Ubuntu Default LVM)"
echo " Target LV: ${LV}"
echo " Version:   1.0.0"
echo "=============================="

if [[ ! -e "${LV}" ]]; then
  echo "No Ubuntu default LV found at: ${LV}"
  echo "Skipping. (This step is only for Ubuntu's default LVM installs.)"
  exit 0
fi

require_cmd lvextend
require_cmd resize2fs

echo "Extending LV to use all FREE space..."
run lvextend -l +100%FREE "${LV}"

echo "Growing filesystem..."
run resize2fs "${LV}"

echo "Done."
