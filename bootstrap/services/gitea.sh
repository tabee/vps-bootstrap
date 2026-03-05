#!/usr/bin/env bash
# =============================================================================
# services/gitea.sh — Gitea + PostgreSQL stack
# =============================================================================
# Deploys:
#   - PostgreSQL 16 (Alpine) at 10.20.0.31
#   - Gitea 1.25.x at 10.20.0.30
#
# Architecture:
#   VPN → Traefik:443 → git.<domain> → Gitea:3000 (HTTP)
#   VPN → Traefik:2222 → git.<domain> → Gitea:2222 (SSH)
#   Gitea → PostgreSQL:5432 (internal, same Docker network)
#
# Security design:
#   - NO published ports — all access via Traefik only
#   - PostgreSQL not reachable from VPN (only from vpn_net containers)
#   - Registration disabled (DISABLE_REGISTRATION=true)
#   - Sign-in required to view anything (REQUIRE_SIGNIN_VIEW=true)
#   - Capabilities dropped to minimum needed for file operations
#   - no-new-privileges on both containers
#   - Secrets via environment variables (from .env file)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="gitea"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

DB_PASSWORD="${DB_PASSWORD:-__DB_PASSWORD__}"
GITEA_SECRET_KEY="${GITEA_SECRET_KEY:-__GITEA_SECRET_KEY__}"
GITEA_INTERNAL_TOKEN="${GITEA_INTERNAL_TOKEN:-__GITEA_INTERNAL_TOKEN__}"
VPN_DOMAIN="${VPN_DOMAIN:-example.com}"

GITEA_DIR="/opt/gitea"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Gitea directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $GITEA_DIR"
    return 0
  fi

  mkdir -p "${GITEA_DIR}/gitea-data"
  mkdir -p "${GITEA_DIR}/pg-data"

  # Gitea data must be writable by container user (UID 1000)
  chown -R 1000:1000 "${GITEA_DIR}/gitea-data"

  log_info "Created $GITEA_DIR"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Gitea docker-compose.yml"

  local compose_file="${GITEA_DIR}/docker-compose.yml"

  # SECURITY NOTES:
  # - NO "ports:" on either service
  # - PostgreSQL health check for dependency ordering
  # - Gitea connects to postgres via internal Docker network IP
  # - cap_drop ALL on Gitea, with minimal cap_add for file operations
  # - SSH runs inside Gitea container on port 2222 (Traefik TCP passthrough)
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Gitea + PostgreSQL
# =============================================================================
# NO ports: directive on any service.
# Access is exclusively through Traefik reverse proxy.

services:
  postgres:
    image: postgres:16-alpine
    container_name: gitea-postgres
    restart: unless-stopped
    env_file: .env
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./pg-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      vpn_net:
        ipv4_address: 10.20.0.31

  gitea:
    image: gitea/gitea:1.25.4
    container_name: gitea
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    environment:
      - USER_UID=1000
      - USER_GID=1000
      # ── Server config ──────────────────────────────────────────────────────
      - GITEA__server__DOMAIN=git.${VPN_DOMAIN}
      - GITEA__server__ROOT_URL=https://git.${VPN_DOMAIN}/
      - GITEA__server__PROTOCOL=http
      - GITEA__server__HTTP_PORT=3000
      # SSH server inside Gitea (Traefik TCP passthrough on 2222)
      - GITEA__server__START_SSH_SERVER=true
      - GITEA__server__SSH_DOMAIN=git.${VPN_DOMAIN}
      - GITEA__server__SSH_PORT=2222
      - GITEA__server__SSH_LISTEN_PORT=2222
      # ── Database config ────────────────────────────────────────────────────
      - GITEA__database__DB_TYPE=postgres
      - GITEA__database__HOST=10.20.0.31:5432
      - GITEA__database__NAME=${POSTGRES_DB}
      - GITEA__database__USER=${POSTGRES_USER}
      - GITEA__database__PASSWD=${POSTGRES_PASSWORD}
      # ── Security config ────────────────────────────────────────────────────
      - GITEA__security__SECRET_KEY=${GITEA_SECRET_KEY}
      - GITEA__security__INTERNAL_TOKEN=${GITEA_INTERNAL_TOKEN}
      # ── Service config ─────────────────────────────────────────────────────
      # Disable public registration — admin creates users manually
      - GITEA__service__DISABLE_REGISTRATION=true
      # Require authentication to view any content
      - GITEA__service__REQUIRE_SIGNIN_VIEW=true
    # Drop ALL capabilities, add only what's needed for file operations
    cap_drop: [ALL]
    cap_add: [DAC_OVERRIDE, CHOWN, FOWNER, SETUID, SETGID]
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./gitea-data:/data
    networks:
      vpn_net:
        ipv4_address: 10.20.0.30

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

# ── Generate .env file ──────────────────────────────────────────────────────
install_env_file() {
  log_step "Installing Gitea .env file"

  local env_file="${GITEA_DIR}/.env"

  if [[ "$DB_PASSWORD" == "__DB_PASSWORD__" ]]; then
    log_warn "DB_PASSWORD not set — using placeholder"
  fi
  if [[ "$GITEA_SECRET_KEY" == "__GITEA_SECRET_KEY__" ]]; then
    log_warn "GITEA_SECRET_KEY not set — using placeholder"
  fi
  if [[ "$GITEA_INTERNAL_TOKEN" == "__GITEA_INTERNAL_TOKEN__" ]]; then
    log_warn "GITEA_INTERNAL_TOKEN not set — using placeholder"
  fi

  local content
  content="$(cat <<EOF
# Domain configuration
VPN_DOMAIN=${VPN_DOMAIN}

# PostgreSQL
POSTGRES_DB=gitea
POSTGRES_USER=gitea
POSTGRES_PASSWORD=${DB_PASSWORD}

# Gitea secrets
GITEA_SECRET_KEY=${GITEA_SECRET_KEY}
GITEA_INTERNAL_TOKEN=${GITEA_INTERNAL_TOKEN}
EOF
)"

  if file_matches "$env_file" "$content"; then
    log_info ".env already up to date"
    return 0
  fi

  install_content "$content" "$env_file" "0600"
}

# ── Deploy Gitea stack ──────────────────────────────────────────────────────
deploy_gitea() {
  log_step "Deploying Gitea stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy Gitea via docker compose"
    return 0
  fi

  cd "${GITEA_DIR}"

  # Pull latest images
  docker compose pull --quiet

  # Deploy
  docker compose up -d --remove-orphans

  # Wait for postgres to be healthy
  log_info "Waiting for PostgreSQL health check..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if docker inspect --format='{{.State.Health.Status}}' gitea-postgres 2>/dev/null | grep -q healthy; then
      log_info "PostgreSQL is healthy"
      break
    fi
    sleep 2
    i=$((i + 2))
  done

  # Wait for Gitea to start
  i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=gitea" --filter "status=running" --format '{{.Names}}' | grep -q '^gitea$'; then
      log_info "Gitea container is running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "Gitea may not be fully started yet"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  install_env_file
  deploy_gitea

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
