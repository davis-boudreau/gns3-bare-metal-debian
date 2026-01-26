#!/usr/bin/env bash
# Collect logs for support / student submissions
set -euo pipefail

LOG_DIR="${LOG_DIR:-/var/log/gns3-bare-metal}"
OUT="${1:-gns3-bare-metal-logs-$(date +%Y-%m-%d_%H-%M-%S).tar.gz}"

if [[ ! -d "${LOG_DIR}" ]]; then
  echo "Log directory not found: ${LOG_DIR}"
  exit 1
fi

echo "Collecting logs from: ${LOG_DIR}"
tar -czf "${OUT}" -C "${LOG_DIR}" .
echo "Created: ${OUT}"
