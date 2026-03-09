#!/usr/bin/env bash
# =============================================================================
# services/users.sh — Restricted User Management with vpn-cli/vpn-web Groups
# =============================================================================
# Deploys:
#   - System groups: vpn-cli (SSH CLI access), vpn-web (WireGuard web access)
#   - Restricted users with rbash shell
#   - CLI wrapper scripts for Docker services
#   - WireGuard peers for vpn-web users
#
# Security Design:
#   - Users get rbash (restricted bash) with PATH locked to ~/bin
#   - ~/bin contains symlinks to allowed commands only
#   - CLI wrappers check group membership before execution
#   - No sudo access, no shell escape
#   - WireGuard peers use separate IP range (10.100.1.x)
#
# Architecture:
#   Terraform → ADDITIONAL_USERS JSON → users.sh → 
#     → System users (rbash)
#     → CLI wrappers (/usr/local/bin)
#     → WireGuard peers (wg0)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="users"
SERVICE_DIR="/opt/users"
VPN_CLIENT_SCRIPT="${SCRIPT_DIR}/scripts/vpn-client.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Service flags
ENABLE_WHOAMI="${ENABLE_WHOAMI:-false}"
ENABLE_GITEA="${ENABLE_GITEA:-false}"
ENABLE_N8N="${ENABLE_N8N:-false}"
ENABLE_GOGCLI="${ENABLE_GOGCLI:-false}"

# User network for WireGuard peers (10.100.1.x instead of admin 10.100.0.x)
USER_WG_SUBNET="10.100.1"

# ── Setup system groups ──────────────────────────────────────────────────────
setup_groups() {
  log_step "Setting up access control groups"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create groups: vpn-cli, vpn-web"
    return 0
  fi

  # vpn-cli: Can use CLI wrappers via SSH
  if ! getent group vpn-cli &>/dev/null; then
    groupadd --system vpn-cli
    log_info "Created group: vpn-cli"
  else
    log_info "Group vpn-cli already exists"
  fi

  # vpn-web: Can access web services via WireGuard
  if ! getent group vpn-web &>/dev/null; then
    groupadd --system vpn-web
    log_info "Created group: vpn-web"
  else
    log_info "Group vpn-web already exists"
  fi
}

# ── Install CLI wrapper scripts ──────────────────────────────────────────────
install_cli_wrappers() {
  log_step "Installing CLI wrapper scripts"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install CLI wrappers to /usr/local/bin"
    return 0
  fi

  local wrapper_dir="/usr/local/bin"

  # GOG CLI wrapper
  if [[ "$ENABLE_GOGCLI" == "true" ]]; then
    cat > "${wrapper_dir}/gog-cli" << 'EOF'
#!/bin/bash
# GOG CLI wrapper — requires vpn-cli group
set -euo pipefail
if [[ " $(/usr/bin/id -nG) " != *" vpn-cli "* ]]; then
    echo "Error: vpn-cli group membership required" >&2
    exit 1
fi
exec /usr/bin/docker exec -i gogcli gog "$@"
EOF
    chmod 755 "${wrapper_dir}/gog-cli"
    log_info "Installed: gog-cli"
  fi

  # n8n CLI wrapper
  if [[ "$ENABLE_N8N" == "true" ]]; then
    cat > "${wrapper_dir}/n8n-cli" << 'EOF'
#!/bin/bash
# n8n CLI wrapper — requires vpn-cli group
set -euo pipefail
if [[ " $(/usr/bin/id -nG) " != *" vpn-cli "* ]]; then
    echo "Error: vpn-cli group membership required" >&2
    exit 1
fi
exec /usr/bin/docker exec -i n8n n8n "$@"
EOF
    chmod 755 "${wrapper_dir}/n8n-cli"
    log_info "Installed: n8n-cli"

    # PostgreSQL (n8n) wrapper
    cat > "${wrapper_dir}/psql-n8n-cli" << 'EOF'
#!/bin/bash
# PostgreSQL (n8n) CLI wrapper — requires vpn-cli group
set -euo pipefail
  if [[ " $(/usr/bin/id -nG) " != *" vpn-cli "* ]]; then
    echo "Error: vpn-cli group membership required" >&2
    exit 1
fi
  exec /usr/bin/docker exec -i n8n-postgres psql -U n8n -d n8n "$@"
EOF
    chmod 755 "${wrapper_dir}/psql-n8n-cli"
    log_info "Installed: psql-n8n-cli"
  fi

  # Gitea CLI wrappers
  if [[ "$ENABLE_GITEA" == "true" ]]; then
    # PostgreSQL (Gitea) wrapper
    cat > "${wrapper_dir}/psql-gitea-cli" << 'EOF'
#!/bin/bash
# PostgreSQL (Gitea) CLI wrapper — requires vpn-cli group
set -euo pipefail
  if [[ " $(/usr/bin/id -nG) " != *" vpn-cli "* ]]; then
    echo "Error: vpn-cli group membership required" >&2
    exit 1
fi
  exec /usr/bin/docker exec -i gitea-postgres psql -U gitea -d gitea "$@"
EOF
    chmod 755 "${wrapper_dir}/psql-gitea-cli"
    log_info "Installed: psql-gitea-cli"

    # tea CLI wrapper (per-user config via environment)
    cat > "${wrapper_dir}/tea-cli" << 'EOF'
#!/bin/bash
# tea (Gitea CLI) wrapper — requires vpn-cli group
# First run: tea login add --url https://git.DOMAIN --token YOUR_TOKEN --name default
set -euo pipefail
  if [[ " $(/usr/bin/id -nG) " != *" vpn-cli "* ]]; then
    echo "Error: vpn-cli group membership required" >&2
    exit 1
fi
# Use user-specific tea config
export XDG_CONFIG_HOME="${HOME}/.config"
  exec /usr/bin/docker exec -i -e "XDG_CONFIG_HOME=/tmp/tea-$(/usr/bin/id -un)" gitea-tea tea "$@"
EOF
    chmod 755 "${wrapper_dir}/tea-cli"
    log_info "Installed: tea-cli"
  fi
}

# ── Create restricted user ───────────────────────────────────────────────────
create_restricted_user() {
  local username="$1"
  local ssh_pubkey="$2"
  local groups_str="$3"
  local effective_groups="$groups_str"

  # vpn-cli users need docker socket access for CLI wrappers
  if echo "$groups_str" | grep -qw vpn-cli; then
    if getent group docker &>/dev/null; then
      if ! echo "$groups_str" | grep -qw docker; then
        effective_groups+=",docker"
      fi
    else
      log_warn "Group 'docker' not found; vpn-cli wrappers may fail for ${username}"
    fi
  fi

  log_info "Setting up restricted user: ${username} (groups: ${effective_groups})"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create user: ${username}"
    return 0
  fi

  local user_home="/home/${username}"
  local user_bin="${user_home}/bin"

  # Create user if not exists
  if ! id "$username" &>/dev/null; then
    useradd \
      --create-home \
      --home-dir "$user_home" \
      --shell /bin/rbash \
      --groups "$effective_groups" \
      --comment "Restricted VPN user (managed by Terraform)" \
      "$username"
    log_info "Created user: ${username}"
  else
    # Update groups for existing user (replace all supplementary groups)
    usermod --groups "$effective_groups" "$username"
    # Ensure shell is rbash
    usermod --shell /bin/rbash "$username"
    log_info "Updated existing user: ${username}"
  fi

  # Setup restricted bin directory (owned by root so user cannot modify)
  mkdir -p "$user_bin"
  chown root:root "$user_bin"
  chmod 755 "$user_bin"

  # Setup SSH authorized_keys
  local ssh_dir="${user_home}/.ssh"
  mkdir -p "$ssh_dir"
  # Trim any trailing whitespace/newlines from pubkey
  echo "$ssh_pubkey" | tr -d '\r' > "${ssh_dir}/authorized_keys"
  chmod 700 "$ssh_dir"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown -R "${username}:${username}" "$ssh_dir"

  # Create restricted .bashrc (owned by root)
  cat > "${user_home}/.bashrc" << 'BASHRC'
# Restricted bash configuration — DO NOT MODIFY
# This file is managed by Terraform

export PATH="${HOME}/bin"
readonly PATH
export HISTFILE=/dev/null
export LESSSECURE=1

# Disable dangerous builtins
enable -n source 2>/dev/null || true
enable -n . 2>/dev/null || true

# Show available commands on login
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Restricted Shell — Available commands:                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
ls ~/bin 2>/dev/null | column 2>/dev/null || ls ~/bin 2>/dev/null || echo "(none)"
echo ""
BASHRC

  # Create .profile that sources .bashrc
  cat > "${user_home}/.profile" << 'PROFILE'
# Restricted profile — DO NOT MODIFY
if [ -f "${HOME}/.bashrc" ]; then
    . "${HOME}/.bashrc"
fi
PROFILE

  # Lock down home directory files
  chown root:root "${user_home}/.bashrc" "${user_home}/.profile"
  chmod 644 "${user_home}/.bashrc" "${user_home}/.profile"
  chown "${username}:${username}" "$user_home"
  chmod 750 "$user_home"

  log_info "Configured restricted environment for: ${username}"
}

# ── Setup user's available commands ──────────────────────────────────────────
setup_user_commands() {
  local username="$1"
  local groups_str="$2"
  local user_bin="/home/${username}/bin"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would setup commands for: ${username}"
    return 0
  fi

  # Clear old symlinks
  find "${user_bin}" -type l -delete 2>/dev/null || true

  # Basic allowed commands (always available)
  ln -sf /bin/ls "${user_bin}/ls"
  ln -sf /bin/cat "${user_bin}/cat"
  ln -sf /bin/echo "${user_bin}/echo"
  ln -sf /usr/bin/whoami "${user_bin}/whoami"
  ln -sf /usr/bin/id "${user_bin}/id"
  ln -sf /usr/bin/clear "${user_bin}/clear" 2>/dev/null || true

  # CLI commands only for vpn-cli group members
  if echo "$groups_str" | grep -qw vpn-cli; then
    [[ -x /usr/local/bin/gog-cli ]] && ln -sf /usr/local/bin/gog-cli "${user_bin}/gog"
    [[ -x /usr/local/bin/n8n-cli ]] && ln -sf /usr/local/bin/n8n-cli "${user_bin}/n8n"
    [[ -x /usr/local/bin/psql-gitea-cli ]] && ln -sf /usr/local/bin/psql-gitea-cli "${user_bin}/psql-gitea"
    [[ -x /usr/local/bin/psql-n8n-cli ]] && ln -sf /usr/local/bin/psql-n8n-cli "${user_bin}/psql-n8n"
    [[ -x /usr/local/bin/tea-cli ]] && ln -sf /usr/local/bin/tea-cli "${user_bin}/tea"
    log_info "CLI commands linked for: ${username}"
  fi
}

# ── Add WireGuard peer for vpn-web user ──────────────────────────────────────
# Uses a separate IP range from admin VPN clients
add_user_wireguard_peer() {
  local username="$1"
  local user_index="$2"  # 0-based index for IP calculation

  local wg_ip="${USER_WG_SUBNET}.$((user_index + 2))"  # Start at .2
  local netdev_file="/etc/systemd/network/99-wg0.netdev"
  local peer_marker="# USER_PEER: ${username}"

  log_info "Adding WireGuard peer for: ${username} (${wg_ip})"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would add WireGuard peer: ${username} → ${wg_ip}"
    return 0
  fi

  # Generate keys for this user if not exists
  local user_wg_dir="/etc/wireguard/users/${username}"
  mkdir -p "$user_wg_dir"
  chmod 700 "$user_wg_dir"

  if [[ ! -f "${user_wg_dir}/private.key" ]]; then
    wg genkey > "${user_wg_dir}/private.key"
    chmod 600 "${user_wg_dir}/private.key"
    wg pubkey < "${user_wg_dir}/private.key" > "${user_wg_dir}/public.key"
    wg genpsk > "${user_wg_dir}/preshared.key"
    chmod 600 "${user_wg_dir}/preshared.key"
    log_info "Generated WireGuard keys for: ${username}"
  fi

  local user_pubkey
  user_pubkey=$(cat "${user_wg_dir}/public.key")
  local user_psk
  user_psk=$(cat "${user_wg_dir}/preshared.key")

  # Check if peer already exists with correct config
  if grep -q "${peer_marker}" "$netdev_file" 2>/dev/null; then
    # Check if IP matches
    if grep -A3 "${peer_marker}" "$netdev_file" | grep -q "AllowedIPs=${wg_ip}/32"; then
      log_info "WireGuard peer already configured correctly: ${username}"
      return 0
    fi
    # Remove old peer block to update it
    log_info "Updating WireGuard peer: ${username}"
    # Use Python for reliable multi-line removal
    python3 - "$netdev_file" "$peer_marker" << 'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    lines = f.readlines()
result = []
skip = False
for line in lines:
    if marker in line:
        skip = True
        continue
    if skip:
        if line.startswith('[') or line.startswith('# USER_PEER:'):
            skip = False
        else:
            continue
    if not skip:
        result.append(line)
with open(path, 'w') as f:
    f.writelines(result)
PY
  fi

  # Append new peer configuration
  cat >> "$netdev_file" << EOF

${peer_marker}
[WireGuardPeer]
PublicKey=${user_pubkey}
PresharedKey=${user_psk}
AllowedIPs=${wg_ip}/32
EOF

  # Generate user's client config
  local server_pubkey server_endpoint
  server_pubkey=$(cat /etc/wireguard/public.key)
  server_endpoint=$(grep -oP 'SERVER_ENDPOINT=\K.*' /etc/wireguard/server.conf 2>/dev/null || curl -s -4 ifconfig.me):51820
  local user_privkey
  user_privkey=$(cat "${user_wg_dir}/private.key")

  cat > "${user_wg_dir}/client.conf" << EOF
# WireGuard Config: ${username}
# Generated: $(date -Iseconds)
# Access: vpn-web group (web services only)

[Interface]
PrivateKey = ${user_privkey}
Address = ${wg_ip}/32
DNS = 10.100.0.1

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${user_psk}
Endpoint = ${server_endpoint}
AllowedIPs = 10.20.0.0/24, 10.100.0.0/24, 10.100.1.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "${user_wg_dir}/client.conf"

  # Generate QR code if qrencode is available
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 < "${user_wg_dir}/client.conf" > "${user_wg_dir}/qr.txt" 2>/dev/null || true
  fi

  # Reload WireGuard
  networkctl reload 2>/dev/null || systemctl restart systemd-networkd 2>/dev/null || true

  log_info "WireGuard peer added: ${username} → ${wg_ip}"
}

# ── Remove WireGuard peer ────────────────────────────────────────────────────
remove_user_wireguard_peer() {
  local username="$1"
  local netdev_file="/etc/systemd/network/99-wg0.netdev"
  local peer_marker="# USER_PEER: ${username}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would remove WireGuard peer: ${username}"
    return 0
  fi

  if grep -q "${peer_marker}" "$netdev_file" 2>/dev/null; then
    python3 - "$netdev_file" "$peer_marker" << 'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    lines = f.readlines()
result = []
skip = False
for line in lines:
    if marker in line:
        skip = True
        continue
    if skip:
        if line.startswith('[') or line.startswith('# USER_PEER:'):
            skip = False
        else:
            continue
    if not skip:
        result.append(line)
with open(path, 'w') as f:
    f.writelines(result)
PY
    networkctl reload 2>/dev/null || systemctl restart systemd-networkd 2>/dev/null || true
    log_info "Removed WireGuard peer: ${username}"
  fi

  # Remove user's WireGuard directory
  rm -rf "/etc/wireguard/users/${username}"
}

# ── Store user metadata ──────────────────────────────────────────────────────
store_user_metadata() {
  local users_json="$1"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  mkdir -p "${SERVICE_DIR}"
  echo "$users_json" > "${SERVICE_DIR}/users.json"
  chmod 600 "${SERVICE_DIR}/users.json"
  log_info "User metadata stored in ${SERVICE_DIR}/users.json"
}

# ── Sync users from ADDITIONAL_USERS ─────────────────────────────────────────
sync_users() {
  log_step "Syncing additional users"

  local users_json="${ADDITIONAL_USERS:-[]}"

  if [[ "$users_json" == "[]" ]] || [[ -z "$users_json" ]]; then
    log_info "No additional users configured"
    # Clean up any existing users if config was emptied
    if [[ -f "${SERVICE_DIR}/users.json" ]]; then
      local existing_users
      existing_users=$(jq -r '.[].username' "${SERVICE_DIR}/users.json" 2>/dev/null || true)
      for existing in $existing_users; do
        log_info "Removing user no longer in config: ${existing}"
        if [[ "$DRY_RUN" != "true" ]]; then
          remove_user_wireguard_peer "$existing"
          userdel -r "$existing" 2>/dev/null || true
        fi
      done
      rm -f "${SERVICE_DIR}/users.json"
    fi
    return 0
  fi

  # Check for jq
  if ! command -v jq &>/dev/null; then
    log_warn "jq not installed, cannot process additional users"
    return 1
  fi

  local user_count
  user_count=$(echo "$users_json" | jq 'length')
  log_info "Processing ${user_count} additional user(s)..."

  # Get list of configured usernames
  local configured_users
  configured_users=$(echo "$users_json" | jq -r '.[].username')

  # Get list of existing managed users
  local existing_users=""
  if [[ -f "${SERVICE_DIR}/users.json" ]]; then
    existing_users=$(jq -r '.[].username' "${SERVICE_DIR}/users.json" 2>/dev/null || true)
  fi

  # Remove users no longer in config
  for existing in $existing_users; do
    if ! echo "$configured_users" | grep -qx "$existing"; then
      log_info "Removing user no longer in config: ${existing}"
      if [[ "$DRY_RUN" != "true" ]]; then
        remove_user_wireguard_peer "$existing"
        userdel -r "$existing" 2>/dev/null || true
        log_info "Removed user: ${existing}"
      fi
    fi
  done

  # Process configured users
  local vpn_web_index=0
  echo "$users_json" | jq -c '.[]' | while read -r user; do
    local username ssh_pubkey groups_array groups_str
    username=$(echo "$user" | jq -r '.username')
    ssh_pubkey=$(echo "$user" | jq -r '.ssh_pubkey')
    groups_array=$(echo "$user" | jq -r '.groups | join(",")')
    groups_str="$groups_array"

    create_restricted_user "$username" "$ssh_pubkey" "$groups_str"
    setup_user_commands "$username" "$groups_str"

    # Handle WireGuard peer based on vpn-web membership
    if echo "$groups_str" | grep -qw vpn-web; then
      add_user_wireguard_peer "$username" "$vpn_web_index"
      vpn_web_index=$((vpn_web_index + 1))
    else
      # Remove peer if user was removed from vpn-web group
      remove_user_wireguard_peer "$username"
    fi
  done

  # Store metadata for future syncs
  store_user_metadata "$users_json"
}

# ── Print summary ────────────────────────────────────────────────────────────
print_summary() {
  local users_json="${ADDITIONAL_USERS:-[]}"

  if [[ "$users_json" == "[]" ]] || [[ -z "$users_json" ]]; then
    return 0
  fi

  log_step "Additional users configured"
  log_info "════════════════════════════════════════════════════════════════"

  echo "$users_json" | jq -c '.[]' | while read -r user; do
    local username groups_str
    username=$(echo "$user" | jq -r '.username')
    groups_str=$(echo "$user" | jq -r '.groups | join(", ")')
    log_info "  • ${username}: ${groups_str}"
  done

  log_info "════════════════════════════════════════════════════════════════"
  log_info "  vpn-cli users: ssh <user>@10.100.0.1 <command>"
  log_info "  vpn-web users: WireGuard config in /etc/wireguard/users/<user>/"
  log_info "════════════════════════════════════════════════════════════════"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  mkdir -p "$SERVICE_DIR"

  setup_groups
  install_cli_wrappers
  sync_users
  print_summary

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
