#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Helpers: prompting + guessing
# -----------------------------
prompt_with_default() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local input=""

  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " input
    input="${input:-$default}"
  else
    read -r -p "$prompt: " input
  fi

  printf -v "$var_name" '%s' "$input"
}

default_uplink_nic() {
  ip route show default 0.0.0.0/0 2>/dev/null | awk '{
    for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}
  }'
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# Idempotent iptables helpers
# -----------------------------
iptables_add_once() {
  # Usage: iptables_add_once <table> <chain> <rule...>
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    echo "OK: iptables rule already present: -t $table $chain $*"
  else
    iptables -t "$table" -A "$chain" "$@"
    echo "ADD: iptables rule added:       -t $table $chain $*"
  fi
}

# -----------------------------
# Persistent routes via systemd
# -----------------------------
install_route_service() {
  local script_path="/usr/local/sbin/gns3-virbr0-routes.sh"
  local unit_path="/etc/systemd/system/gns3-virbr0-routes.service"

  echo "INFO: Installing persistent route script at: $script_path"
  cat > "$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Persistent routes for GNS3 VLSM subnets behind router
VIRBR="$VIRBR"
ROUTER_IP="$ROUTER_IP"
EOF

  # Add route commands (replace is idempotent)
  for s in "${VLSM_SUBNETS[@]}"; do
    cat >> "$script_path" <<EOF
ip route replace $s via $ROUTER_IP dev $VIRBR
EOF
  done

  chmod 0755 "$script_path"

  echo "INFO: Installing systemd unit at: $unit_path"
  cat > "$unit_path" <<EOF
[Unit]
Description=Install static routes for GNS3 behind virbr0
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now gns3-virbr0-routes.service >/dev/null
  echo "OK: Persistent route service enabled and started."
}

# -----------------------------
# Main
# -----------------------------
require_root

echo "=== GNS3 virbr0 NAT + VLSM Route Automation (Ubuntu 24.04) ==="
echo

# Guess uplink NIC
GUESS="$(default_uplink_nic || true)"

# Prompt for uplink NIC (your provided logic, slightly adapted)
while true; do
  if [[ -n "${GUESS}" ]]; then
    prompt_with_default NIC "Enter primary NIC name (internet-facing uplink)" "$GUESS"
  else
    prompt_with_default NIC "Enter primary NIC name (internet-facing uplink)" ""
  fi

  [[ -n "$NIC" ]] || { echo "Please enter a NIC name."; continue; }
  ip link show "$NIC" >/dev/null 2>&1 && break
  echo "Invalid NIC '$NIC'. Check with: ip -br link"
done

# virbr0 interface name (usually virbr0)
prompt_with_default VIRBR "Enter inside bridge interface (virbr0)" "virbr0"
ip link show "$VIRBR" >/dev/null 2>&1 || {
  echo "ERROR: Interface '$VIRBR' not found. Check with: ip -br link"
  exit 1
}

# Router IP on the transit /26 (must be reachable on virbr0)
prompt_with_default ROUTER_IP "Enter GNS3 router IP on virbr0 transit (e.g., 192.168.100.2)" "192.168.100.2"

# NAT source summary (what you want NAT to cover)
prompt_with_default NAT_SRC "Enter NAT source summary (CIDR)" "192.168.100.0/24"

# VLSM subnets behind the router (comma-separated)
prompt_with_default VLSM_LIST "Enter VLSM subnets behind router (comma-separated)" "192.168.100.64/26,192.168.100.128/26,192.168.100.192/26"

# Parse subnets
IFS=',' read -r -a VLSM_SUBNETS <<< "$VLSM_LIST"

echo
echo "=== Summary ==="
echo "Uplink NIC:        $NIC"
echo "Inside interface:  $VIRBR"
echo "GNS3 router IP:    $ROUTER_IP"
echo "NAT source CIDR:   $NAT_SRC"
echo "VLSM subnets:      ${VLSM_SUBNETS[*]}"
echo

# 1) Enable forwarding now + persistently
echo "INFO: Enabling IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

SYSCTL_FILE="/etc/sysctl.d/99-gns3-virbr0-nat.conf"
cat > "$SYSCTL_FILE" <<EOF
# Enable IPv4 forwarding for GNS3 NAT
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null || true
echo "OK: IPv4 forwarding enabled and persisted in $SYSCTL_FILE"

# 2) Add runtime routes now (idempotent using replace)
echo "INFO: Installing runtime routes (ip route replace)..."
for s in "${VLSM_SUBNETS[@]}"; do
  ip route replace "$s" via "$ROUTER_IP" dev "$VIRBR"
  echo "OK: route -> $s via $ROUTER_IP dev $VIRBR"
done

# 3) NAT + forward rules (idempotent)
echo "INFO: Adding iptables NAT/FORWARD rules (idempotent)..."
iptables_add_once nat POSTROUTING -s "$NAT_SRC" -o "$NIC" -j MASQUERADE
iptables_add_once filter FORWARD -i "$VIRBR" -o "$NIC" -s "$NAT_SRC" -j ACCEPT
iptables_add_once filter FORWARD -i "$NIC" -o "$VIRBR" -d "$NAT_SRC" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 4) Persist iptables rules
echo "INFO: Making iptables rules persistent..."
if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
  echo "INFO: Installing iptables-persistent (will prompt in some environments)..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null
fi

# Save current rules
if have_cmd netfilter-persistent; then
  netfilter-persistent save >/dev/null
  echo "OK: Saved rules via netfilter-persistent."
else
  # Fallback
  iptables-save > /etc/iptables/rules.v4
  echo "OK: Saved rules to /etc/iptables/rules.v4"
fi

# 5) Install persistent route service (systemd)
echo "INFO: Creating persistent route service..."
install_route_service

echo
echo "=== DONE ==="
echo "To verify:"
echo "  ip route | grep 192.168.100"
echo "  sudo iptables -t nat -L -n -v"
echo "  sudo iptables -L FORWARD -n -v"
echo
echo "From a GNS3 internal VM, test: ping 8.8.8.8 and DNS resolution."