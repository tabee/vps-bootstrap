#!/usr/bin/env bash
# =============================================================================
# services/uptime-kuma.sh — Uptime Kuma monitoring service
# =============================================================================
# Optional module.
#
# Deploys:
#   - Uptime Kuma at 10.20.0.70
#
# Access model:
#   VPN → Traefik:443 → status.<domain> → Uptime Kuma:3001 (HTTP)
#
# Security design:
#   - NO published ports (no `ports:` directive)
#   - Traffic must go through Traefik + vpn-only middleware (ipAllowList)
#   - First user to register becomes administrator
#   - no-new-privileges enabled
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="uptime-kuma"

# Load environment from .env
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

VPN_DOMAIN="${VPN_DOMAIN:-example.com}"
UPTIME_KUMA_DIR="/opt/uptime-kuma"
TRAEFIK_DYNAMIC="/opt/traefik/dynamic.yml"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Uptime Kuma directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $UPTIME_KUMA_DIR"
    return 0
  fi

  mkdir -p "${UPTIME_KUMA_DIR}/data"

  log_info "Created $UPTIME_KUMA_DIR"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Uptime Kuma docker-compose.yml"

  local compose_file="${UPTIME_KUMA_DIR}/docker-compose.yml"

  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Uptime Kuma monitoring service
# =============================================================================
# NO ports: directive — accessible only via Traefik (10.20.0.10).

services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./data:/app/data
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
  if grep -qE '^\s*uptime-kuma:\s*$' "$TRAEFIK_DYNAMIC"; then
    log_info "Traefik router 'uptime-kuma' already present"
    return 0
  fi

  # Patch file content deterministically (Traefik uses file provider).
  # We insert:
  #   - router `uptime-kuma` under http.routers
  #   - service `uptime-kuma-svc` under http.services
  # right next to the existing entries.

  # IMPORTANT: This heredoc is single-quoted so bash does NOT interpret backticks
  # in the Traefik Host(`...`) rule.
  VPN_DOMAIN="$VPN_DOMAIN" TRAEFIK_DYNAMIC="$TRAEFIK_DYNAMIC" python3 - <<'PY'
from pathlib import Path
import os

vpn_domain = os.environ["VPN_DOMAIN"]
path = os.environ["TRAEFIK_DYNAMIC"]
p = Path(path)
text = p.read_text(encoding="utf-8")

router_snip = f"""

    # Uptime Kuma monitoring UI
    uptime-kuma:
      entryPoints: ["websecure"]
      rule: "Host(`status.{vpn_domain}`)"
      middlewares: ["vpn-only"]
      service: uptime-kuma-svc
      tls:
        certResolver: le
"""

service_snip = """

    uptime-kuma-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.70:3001"
"""

if "\n    uptime-kuma:\n" in text or "\n    uptime-kuma-svc:\n" in text:
    # Already patched (or partially patched). Keep idempotent.
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
}

# ── Deploy Uptime Kuma ──────────────────────────────────────────────────────
deploy_uptime_kuma() {
  log_step "Deploying Uptime Kuma"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy Uptime Kuma via docker compose"
    return 0
  fi

  cd "${UPTIME_KUMA_DIR}"

  docker compose pull --quiet
  docker compose up -d --remove-orphans

  # Wait for container
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=uptime-kuma" --filter "status=running" --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
      log_info "Uptime Kuma container is running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "Uptime Kuma may not be fully started yet"
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_info ""
  log_info "╔══════════════════════════════════════════════════════════════╗"
  log_info "║           Uptime Kuma — Setup Instructions                  ║"
  log_info "╚══════════════════════════════════════════════════════════════╝"
  log_info ""
  log_info "  URL:   https://status.${VPN_DOMAIN}  (VPN required)"
  log_info ""
  log_info "  First steps:"
  log_info "    1. Open https://status.${VPN_DOMAIN} in your browser"
  log_info "    2. Create an admin account (first user becomes administrator)"
  log_info "    3. Add monitors for your services"
  log_info ""
  log_info "  Data stored in: ${UPTIME_KUMA_DIR}/data/"
  log_info ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  patch_traefik_routes
  deploy_uptime_kuma
  print_setup_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
