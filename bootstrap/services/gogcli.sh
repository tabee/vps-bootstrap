#!/usr/bin/env bash
# =============================================================================
# services/gogcli.sh — Google Workspace CLI (SSH-basiert)
# =============================================================================
# Optional module.
#
# Installs:
#   - gogcli binary (gog) from https://gogcli.sh
#   - Config directory at /opt/gogcli
#
# Access model:
#   SSH → admin@10.100.0.1 → gog <service> <command>
#
# Security design:
#   - NO published ports
#   - NO REST API / HTTP endpoints
#   - Uses existing SSH infrastructure (VPN-only after hardening)
#   - Google OAuth credentials stored in /opt/gogcli with restricted perms
#
# Usage from other VPS (e.g., openclaw):
#   ssh admin@10.100.0.1 "gog gmail search 'is:unread' --max 10 --json"
#   ssh admin@10.100.0.1 "gog drive list --json"
#   ssh admin@10.100.0.1 "gog calendar events --json"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="gogcli"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

ADMIN_USER="${ADMIN_USER:-admin}"
GOGCLI_DIR="/opt/gogcli"
GOGCLI_BIN="/usr/local/bin/gog"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating gogcli directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $GOGCLI_DIR"
    return 0
  fi

  mkdir -p "${GOGCLI_DIR}"
  
  # Secure permissions (OAuth credentials will be stored here)
  chmod 700 "${GOGCLI_DIR}"
  
  # Set ownership to admin user (for gog auth commands)
  if id "$ADMIN_USER" &>/dev/null; then
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "${GOGCLI_DIR}"
  fi

  log_info "Created $GOGCLI_DIR"
}

# ── Install gogcli binary ────────────────────────────────────────────────────
install_binary() {
  log_step "Installing gogcli binary"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install gog binary to $GOGCLI_BIN"
    return 0
  fi

  # Check if already installed and working
  if [[ -x "$GOGCLI_BIN" ]]; then
    local current_version
    current_version=$("$GOGCLI_BIN" --version 2>/dev/null | head -1 || echo "unknown")
    log_info "gogcli already installed: $current_version"
    
    # Check for updates (optional, skip if recent)
    if [[ -f "${GOGCLI_DIR}/.last_update" ]]; then
      local last_update
      last_update=$(cat "${GOGCLI_DIR}/.last_update")
      local now
      now=$(date +%s)
      local age=$((now - last_update))
      # Skip update if less than 7 days old
      if [[ $age -lt 604800 ]]; then
        log_info "Skipping update check (last updated $((age / 86400)) days ago)"
        return 0
      fi
    fi
  fi

  # Get latest version
  log_info "Fetching latest gogcli release..."
  local latest_version
  latest_version=$(curl -sL https://api.github.com/repos/steipete/gogcli/releases/latest | grep tag_name | cut -d'"' -f4)
  
  if [[ -z "$latest_version" ]]; then
    log_warn "Could not determine latest version, using 'latest'"
    latest_version="latest"
  fi

  log_info "Installing gogcli $latest_version..."

  # Download binary
  local download_url="https://github.com/steipete/gogcli/releases/download/${latest_version}/gog_linux_amd64"
  local tmpfile
  tmpfile=$(mktemp)
  
  if ! curl -sL "$download_url" -o "$tmpfile"; then
    rm -f "$tmpfile"
    log_fatal "Failed to download gogcli from $download_url"
  fi

  # Verify it's a valid binary (not HTML error page)
  if ! file "$tmpfile" | grep -q "ELF"; then
    rm -f "$tmpfile"
    log_fatal "Downloaded file is not a valid binary"
  fi

  # Install
  chmod +x "$tmpfile"
  mv "$tmpfile" "$GOGCLI_BIN"
  
  # Verify installation
  if ! "$GOGCLI_BIN" --version &>/dev/null; then
    log_fatal "gogcli binary installed but not working"
  fi

  # Mark update time
  date +%s > "${GOGCLI_DIR}/.last_update"

  log_info "✅ Installed gogcli: $("$GOGCLI_BIN" --version 2>/dev/null | head -1)"
}

# ── Setup environment for admin user ─────────────────────────────────────────
setup_user_environment() {
  log_step "Setting up gogcli environment for $ADMIN_USER"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would configure environment for $ADMIN_USER"
    return 0
  fi

  if ! id "$ADMIN_USER" &>/dev/null; then
    log_warn "Admin user $ADMIN_USER does not exist yet"
    return 0
  fi

  local admin_home
  admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)

  # Create gog config symlink in user's home
  local user_config="${admin_home}/.config/gog"
  if [[ ! -L "$user_config" ]] && [[ ! -d "$user_config" ]]; then
    mkdir -p "${admin_home}/.config"
    ln -sf "$GOGCLI_DIR" "$user_config"
    chown -h "${ADMIN_USER}:${ADMIN_USER}" "$user_config"
    chown "${ADMIN_USER}:${ADMIN_USER}" "${admin_home}/.config"
    log_info "Created config symlink: $user_config -> $GOGCLI_DIR"
  fi

  # Add gog to PATH if not already there (via profile.d)
  local profile_script="/etc/profile.d/gogcli.sh"
  if [[ ! -f "$profile_script" ]]; then
    cat > "$profile_script" <<'EOF'
# gogcli - Google Workspace CLI
# Config: /opt/gogcli
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
EOF
    chmod 644 "$profile_script"
    log_info "Created $profile_script"
  fi

  log_info "Environment configured for $ADMIN_USER"
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_step "gogcli setup instructions"

  cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  gogcli (Google Workspace CLI) - Setup Required                             ║
╚══════════════════════════════════════════════════════════════════════════════╝

gogcli is installed. You need to authorize it with Google:

1. Create OAuth credentials:
   - Go to: https://console.cloud.google.com/apis/credentials
   - Create "OAuth 2.0 Client ID" → "Desktop app"
   - Download the JSON file

2. Copy credentials to the VPS:
   scp client_secret_*.json ${ADMIN_USER}@10.100.0.1:/opt/gogcli/

3. SSH to VPS and authorize:
   ssh ${ADMIN_USER}@10.100.0.1
   gog auth credentials /opt/gogcli/client_secret_*.json
   gog auth add your@gmail.com

4. Test it works:
   gog gmail labels list

5. From another VPS (e.g., openclaw), use via SSH:
   ssh ${ADMIN_USER}@10.100.0.1 "gog gmail search 'is:unread' --json"
   ssh ${ADMIN_USER}@10.100.0.1 "gog drive list --json"

Available services: gmail, calendar, drive, sheets, docs, slides, contacts, tasks

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_binary
  setup_user_environment
  print_setup_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
