#!/usr/bin/env bash
# =============================================================================
# services/open-webui.sh — Open WebUI AI chat interface (Traefik)
# =============================================================================
# Deploys:
#   - Open WebUI container at 10.20.0.60
#
# Architecture:
#   VPN → Traefik:443 → ai.<domain> → Open WebUI:8080
#   Open WebUI → Ollama at http://10.20.0.80:11434 (if enabled)
#
# Security design:
#   - NO published ports — access exclusively via Traefik
#   - vpn-only middleware: only VPN clients can reach the web UI
#   - Data persisted in /opt/open-webui/data/
#   - no-new-privileges enabled
#
# Prerequisites:
#   - Traefik must be running (core/05-traefik.sh)
#   - Optionally: Ollama (services/ollama.sh) for local model support
#
# Usage:
#   Browser → https://ai.YOUR_DOMAIN (VPN connected)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="open-webui"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

VPN_DOMAIN="${VPN_DOMAIN:-example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"

# Optional: OpenAI API key for cloud models in Open WebUI
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

# Optional: Ollama backend (internal Docker network)
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://10.20.0.80:11434}"

OPEN_WEBUI_DIR="/opt/open-webui"
TRAEFIK_DYNAMIC="/opt/traefik/dynamic.yml"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Open WebUI directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $OPEN_WEBUI_DIR"
    return 0
  fi

  mkdir -p "${OPEN_WEBUI_DIR}/data"

  # Open WebUI runs as UID 0 inside container
  chmod 755 "${OPEN_WEBUI_DIR}"
  chmod 755 "${OPEN_WEBUI_DIR}/data"

  log_info "Created $OPEN_WEBUI_DIR"
}

# ── Generate .env file ──────────────────────────────────────────────────────
install_env_file() {
  log_step "Installing Open WebUI .env file"

  local env_file="${OPEN_WEBUI_DIR}/.env"

  local content
  content="$(cat <<EOF
# Open WebUI configuration
VPN_DOMAIN=${VPN_DOMAIN}

# Ollama backend (internal Docker network)
OLLAMA_BASE_URL=${OLLAMA_BASE_URL}

# Optional: OpenAI API key for cloud models
OPENAI_API_KEY=${OPENAI_API_KEY}
EOF
)"

  if file_matches "$env_file" "$content"; then
    log_info ".env already up to date"
    return 0
  fi

  install_content "$content" "$env_file" "0600"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Open WebUI docker-compose.yml"

  local compose_file="${OPEN_WEBUI_DIR}/docker-compose.yml"

  # SECURITY NOTES:
  # - NO "ports:" directive — Traefik routes to container IP
  # - vpn-only middleware enforced at Traefik level
  # - Data persisted in /opt/open-webui/data/
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Open WebUI AI chat interface
# =============================================================================
# NO ports: directive. Access via Traefik only.
#
# URL: https://ai.YOUR_DOMAIN (VPN required)

services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    env_file: .env
    environment:
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      # Disable telemetry
      - SCARF_NO_ANALYTICS=true
      - DO_NOT_TRACK=true
      - ANONYMIZED_TELEMETRY=false
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./data:/app/backend/data
    networks:
      vpn_net:
        ipv4_address: 10.20.0.60

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
  log_step "Ensuring Traefik route exists for ai.${VPN_DOMAIN}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would patch ${TRAEFIK_DYNAMIC}"
    return 0
  fi

  if [[ ! -f "$TRAEFIK_DYNAMIC" ]]; then
    log_fatal "Traefik dynamic config not found at ${TRAEFIK_DYNAMIC}. Run core/05-traefik first."
  fi

  # Idempotency: do nothing if router already exists
  if grep -qE '^\s*open-webui:\s*$' "$TRAEFIK_DYNAMIC"; then
    log_info "Traefik router 'open-webui' already present"
    return 0
  fi

  VPN_DOMAIN="$VPN_DOMAIN" TRAEFIK_DYNAMIC="$TRAEFIK_DYNAMIC" python3 - <<'PY'
from pathlib import Path
import os

vpn_domain = os.environ["VPN_DOMAIN"]
path = os.environ["TRAEFIK_DYNAMIC"]
p = Path(path)
text = p.read_text(encoding="utf-8")

router_snip = f"""

    # Open WebUI AI chat interface
    open-webui:
      entryPoints: ["websecure"]
      rule: "Host(`ai.{vpn_domain}`)"
      middlewares: ["vpn-only"]
      service: open-webui-svc
      tls:
        certResolver: le
"""

service_snip = """

    open-webui-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.60:8080"
"""

if "\n    open-webui:\n" in text or "\n    open-webui-svc:\n" in text:
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

  log_info "✅ Added Traefik router+service for ai.${VPN_DOMAIN}"
}

# ── Deploy Open WebUI stack ──────────────────────────────────────────────────
deploy_open_webui() {
  log_step "Deploying Open WebUI stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy Open WebUI via docker compose"
    return 0
  fi

  cd "${OPEN_WEBUI_DIR}"

  docker compose pull --quiet
  docker compose up -d --remove-orphans

  # Wait for container
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=^/open-webui$" --filter "status=running" --format '{{.Names}}' | grep -q '^open-webui$'; then
      log_info "✅ Open WebUI container running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "Open WebUI may not be fully started yet"
  docker compose logs
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_step "Open WebUI setup instructions"

  cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  Open WebUI — AI Chat Interface                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

1. Connect VPN
2. Open in browser: https://ai.${VPN_DOMAIN}
3. Create an admin account on first visit

EOF

  if [[ -n "$OPENAI_API_KEY" ]]; then
    cat <<EOF
OpenAI API key configured — cloud models available in Settings → Models.
EOF
  else
    cat <<EOF
No OpenAI API key configured. Add to terraform.tfvars:
  openai_api_key = "sk-..."

EOF
  fi

  cat <<EOF
For local models, ensure Ollama is enabled:
  enable_ollama = true
Then pull a model:
  ssh ${ADMIN_USER}@10.100.0.1
  ollama pull llama3.2

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_env_file
  install_compose_file
  patch_traefik_routes
  deploy_open_webui
  print_setup_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
