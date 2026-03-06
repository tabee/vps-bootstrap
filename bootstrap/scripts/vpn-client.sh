#!/usr/bin/env bash
# =============================================================================
# vpn-client.sh — WireGuard Client Management
# =============================================================================
# Comprehensive VPN client lifecycle management.
#
# Usage:
#   vpn-client.sh add <name>       # Create new client
#   vpn-client.sh remove <name>    # Delete client
#   vpn-client.sh list             # List all clients
#   vpn-client.sh show <name>      # Show client config
#   vpn-client.sh qr <name>        # Display QR code
#   vpn-client.sh sync <names>     # Sync clients (Terraform)
#
# Storage structure:
#   /etc/wireguard/clients/<name>/
#     ├── private.key     # Client private key
#     ├── public.key      # Client public key
#     ├── preshared.key   # PresharedKey (post-quantum security)
#     ├── client.conf     # Ready-to-use WireGuard config
#     └── qr.txt          # ASCII QR code
# =============================================================================

set -euo pipefail

WG_DIR="/etc/wireguard"
CLIENTS_DIR="${WG_DIR}/clients"
NETDEV_FILE="/etc/systemd/network/99-wg0.netdev"
SERVER_CONF="${WG_DIR}/server.conf"

# Default values (can be overridden by server.conf)
SERVER_PORT=51820
VPN_SUBNET="10.100.0"

# Load server config if exists
if [[ -f "$SERVER_CONF" ]]; then
  source "$SERVER_CONF"
fi

# Get server endpoint (public IP)
get_server_endpoint() {
  if [[ -n "${SERVER_ENDPOINT:-}" ]]; then
    echo "$SERVER_ENDPOINT"
  else
    # Try to get public IP
    local ip
    ip=$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo "${ip}:${SERVER_PORT}"
  fi
}

# Get server public key
get_server_pubkey() {
  if [[ -f "${WG_DIR}/public.key" ]]; then
    cat "${WG_DIR}/public.key"
  else
    wg show wg0 public-key 2>/dev/null || wg pubkey < "${WG_DIR}/private.key"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[vpn-client] $*" >&2; }

# Check if running as root
require_root() {
  [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

# Install required packages
install_deps() {
  if ! command -v qrencode &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq qrencode
  fi
  if ! command -v wg &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq wireguard-tools
  fi
}

# Find next free IP in subnet
get_next_ip() {
  local used_ips
  used_ips=$(grep -Pho "AllowedIPs=${VPN_SUBNET}\.\K\d+" "$NETDEV_FILE" 2>/dev/null | sort -n || true)
  
  local next=2  # Start at .2 (.1 is server)
  for ip in $used_ips; do
    [[ "$ip" -eq "$next" ]] && ((next++))
  done
  
  [[ "$next" -le 254 ]] || die "No free IPs in ${VPN_SUBNET}.0/24"
  echo "$next"
}

# Check if client exists
client_exists() {
  [[ -d "${CLIENTS_DIR}/$1" ]]
}

# Validate client name
validate_name() {
  local name="$1"
  [[ -z "$name" ]] && die "Client name required"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid client name (alphanumeric, - and _ only)"
  [[ ${#name} -le 32 ]] || die "Client name too long (max 32 chars)"
}

# ── ADD COMMAND ─────────────────────────────────────────────────────────────
cmd_add() {
  local name="$1"
  validate_name "$name"
  
  if client_exists "$name"; then
    log "Client '$name' already exists"
    return 0
  fi
  
  log "Creating client: $name"
  install_deps
  
  local client_dir="${CLIENTS_DIR}/${name}"
  mkdir -p "$client_dir"
  chmod 700 "$client_dir"
  
  # Generate keys
  local privkey pubkey psk
  privkey=$(wg genkey)
  pubkey=$(echo "$privkey" | wg pubkey)
  psk=$(wg genpsk)
  
  echo "$privkey" > "${client_dir}/private.key"
  echo "$pubkey" > "${client_dir}/public.key"
  echo "$psk" > "${client_dir}/preshared.key"
  chmod 600 "${client_dir}/private.key" "${client_dir}/preshared.key"
  
  # Get next free IP
  local client_ip="${VPN_SUBNET}.$(get_next_ip)"
  local server_pubkey server_endpoint
  server_pubkey=$(get_server_pubkey)
  server_endpoint=$(get_server_endpoint)
  
  # Generate client config (Split-Tunnel: VPN + Docker subnets routed through VPN)
  # DNS points to VPN gateway (dnsmasq) which resolves *.domain → Traefik (10.20.0.10)
  # AllowedIPs includes both:
  #   - 10.100.0.0/24 (VPN subnet) for SSH to admin@10.100.0.1
  #   - 10.20.0.0/24 (Docker subnet) for Traefik and services
  cat > "${client_dir}/client.conf" <<EOF
# WireGuard Config: ${name}
# Generated: $(date -Iseconds)

[Interface]
PrivateKey = ${privkey}
Address = ${client_ip}/24
DNS = ${VPN_SUBNET}.1

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${psk}
Endpoint = ${server_endpoint}
AllowedIPs = ${VPN_SUBNET}.0/24, 10.20.0.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "${client_dir}/client.conf"
  
  # Generate QR code
  qrencode -t UTF8 < "${client_dir}/client.conf" > "${client_dir}/qr.txt"
  
  # Add peer to server config
  cat >> "$NETDEV_FILE" <<EOF

[WireGuardPeer]
# Client: ${name}
PublicKey=${pubkey}
PresharedKey=${psk}
AllowedIPs=${client_ip}/32
EOF
  
  # Restart systemd-networkd (reload is unreliable for adding peers)
  systemctl restart systemd-networkd
  sleep 2
  
  log "Client '$name' created: ${client_ip}"
  log "Config: ${client_dir}/client.conf"
}

# ── REMOVE COMMAND ──────────────────────────────────────────────────────────
cmd_remove() {
  local name="$1"
  validate_name "$name"
  
  [[ "$name" == "admin" ]] && die "Cannot remove 'admin' client (protected)"
  
  if ! client_exists "$name"; then
    log "Client '$name' does not exist"
    return 0
  fi
  
  log "Removing client: $name"
  
  local client_dir="${CLIENTS_DIR}/${name}"
  
  # Remove peer from server config (block from # Client: to next empty line or [)
  sed -i "/# Client: ${name}/,/^$/d" "$NETDEV_FILE"
  
  # Remove client directory
  rm -rf "$client_dir"
  
  # Restart systemd-networkd (reload is unreliable for removing peers)
  systemctl restart systemd-networkd
  sleep 2
  
  log "Client '$name' removed"
}

# ── LIST COMMAND ────────────────────────────────────────────────────────────
cmd_list() {
  echo "╔═══════════════════════════════════════════╗"
  echo "║         WireGuard VPN Clients             ║"
  echo "╠═══════════════════════════════════════════╣"
  
  local count=0
  for dir in "${CLIENTS_DIR}"/*/; do
    [[ -d "$dir" ]] || continue
    local name ip
    name=$(basename "$dir")
    ip=$(grep -Po "Address = \K[0-9.]+" "${dir}/client.conf" 2>/dev/null || echo "?")
    printf "║  %-20s │ %s\n" "$name" "$ip"
    ((count++))
  done
  
  if [[ $count -eq 0 ]]; then
    echo "║  (no clients configured)                  ║"
  fi
  
  echo "╚═══════════════════════════════════════════╝"
  echo "Total: $count client(s)"
}

# ── SHOW COMMAND ────────────────────────────────────────────────────────────
cmd_show() {
  local name="$1"
  validate_name "$name"
  client_exists "$name" || die "Client '$name' does not exist"
  
  cat "${CLIENTS_DIR}/${name}/client.conf"
}

# ── QR COMMAND ──────────────────────────────────────────────────────────────
cmd_qr() {
  local name="$1"
  validate_name "$name"
  client_exists "$name" || die "Client '$name' does not exist"
  
  local qr_file="${CLIENTS_DIR}/${name}/qr.txt"
  if [[ -f "$qr_file" ]]; then
    cat "$qr_file"
  else
    # Generate on-the-fly
    qrencode -t UTF8 < "${CLIENTS_DIR}/${name}/client.conf"
  fi
}

# ── SYNC COMMAND ────────────────────────────────────────────────────────────
# Called by Terraform to synchronize client list
cmd_sync() {
  local wanted="$1"
  [[ -z "$wanted" ]] && die "Usage: $0 sync 'admin,iphone,laptop'"
  
  log "Syncing clients: $wanted"
  
  # Parse comma-separated list
  IFS=',' read -ra wanted_array <<< "$wanted"
  
  # Get existing clients
  local existing=()
  for dir in "${CLIENTS_DIR}"/*/; do
    [[ -d "$dir" ]] && existing+=("$(basename "$dir")")
  done
  
  # Add missing clients
  for client in "${wanted_array[@]}"; do
    client=$(echo "$client" | xargs)  # Trim whitespace
    [[ -n "$client" ]] || continue
    client_exists "$client" || cmd_add "$client"
  done
  
  # Remove unwanted clients (except admin)
  for client in "${existing[@]}"; do
    local found=false
    for w in "${wanted_array[@]}"; do
      w=$(echo "$w" | xargs)
      [[ "$client" == "$w" ]] && found=true
    done
    if [[ "$found" == "false" && "$client" != "admin" ]]; then
      cmd_remove "$client"
    fi
  done
  
  log "Sync complete"
}

# ── HELP ────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Usage: $0 <command> [arguments]

Commands:
  add <name>         Create a new VPN client
  remove <name>      Remove an existing client
  list               List all configured clients
  show <name>        Display client configuration
  qr <name>          Display QR code for mobile import
  sync <names>       Synchronize with comma-separated list

Examples:
  $0 add laptop
  $0 qr laptop
  $0 remove laptop
  $0 sync "admin,iphone,laptop"

Storage:
  Client configs are stored in /etc/wireguard/clients/<name>/
EOF
}

# ── MAIN ────────────────────────────────────────────────────────────────────
main() {
  require_root
  
  local cmd="${1:-help}"
  shift || true
  
  case "$cmd" in
    add)    cmd_add "${1:-}" ;;
    remove) cmd_remove "${1:-}" ;;
    list)   cmd_list ;;
    show)   cmd_show "${1:-}" ;;
    qr)     cmd_qr "${1:-}" ;;
    sync)   cmd_sync "${1:-}" ;;
    help|--help|-h) cmd_help ;;
    *)      die "Unknown command: $cmd (use --help for usage)" ;;
  esac
}

main "$@"
