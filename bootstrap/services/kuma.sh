#!/usr/bin/env bash
# =============================================================================
# services/kuma.sh — Uptime Kuma Monitoring (VPN-only via Traefik)
# =============================================================================
# Deploys:
#   - Uptime Kuma at 10.20.0.70
#
# Architecture:
#   VPN → Traefik:443 → status.<domain> → Kuma:3001 (HTTP)
#
# Security design:
#   - NO published ports (no `ports:` directive)
#   - Traffic must go through Traefik + vpn-only middleware (ipAllowList)
#   - SQLite database (no external DB needed)
#   - Containers with no-new-privileges + capability drop
#
# Monitoring:
#   - Can monitor all internal services on vpn_net
#   - HTTP(S), TCP, Ping, DNS, Docker, and more
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="kuma"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

VPN_DOMAIN="${VPN_DOMAIN:-example.com}"
KUMA_ADMIN_USER="${KUMA_ADMIN_USER:-kuma-admin}"
KUMA_ADMIN_PASSWORD="${KUMA_ADMIN_PASSWORD:-}"

# Service flags from bootstrap .env
ENABLE_WHOAMI="${ENABLE_WHOAMI:-false}"
ENABLE_GITEA="${ENABLE_GITEA:-false}"
ENABLE_N8N="${ENABLE_N8N:-false}"
ENABLE_MKDOCS="${ENABLE_MKDOCS:-false}"

KUMA_DIR="/opt/kuma"
TRAEFIK_DYNAMIC="/opt/traefik/dynamic.yml"
TRAEFIK_ACME_STATE_FILE="/opt/traefik/.acme-active"

traefik_https_tls_block() {
  if [[ -f "$TRAEFIK_ACME_STATE_FILE" ]] && grep -qx 'true' "$TRAEFIK_ACME_STATE_FILE"; then
    cat <<'YAML'
      tls:
        certResolver: le
YAML
  else
    echo '      tls: {}'
  fi
}

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Uptime Kuma directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $KUMA_DIR"
    return 0
  fi

  mkdir -p "${KUMA_DIR}/data"

  # Uptime Kuma runs as node user (UID 1000) in the official image
  chown -R 1000:1000 "${KUMA_DIR}/data"

  log_info "Created $KUMA_DIR"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Uptime Kuma docker-compose.yml"

  local compose_file="${KUMA_DIR}/docker-compose.yml"

  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Uptime Kuma
# =============================================================================
# NO ports: directive — accessible only via Traefik (10.20.0.10).
# Monitors internal services on the vpn_net network.

services:
  kuma:
    image: louislam/uptime-kuma:1
    container_name: kuma
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop: ["ALL"]
    cap_add: ["CHOWN", "SETUID", "SETGID"]
    volumes:
      - ./data:/app/data
      # Docker socket for container monitoring (optional, read-only)
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - TZ=Europe/Zurich
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --spider http://localhost:3001/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      vpn_net:
        ipv4_address: 10.20.0.70

networks:
  vpn_net:
    external: true
YAML
)"

  if file_matches "$compose_file" "$content"; then
    log_info "docker-compose.yml already up to date"
    return 0
  fi

  install_content "$content" "$compose_file" "0644"
}

# ── Patch Traefik dynamic.yml ───────────────────────────────────────────────
patch_traefik_routes() {
  log_step "Ensuring Traefik route exists for status.${VPN_DOMAIN}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would patch ${TRAEFIK_DYNAMIC}"
    return 0
  fi

  if [[ ! -f "$TRAEFIK_DYNAMIC" ]]; then
    log_fatal "Traefik dynamic config not found at ${TRAEFIK_DYNAMIC}. Run core/05-traefik first."
  fi

  # Idempotency: do nothing if router already exists
  if grep -qE '^\s*kuma:\s*$' "$TRAEFIK_DYNAMIC"; then
    log_info "Traefik router 'kuma' already present"
    return 0
  fi

  local tls_block
  tls_block="$(traefik_https_tls_block)"

  VPN_DOMAIN="$VPN_DOMAIN" TRAEFIK_DYNAMIC="$TRAEFIK_DYNAMIC" TLS_BLOCK="$tls_block" python3 - <<'PY'
from pathlib import Path
import os

vpn_domain = os.environ["VPN_DOMAIN"]
path = os.environ["TRAEFIK_DYNAMIC"]
tls_block = os.environ["TLS_BLOCK"]
p = Path(path)
text = p.read_text(encoding="utf-8")

router_snip = f"""

    # Uptime Kuma monitoring
    kuma:
      entryPoints: ["websecure"]
      rule: "Host(`status.{vpn_domain}`)"
      middlewares: ["vpn-only"]
      service: kuma-svc
{tls_block}
"""

service_snip = """

    kuma-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.70:3001"
"""

if "\n    kuma:\n" in text or "\n    kuma-svc:\n" in text:
    # Already patched (or partially patched). Keep idempotent.
    p.write_text(text, encoding="utf-8")
    raise SystemExit(0)

needle_services = "\n  services:\n"
if needle_services not in text:
    raise SystemExit("Could not find 'http.services' section in Traefik dynamic.yml")

text = text.replace(needle_services, router_snip + needle_services, 1)

needle_tcp = "\n# ── TCP routers"
if needle_tcp not in text:
    needle_tcp = "\ntcp:\n"
    if needle_tcp not in text:
        raise SystemExit("Could not find tcp section in Traefik dynamic.yml")
    text = text.replace(needle_tcp, service_snip + needle_tcp, 1)
else:
    text = text.replace(needle_tcp, service_snip + needle_tcp, 1)

p.write_text(text, encoding="utf-8")
PY

  chmod 0644 "$TRAEFIK_DYNAMIC"

  log_info "✅ Added Traefik router+service for status.${VPN_DOMAIN}"

  # Reload Traefik to pick up new routes (bind-mount doesn't always trigger inotify)
  if docker ps --filter "name=^/traefik$" --format '{{.Names}}' | grep -q '^traefik$'; then
    log_info "Restarting Traefik to apply new routes..."
    (cd /opt/traefik && docker compose restart traefik) || log_warn "Failed to restart Traefik"
  fi
}

# ── Deploy kuma stack ───────────────────────────────────────────────────────
deploy_kuma() {
  log_step "Deploying Uptime Kuma stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy kuma via docker compose"
    return 0
  fi

  cd "${KUMA_DIR}"

  # NOTE: Avoid a separate `docker compose pull`, which can hang indefinitely
  # in non-interactive Terraform remote-exec sessions. `up -d` pulls missing
  # images automatically.
  docker compose up -d --remove-orphans

  # Wait for kuma container and health check
  log_info "Waiting for Uptime Kuma to start..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if docker ps --filter "name=^/kuma$" --filter "status=running" --format '{{.Names}}' | grep -q '^kuma$'; then
      # Check health status
      local health
      health=$(docker inspect --format='{{.State.Health.Status}}' kuma 2>/dev/null || echo "unknown")
      if [[ "$health" == "healthy" ]]; then
        log_info "Uptime Kuma is healthy"
        return 0
      fi
    fi
    sleep 2
    i=$((i + 2))
  done

  if docker ps --filter "name=^/kuma$" --filter "status=running" --format '{{.Names}}' | grep -q '^kuma$'; then
    log_info "Uptime Kuma container is running (health check pending)"
    return 0
  fi

  log_warn "Uptime Kuma may not be fully started yet"
}

# ── Provision admin user ─────────────────────────────────────────────────────
provision_admin_user() {
  log_step "Provisioning Uptime Kuma admin user"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would provision admin user '${KUMA_ADMIN_USER}'"
    return 0
  fi

  if [[ -z "$KUMA_ADMIN_PASSWORD" ]]; then
    log_warn "KUMA_ADMIN_PASSWORD not set, skipping admin provisioning"
    return 0
  fi

  local db_file="${KUMA_DIR}/data/kuma.db"

  # Wait for database to be created by Kuma
  local i=0
  while [[ ! -f "$db_file" ]] && [[ $i -lt 30 ]]; do
    sleep 2
    i=$((i + 2))
  done

  if [[ ! -f "$db_file" ]]; then
    log_warn "Database not found, admin user will be created on first visit"
    return 0
  fi

  # Check if any user exists
  local user_count
  user_count=$(docker exec kuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user" 2>/dev/null || echo "0")

  if [[ "$user_count" -gt 0 ]]; then
    log_info "Admin user already exists, skipping provisioning"
    return 0
  fi

  log_info "Creating admin user '${KUMA_ADMIN_USER}'..."

  # Hash password using bcryptjs in the Kuma container
  docker exec -e PASSWORD="$KUMA_ADMIN_PASSWORD" -e USERNAME="$KUMA_ADMIN_USER" kuma node -e '
const bcryptjs = require("bcryptjs");
const hash = bcryptjs.hashSync(process.env.PASSWORD, 10);
const username = process.env.USERNAME;
const fs = require("fs");
const Database = require("better-sqlite3");

const db = new Database("/app/data/kuma.db");
db.exec(`
  INSERT INTO user (username, password, active) 
  VALUES ("${username}", "${hash}", 1)
`);
db.close();
console.log("User created: " + username);
'

  log_info "Admin user '${KUMA_ADMIN_USER}' created successfully"
}

# ── Provision monitors for enabled services ──────────────────────────────────
provision_monitors() {
  log_step "Provisioning monitors for enabled services"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would provision monitors based on enabled services"
    return 0
  fi

  local db_file="${KUMA_DIR}/data/kuma.db"

  if [[ ! -f "$db_file" ]]; then
    log_warn "Database not found, skipping monitor provisioning"
    return 0
  fi

  # Get user_id (first user)
  local user_id
  user_id=$(docker exec kuma sqlite3 /app/data/kuma.db "SELECT id FROM user LIMIT 1" 2>/dev/null || echo "")

  if [[ -z "$user_id" ]]; then
    log_warn "No user found, skipping monitor provisioning"
    return 0
  fi

  # Check if monitors already exist
  local monitor_count
  monitor_count=$(docker exec kuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM monitor" 2>/dev/null || echo "0")

  if [[ "$monitor_count" -gt 0 ]]; then
    log_info "Monitors already exist ($monitor_count found), skipping provisioning"
    return 0
  fi

  log_info "Creating monitors for enabled services..."

  # Build monitor definitions based on enabled services
  local monitors=()

  # Always add Traefik (via whoami) if whoami is enabled
  if [[ "$ENABLE_WHOAMI" == "true" ]]; then
    monitors+=("Traefik (via whoami)|http|http://10.20.0.20:80/||")
  fi

  # Gitea and its PostgreSQL
  if [[ "$ENABLE_GITEA" == "true" ]]; then
    monitors+=("Gitea|http|http://10.20.0.30:3000/api/healthz||")
    monitors+=("PostgreSQL (Gitea)|port||10.20.0.31|5432")
  fi

  # n8n and its PostgreSQL
  if [[ "$ENABLE_N8N" == "true" ]]; then
    monitors+=("n8n|http|http://10.20.0.40:5678/healthz||")
    monitors+=("PostgreSQL (n8n)|port||10.20.0.41|5432")
  fi

  # MkDocs
  if [[ "$ENABLE_MKDOCS" == "true" ]]; then
    monitors+=("MkDocs|http|http://10.20.0.60:8080/||")
  fi

  # Insert monitors using Node.js in the container
  for m in "${monitors[@]}"; do
    IFS='|' read -r name type url hostname port <<< "$m"
    
    docker exec -e NAME="$name" -e TYPE="$type" -e URL="$url" -e HOSTNAME="$hostname" -e PORT="$port" -e USER_ID="$user_id" kuma node -e '
const Database = require("better-sqlite3");
const db = new Database("/app/data/kuma.db");

const name = process.env.NAME;
const type = process.env.TYPE;
const url = process.env.URL || "";
const hostname = process.env.HOSTNAME || "";
const port = process.env.PORT ? parseInt(process.env.PORT) : null;
const userId = parseInt(process.env.USER_ID);

const stmt = db.prepare(`
  INSERT INTO monitor (name, active, user_id, interval, url, type, hostname, port, accepted_statuscodes_json)
  VALUES (?, 1, ?, 60, ?, ?, ?, ?, ?)
`);

const statusCodes = type === "http" ? JSON.stringify(["200"]) : JSON.stringify(["200-299"]);
stmt.run(name, userId, url, type, hostname || null, port, statusCodes);
db.close();
console.log("Monitor created: " + name);
' 2>/dev/null || log_warn "Failed to create monitor: $name"
  done

  log_info "Monitors provisioned successfully"
}

# ── Print post-deploy instructions ──────────────────────────────────────────
print_instructions() {
  log_step "Uptime Kuma deployment complete"

  echo "" >&2
  log_info "════════════════════════════════════════════════════════════════"
  log_info "  Uptime Kuma Monitoring"
  log_info "════════════════════════════════════════════════════════════════"
  log_info "  URL:       https://status.${VPN_DOMAIN}"
  if [[ -n "$KUMA_ADMIN_PASSWORD" ]]; then
    log_info "  User:      ${KUMA_ADMIN_USER}"
    log_info "  Password:  (see terraform output -json credentials | jq '.kuma')"
  else
    log_info "  Setup:     Create admin account on first visit"
  fi
  log_info "  Data:      ${KUMA_DIR}/data/"
  log_info "════════════════════════════════════════════════════════════════"
  echo "" >&2
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  patch_traefik_routes
  deploy_kuma
  provision_admin_user
  provision_monitors
  print_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
