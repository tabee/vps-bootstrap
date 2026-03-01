#!/usr/bin/env bash
# =============================================================================
# init-env.sh — Initialize .env and generate secrets for VPS bootstrap
# =============================================================================
# On first run: copies .env.example → .env, auto-generates all secrets
# except HETZNER_API_TOKEN, and writes a wg0-client.conf for VPN access.
#
# Usage:
#   sudo bash bootstrap/init-env.sh           # First-run init (creates .env)
#   sudo bash bootstrap/init-env.sh --rotate  # Rotate auto-generated secrets
#        bash bootstrap/init-env.sh --client  # (Re)print wg0-client.conf
#
# Called automatically by apply.sh before preflight checks.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="init-env"

ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
CLIENT_CONF="${SCRIPT_DIR}/wg0-client.conf"

ROTATE=false
SHOW_CLIENT=false

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate|-r)   ROTATE=true;      shift ;;
    --client|-c)   SHOW_CLIENT=true; shift ;;
    --help|-h)
      grep '^#' "$0" | head -15 | tail -12 | sed 's/^# \?//'
      exit 0
      ;;
    *) log_fatal "Unknown option: $1 (use --help)" ;;
  esac
done

# ── Helper: set or replace a variable in .env ────────────────────────────────
# Uses | as delimiter so base64 chars (A-Z a-z 0-9 + / =) are safe.
_set_var() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# ── Ensure wireguard-tools is installed ──────────────────────────────────────
_ensure_wg() {
  if command -v wg &>/dev/null; then return 0; fi
  log_info "Installing wireguard-tools for key generation..."
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wireguard-tools >/dev/null 2>&1 || true
  fi
  if ! command -v wg &>/dev/null; then
    log_fatal "wg not found — install manually: apt-get install wireguard-tools"
  fi
}

# ── Detect the server's public IPv4 ─────────────────────────────────────────
_server_ip() {
  local ip
  ip="$(curl -sf --connect-timeout 5 https://ifconfig.me 2>/dev/null)" \
    && printf '%s' "$ip" && return 0
  ip="$(curl -sf --connect-timeout 5 https://api.ipify.org 2>/dev/null)" \
    && printf '%s' "$ip" && return 0
  printf '%s' "YOUR_SERVER_IP"
}

# ── Write wg0-client.conf ────────────────────────────────────────────────────
_write_client_conf() {
  local client_privkey="$1" server_pubkey="$2" server_ip="$3"

  # Write to tmp, then move atomically (avoids world-readable intermediate)
  local tmpf
  tmpf="$(mktemp "${CLIENT_CONF}.XXXXXX")"
  chmod 0600 "$tmpf"

  cat > "$tmpf" <<WG
# =============================================================================
# wg0-client.conf — WireGuard client configuration
# =============================================================================
# Copy to your WireGuard client:
#   Linux:       cp wg0-client.conf /etc/wireguard/wg0.conf && wg-quick up wg0
#   macOS:       WireGuard.app → Add Tunnel → Import from File
#   Android/iOS: wg showconf wg0 | qrencode -t ansiutf8
# =============================================================================

[Interface]
PrivateKey = ${client_privkey}
Address    = 10.100.0.2/24
DNS        = 10.100.0.1

[Peer]
# VPS Server
PublicKey           = ${server_pubkey}
Endpoint            = ${server_ip}:51820
AllowedIPs          = 10.100.0.0/24, 10.20.0.0/24
PersistentKeepalive = 25
WG

  mv -f "$tmpf" "$CLIENT_CONF"
  log_info "✅ wg0-client.conf  → ${CLIENT_CONF}"
}

# ── Print client conf to stderr + stdout ────────────────────────────────────
_print_client_conf() {
  if [[ ! -f "$CLIENT_CONF" ]]; then
    log_error "wg0-client.conf not found — run: sudo bash ${SCRIPT_DIR}/init-env.sh --rotate"
    return 1
  fi
  echo "" >&2
  log_step "══════════════════════════════════════════════════════════════"
  log_step " wg0-client.conf — copy this to your VPN client"
  log_step "══════════════════════════════════════════════════════════════"
  cat "$CLIENT_CONF"
  echo "" >&2
}

# ── Generate all auto-managed secrets and inject into .env ──────────────────
_generate_secrets() {
  _ensure_wg

  log_step "Generating secrets..."

  # WireGuard: server keypair (server-side only)
  local srv_priv srv_pub
  srv_priv="$(wg genkey)"
  srv_pub="$(printf '%s' "$srv_priv" | wg pubkey)"

  # WireGuard: client keypair (client private key stored in .env for conf regen)
  local cli_priv cli_pub
  cli_priv="$(wg genkey)"
  cli_pub="$(printf '%s' "$cli_priv" | wg pubkey)"

  # Application secrets
  local db_pass gitea_secret gitea_token n8n_db_pass n8n_enc n8n_basic_pass
  db_pass="$(openssl rand -base64 32 | tr -d '\n')"
  gitea_secret="$(openssl rand -base64 48 | tr -d '\n')"
  gitea_token="$(openssl rand -base64 48 | tr -d '\n')"

  # Optional modules: n8n
  n8n_db_pass="$(openssl rand -base64 32 | tr -d '\n')"
  n8n_enc="$(openssl rand -base64 48 | tr -d '\n')"
  n8n_basic_pass="$(openssl rand -base64 24 | tr -d '\n')"

  # Inject into .env (preserves HETZNER_API_TOKEN and ACME_EMAIL untouched)
  _set_var "WG_PRIVATE_KEY"       "$srv_priv"
  _set_var "WG_CLIENT_PRIVKEY"    "$cli_priv"
  _set_var "WG_PEER_PUBKEY"       "$cli_pub"
  _set_var "DB_PASSWORD"          "$db_pass"
  _set_var "GITEA_SECRET_KEY"     "$gitea_secret"
  _set_var "GITEA_INTERNAL_TOKEN" "$gitea_token"

  # Optional modules: n8n
  _set_var "N8N_DB_PASSWORD"        "$n8n_db_pass"
  _set_var "N8N_ENCRYPTION_KEY"     "$n8n_enc"
  _set_var "N8N_BASIC_AUTH_USER"    "admin"
  _set_var "N8N_BASIC_AUTH_PASSWORD" "$n8n_basic_pass"

  log_info "✅ WG_PRIVATE_KEY       (server private key)"
  log_info "✅ WG_CLIENT_PRIVKEY    (client private key → wg0-client.conf)"
  log_info "✅ WG_PEER_PUBKEY       (client public key)"
  log_info "✅ DB_PASSWORD"
  log_info "✅ GITEA_SECRET_KEY"
  log_info "✅ GITEA_INTERNAL_TOKEN"
  log_info "✅ N8N_DB_PASSWORD"
  log_info "✅ N8N_ENCRYPTION_KEY"
  log_info "✅ N8N_BASIC_AUTH_USER"
  log_info "✅ N8N_BASIC_AUTH_PASSWORD"

  # Detect server IP and write client config
  log_info "Detecting server public IP..."
  local server_ip
  server_ip="$(_server_ip)"
  if [[ "$server_ip" == "YOUR_SERVER_IP" ]]; then
    log_warn "Could not auto-detect server IP — set Endpoint manually in ${CLIENT_CONF}"
  else
    log_info "Server IP: ${server_ip}"
  fi

  _write_client_conf "$cli_priv" "$srv_pub" "$server_ip"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  # ── --client: print wg0-client.conf and exit ─────────────────────────────
  if [[ "$SHOW_CLIENT" == "true" ]]; then
    _print_client_conf
    return 0
  fi

  # ── --rotate: regenerate all auto-generated secrets ──────────────────────
  if [[ "$ROTATE" == "true" ]]; then
    require_root
    if [[ ! -f "$ENV_FILE" ]]; then
      log_fatal ".env not found — run init first: sudo bash ${SCRIPT_DIR}/init-env.sh"
    fi
    log_step "Rotating auto-generated secrets (HETZNER_API_TOKEN and ACME_EMAIL preserved)..."
    _generate_secrets
    echo "" >&2
    log_warn "⚠️  WireGuard keys rotated — re-run apply.sh to deploy new server config,"
    log_warn "   then update your VPN client with the new wg0-client.conf:"
    _print_client_conf
    return 0
  fi

  # ── Normal / first-run init ───────────────────────────────────────────────
  if [[ ! -f "$ENV_FILE" ]]; then
    # ── First run: create .env and generate all secrets ──────────────────
    require_root
    log_step "First run — creating .env from .env.example"
    install -m 0600 "$ENV_EXAMPLE" "$ENV_FILE"
    log_info ".env created at ${ENV_FILE}"
    _generate_secrets

    echo "" >&2
    log_step "══════════════════════════════════════════════════════════════"
    log_step "  ⚠️  ACTION REQUIRED — set HETZNER_API_TOKEN"
    log_step "══════════════════════════════════════════════════════════════"
    log_warn ""
    log_warn "  .env has been created with auto-generated secrets."
    log_warn "  One value requires your input:"
    log_warn ""
    log_warn "    1. Open:  ${ENV_FILE}"
    log_warn "    2. Set:   HETZNER_API_TOKEN=<your-hetzner-dns-api-token>"
    log_warn "       Get a token at: https://dns.hetzner.com/settings/api-token"
    log_warn ""
    log_warn "    3. Re-run: sudo bash ${SCRIPT_DIR}/apply.sh"
    log_warn ""
    log_warn "  Your VPN client config is ready (fill in server IP first):"
    log_warn "    ${CLIENT_CONF}"
    log_step "══════════════════════════════════════════════════════════════"
    echo "" >&2
    exit 1   # Signal to apply.sh: stop here, user action needed
  fi

  # ── .env exists: check HETZNER_API_TOKEN ─────────────────────────────────
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  local token="${HETZNER_API_TOKEN:-}"
  if [[ -z "$token" || "$token" == *"__"* ]]; then
    echo "" >&2
    log_error "❌ HETZNER_API_TOKEN not set in .env"
    log_error "   Edit:   ${ENV_FILE}"
    log_error "   Then:   sudo bash ${SCRIPT_DIR}/apply.sh"
    echo "" >&2
    exit 1
  fi

  # ── Check for un-generated placeholder values ─────────────────────────────
  local needs_regen=false
  for var in WG_PRIVATE_KEY WG_PEER_PUBKEY DB_PASSWORD GITEA_SECRET_KEY GITEA_INTERNAL_TOKEN; do
    local val="${!var:-}"
    if [[ -z "$val" || "$val" == *"__"* ]]; then
      log_warn "⚠️  ${var} still has a placeholder — regenerating auto-generated secrets"
      needs_regen=true
      break
    fi
  done

  if [[ "$needs_regen" == "true" ]]; then
    require_root
    _generate_secrets
    log_info "✅ Auto-generated secrets replaced"
  else
    log_info "✅ .env initialized — all core secrets present"

    # ── Optional module secrets (non-disruptive) ─────────────────────────
    # Add/repair optional secrets WITHOUT rotating WireGuard keys or core secrets.
    # This keeps upgrades safe when new modules are added over time.
    local opt_changed=false

    if [[ -z "${N8N_DB_PASSWORD:-}" || "${N8N_DB_PASSWORD:-}" == *"__"* ]]; then
      require_root
      local v
      v="$(openssl rand -base64 32 | tr -d '\n')"
      _set_var "N8N_DB_PASSWORD" "$v"
      opt_changed=true
      log_info "✅ N8N_DB_PASSWORD generated"
    fi

    if [[ -z "${N8N_ENCRYPTION_KEY:-}" || "${N8N_ENCRYPTION_KEY:-}" == *"__"* ]]; then
      require_root
      local v
      v="$(openssl rand -base64 48 | tr -d '\n')"
      _set_var "N8N_ENCRYPTION_KEY" "$v"
      opt_changed=true
      log_info "✅ N8N_ENCRYPTION_KEY generated"
    fi

    if [[ -z "${N8N_BASIC_AUTH_USER:-}" || "${N8N_BASIC_AUTH_USER:-}" == *"__"* ]]; then
      require_root
      _set_var "N8N_BASIC_AUTH_USER" "admin"
      opt_changed=true
      log_info "✅ N8N_BASIC_AUTH_USER set to 'admin'"
    fi

    if [[ -z "${N8N_BASIC_AUTH_PASSWORD:-}" || "${N8N_BASIC_AUTH_PASSWORD:-}" == *"__"* ]]; then
      require_root
      local v
      v="$(openssl rand -base64 24 | tr -d '\n')"
      _set_var "N8N_BASIC_AUTH_PASSWORD" "$v"
      opt_changed=true
      log_info "✅ N8N_BASIC_AUTH_PASSWORD generated"
    fi

    if [[ "$opt_changed" == "true" ]]; then
      chmod 0600 "$ENV_FILE" 2>/dev/null || true
      log_info "✅ Optional module secrets updated in .env"
    fi
  fi

  # ── Ensure wg0-client.conf exists ────────────────────────────────────────
  if [[ ! -f "$CLIENT_CONF" ]]; then
    log_warn "wg0-client.conf missing — regenerating from .env..."
    local cli_priv="${WG_CLIENT_PRIVKEY:-}"
    local srv_priv="${WG_PRIVATE_KEY:-}"
    if [[ -n "$cli_priv" && -n "$srv_priv" ]]; then
      _ensure_wg
      local srv_pub
      srv_pub="$(printf '%s' "$srv_priv" | wg pubkey)"
      local server_ip
      server_ip="$(_server_ip)"
      _write_client_conf "$cli_priv" "$srv_pub" "$server_ip"
    else
      log_warn "WG_CLIENT_PRIVKEY not found in .env — cannot regenerate wg0-client.conf"
      log_warn "Run: sudo bash ${SCRIPT_DIR}/init-env.sh --rotate"
    fi
  fi
}

main "$@"
