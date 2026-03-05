#!/usr/bin/env bash
# =============================================================================
# services/whoami.sh — whoami diagnostic service
# =============================================================================
# Deploys a minimal HTTP echo service for verifying:
#   - Traefik routing works
#   - TLS certificate provisioning works
#   - VPN-only access control works
#   - DNS resolution works (whoami.<domain> → 10.20.0.10)
#
# Security design:
#   - NO published ports
#   - Read-only root filesystem
#   - no-new-privileges
#   - Accessible only through Traefik with vpn-only middleware
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="whoami"

WHOAMI_DIR="/opt/whoami"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating whoami directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $WHOAMI_DIR"
    return 0
  fi

  mkdir -p "$WHOAMI_DIR"
  log_info "Created $WHOAMI_DIR"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing whoami docker-compose.yml"

  local compose_file="${WHOAMI_DIR}/docker-compose.yml"

  # Minimal service: no ports, read-only, hardened
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — whoami diagnostic service
# =============================================================================
# Lightweight HTTP echo service for verifying the ingress pipeline.
# NO ports: directive — accessible only via Traefik.

services:
  whoami:
    image: traefik/whoami:v1.11
    container_name: whoami
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    networks:
      vpn_net:
        ipv4_address: 10.20.0.20

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

# ── Deploy whoami stack ─────────────────────────────────────────────────────
deploy_whoami() {
  log_step "Deploying whoami stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy whoami via docker compose"
    return 0
  fi

  cd "${WHOAMI_DIR}"

  # Pull image
  docker compose pull --quiet

  # Deploy
  docker compose up -d --remove-orphans

  # Wait for container
  local i=0
  while [[ $i -lt 15 ]]; do
    if docker ps --filter "name=whoami" --filter "status=running" --format '{{.Names}}' | grep -q whoami; then
      log_info "whoami container is running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "whoami may not be fully started yet"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  deploy_whoami

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
