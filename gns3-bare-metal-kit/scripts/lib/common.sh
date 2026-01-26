#!/usr/bin/env bash
#==============================================================================
# Common helpers for the GNS3 Bare-Metal Server Kit
#==============================================================================

set -euo pipefail

# -----------------------------
# Errors / Privilege
# -----------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

# -----------------------------
# Backups / Validation
# -----------------------------
backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
    echo "✔ Backup created: ${f}.bak.${ts}"
  fi
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
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
  local __var="$1" __prompt="$2" __default="${3:-}" __val=""
  if [[ -n "$__default" ]]; then
    read -rp "${__prompt} [${__default}]: " __val
    __val="${__val:-$__default}"
  else
    read -rp "${__prompt}: " __val
  fi
  __val="${__val#"${__val%%[![:space:]]*}"}"
  __val="${__val%"${__val##*[![:space:]]}"}"
  printf -v "$__var" "%s" "$__val"
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
}

os_release_id() { . /etc/os-release; echo "${ID}"; }
os_release_codename() { . /etc/os-release; echo "${VERSION_CODENAME:-}"; }

# -----------------------------
# Logging + Flags
# -----------------------------
LOG_DIR_DEFAULT="/var/log/gns3-bare-metal"
LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
LOG_FILE="${LOG_FILE:-}"

DRY_RUN="${DRY_RUN:-0}"   # 1 => do not execute mutating commands
COMMON_ARGS=()

usage_common() {
  cat <<'EOF'
Common flags (supported by all scripts):
  --dry-run        Print what would happen, but do not execute mutating commands.
  --log-dir DIR    Override log directory (default: /var/log/gns3-bare-metal)

Environment equivalents:
  DRY_RUN=1
  LOG_DIR=/path
EOF
}

parse_common_flags() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --log-dir)
        [[ -n "${2:-}" ]] || die "--log-dir requires a value"
        LOG_DIR="$2"; shift 2 ;;
      -h|--help) usage_common; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  COMMON_ARGS=("${args[@]}")
}

init_logging() {
  local script_name ts
  script_name="$(basename "$0" .sh)"
  ts="$(date '+%Y-%m-%d_%H-%M-%S')"

  mkdir -p "${LOG_DIR}"
  chmod 750 "${LOG_DIR}" || true

  LOG_FILE="${LOG_DIR}/${script_name}-${ts}.log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  echo "============================================================"
  echo " GNS3 Bare-Metal Installation Log"
  echo " Script : ${script_name}"
  echo " Date   : $(date)"
  echo " Host   : $(hostname)"
  echo " User   : $(whoami)"
  echo " DryRun : ${DRY_RUN}"
  echo " Log    : ${LOG_FILE}"
  echo "============================================================"
  echo ""
}

# -----------------------------
# Traps + Reporting
# -----------------------------
REPORT_ITEMS=()
REPORT_STATUS="UNKNOWN"
REPORT_START_EPOCH="$(date +%s)"

report_add() { REPORT_ITEMS+=("$1=$2"); }

print_report() {
  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed="$((end_epoch - REPORT_START_EPOCH))"
  echo ""
  echo "============================================================"
  echo " Install Report Summary"
  echo " Status   : ${REPORT_STATUS}"
  echo " Duration : ${elapsed}s"
  echo " DryRun   : ${DRY_RUN}"
  echo " Log File : ${LOG_FILE:-<none>}"
  echo "------------------------------------------------------------"
  for kv in "${REPORT_ITEMS[@]}"; do
    echo " - ${kv/=/: }"
  done
  echo "============================================================"
  echo ""
}

on_error_trap() {
  local line="${1:-?}"
  REPORT_STATUS="FAILED"
  echo ""
  echo "❌ Script failed at line ${line}"
  echo "   Log: ${LOG_FILE:-<none>}"
  print_report
  exit 1
}

on_exit_trap() {
  local code="$?"
  if [[ "$code" -eq 0 && "${REPORT_STATUS}" == "UNKNOWN" ]]; then
    REPORT_STATUS="SUCCESS"
  elif [[ "$code" -ne 0 && "${REPORT_STATUS}" == "UNKNOWN" ]]; then
    REPORT_STATUS="FAILED"
  fi
  print_report
}

setup_traps() {
  trap 'on_error_trap $LINENO' ERR
  trap 'on_exit_trap' EXIT
}

# -----------------------------
# Dry-run aware execution helpers
# -----------------------------
run() {
  echo "+ $*"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  "$@"
}

run_bash() {
  echo "+ bash -lc \"$*\""
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  bash -lc "$*"
}

write_file() {
  local path="$1"
  echo "+ write_file ${path}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    cat >/dev/null
    echo "  (dry-run) not writing ${path}"
    return 0
  fi
  cat > "${path}"
}

copy_file() {
  local src="$1" dst="$2"
  echo "+ cp -a ${src} ${dst}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  cp -a "${src}" "${dst}"
}


# -----------------------------
# Dry-run safety for install scripts
# -----------------------------
is_dry_run() { [[ "${DRY_RUN}" -eq 1 ]]; }

require_real_run() {
  # Use in scripts that cannot proceed meaningfully in --dry-run mode because
  # later steps assume packages/files/services exist.
  if is_dry_run; then
    echo ""
    echo "DRY-RUN: This script will NOT make changes and will NOT attempt verification."
    echo "DRY-RUN: Re-run without --dry-run to perform installation."
    report_add "Dry-run note" "Skipped install/verify"
    REPORT_STATUS="SUCCESS"
    exit 0
  fi
}
