#!/usr/bin/env bash
# =============================================================================
# services/gitea.sh — Gitea + PostgreSQL + tea CLI stack
# =============================================================================
# Deploys:
#   - PostgreSQL 16 (Alpine) at 10.20.0.31
#   - Gitea 1.25.x at 10.20.0.30
#   - tea CLI (Gitea CLI) sidecar at 10.20.0.32
#
# Architecture:
#   VPN → Traefik:443 → git.<domain> → Gitea:3000 (HTTP)
#   VPN → Traefik:2222 → git.<domain> → Gitea:2222 (SSH)
#   Gitea → PostgreSQL:5432 (internal, same Docker network)
#   VPN → SSH → docker exec gitea-tea tea <command>
#
# Security design:
#   - NO published ports — all access via Traefik only
#   - PostgreSQL not reachable from VPN (only from vpn_net containers)
#   - tea CLI: NO ports, access via SSH + docker exec only (analog gogcli)
#   - Registration disabled (DISABLE_REGISTRATION=true)
#   - Sign-in required to view anything (REQUIRE_SIGNIN_VIEW=true)
#   - Capabilities dropped to minimum needed for file operations
#   - no-new-privileges on all containers
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

# Variables from Terraform-generated .env
GITEA_DB_PASSWORD="${GITEA_DB_PASSWORD:-}"
GITEA_SECRET_KEY="${GITEA_SECRET_KEY:-}"
GITEA_INTERNAL_TOKEN="${GITEA_INTERNAL_TOKEN:-}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@example.com}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"
VPN_DOMAIN="${VPN_DOMAIN:-example.com}"

ADMIN_USER="${ADMIN_USER:-admin}"
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
  mkdir -p "${GITEA_DIR}/tea-config"

  # Gitea data must be writable by container user (UID 1000)
  chown -R 1000:1000 "${GITEA_DIR}/gitea-data"

  # tea config directory — secure permissions
  chmod 700 "${GITEA_DIR}/tea-config"

  log_info "Created $GITEA_DIR (incl. tea-config)"
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
      - GITEA__security__INSTALL_LOCK=true
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

  tea:
    image: gitea/tea:latest
    container_name: gitea-tea
    restart: unless-stopped
    depends_on:
      gitea:
        condition: service_started
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ./tea-config:/root/.config/tea:rw
    networks:
      vpn_net:
        ipv4_address: 10.20.0.32
    # Keep container running for exec access (CLI sidecar)
    entrypoint: ["/bin/sh", "-c", "sleep infinity"]

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

  if [[ -f "$env_file" ]]; then
    local existing_db_password
    local existing_secret_key
    local existing_internal_token
    existing_db_password=$(grep '^POSTGRES_PASSWORD=' "$env_file" 2>/dev/null | cut -d'=' -f2- || true)
    existing_secret_key=$(grep '^GITEA_SECRET_KEY=' "$env_file" 2>/dev/null | cut -d'=' -f2- || true)
    existing_internal_token=$(grep '^GITEA_INTERNAL_TOKEN=' "$env_file" 2>/dev/null | cut -d'=' -f2- || true)

    if [[ -n "$existing_db_password" ]]; then
      GITEA_DB_PASSWORD="$existing_db_password"
      log_info "Preserving existing POSTGRES_PASSWORD for DB compatibility"
    fi
    if [[ -n "$existing_secret_key" ]]; then
      GITEA_SECRET_KEY="$existing_secret_key"
      log_info "Preserving existing GITEA_SECRET_KEY"
    fi
    if [[ -n "$existing_internal_token" ]]; then
      GITEA_INTERNAL_TOKEN="$existing_internal_token"
      log_info "Preserving existing GITEA_INTERNAL_TOKEN"
    fi
  fi

  if [[ -z "$GITEA_DB_PASSWORD" ]]; then
    log_warn "GITEA_DB_PASSWORD not set — generating random password"
    GITEA_DB_PASSWORD=$(openssl rand -hex 16)
  fi
  if [[ -z "$GITEA_SECRET_KEY" ]]; then
    log_warn "GITEA_SECRET_KEY not set — generating random key"
    GITEA_SECRET_KEY=$(openssl rand -hex 32)
  fi
  if [[ -z "$GITEA_INTERNAL_TOKEN" ]]; then
    log_warn "GITEA_INTERNAL_TOKEN not set — generating random token"
    GITEA_INTERNAL_TOKEN=$(openssl rand -hex 32)
  fi

  local content
  content="$(cat <<EOF
# Domain configuration
VPN_DOMAIN=${VPN_DOMAIN}

# PostgreSQL
POSTGRES_DB=gitea
POSTGRES_USER=gitea
POSTGRES_PASSWORD=${GITEA_DB_PASSWORD}

# Gitea secrets
GITEA_SECRET_KEY=${GITEA_SECRET_KEY}
GITEA_INTERNAL_TOKEN=${GITEA_INTERNAL_TOKEN}

# Gitea admin credentials
GITEA_ADMIN_USER=${GITEA_ADMIN_USER}
GITEA_ADMIN_EMAIL=${GITEA_ADMIN_EMAIL}
GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD}
EOF
)"

  if file_matches "$env_file" "$content"; then
    log_info ".env already up to date"
    return 0
  fi

  install_content "$content" "$env_file" "0600"
}

# ── Keep existing app.ini DB password in sync ──────────────────────────────
sync_app_ini_db_password() {
  log_step "Ensuring Gitea app.ini database password is in sync"

  local app_ini="${GITEA_DIR}/gitea-data/gitea/conf/app.ini"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would ensure database PASSWD in ${app_ini} matches POSTGRES_PASSWORD"
    return 0
  fi

  if [[ ! -f "$app_ini" ]]; then
    log_info "No existing app.ini yet (first run)"
    return 0
  fi

  if [[ -z "$GITEA_DB_PASSWORD" ]]; then
    log_warn "GITEA_DB_PASSWORD empty — cannot sync app.ini"
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  if awk -v pw="$GITEA_DB_PASSWORD" '
    BEGIN { in_db=0; replaced=0 }
    /^\[/ {
      in_db = ($0 == "[database]")
    }
    {
      if (in_db && $0 ~ /^PASSWD[[:space:]]*=/) {
        print "PASSWD = " pw
        replaced=1
        next
      }
      print
    }
    END {
      if (replaced == 0) exit 2
    }
  ' "$app_ini" > "$tmp_file"; then
    if cmp -s "$app_ini" "$tmp_file"; then
      log_info "app.ini database password already in sync"
      rm -f "$tmp_file"
      return 0
    fi

    cp "$tmp_file" "$app_ini"
    rm -f "$tmp_file"
    log_info "Updated database PASSWD in app.ini"
  else
    rm -f "$tmp_file"
    log_warn "Could not patch app.ini database PASSWD automatically; continuing"
  fi
}

# ── Deploy Gitea stack ──────────────────────────────────────────────────────
deploy_gitea() {
  log_step "Deploying Gitea stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy Gitea via docker compose"
    return 0
  fi

  cd "${GITEA_DIR}"

  # NOTE: Avoid a separate `docker compose pull`, which can hang indefinitely
  # in non-interactive Terraform remote-exec sessions. `up -d` pulls missing
  # images automatically.
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

# ── Create Gitea admin user ────────────────────────────────────────────────
create_admin_user() {
  log_step "Creating Gitea admin user"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create Gitea admin user: ${GITEA_ADMIN_USER}"
    return 0
  fi

  if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_warn "GITEA_ADMIN_PASSWORD not set — skipping admin user creation"
    return 0
  fi

  # Wait for Gitea to be fully ready (HTTP responding)
  log_info "Waiting for Gitea to be ready..."
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker exec gitea curl -sS http://localhost:3000/ >/dev/null 2>&1; then
      break
    fi
    sleep 2
    i=$((i + 2))
  done

  # Check if admin user already exists
  local admin_list
  admin_list=$(docker exec -u git gitea gitea admin user list --admin 2>/dev/null || true)

  if [[ -z "$admin_list" ]]; then
    log_warn "Gitea admin CLI is not ready (DB/auth) — skipping admin user creation for now"
    return 0
  fi

  if echo "$admin_list" | grep -q "${GITEA_ADMIN_USER}"; then
    log_info "Admin user '${GITEA_ADMIN_USER}' already exists"

    # Keep password in sync with Terraform-managed secret
    docker exec -u git gitea gitea admin user change-password \
      --username "${GITEA_ADMIN_USER}" \
      --password "${GITEA_ADMIN_PASSWORD}" >/dev/null 2>&1 || \
      log_warn "Could not sync admin password for '${GITEA_ADMIN_USER}'"

    # Ensure API automation can authenticate without forced password change flow
    docker exec -u git gitea gitea admin user must-change-password \
      --unset "${GITEA_ADMIN_USER}" >/dev/null 2>&1 || true

    return 0
  fi

  # Create admin user via Gitea CLI
  log_info "Creating admin user '${GITEA_ADMIN_USER}'..."
  docker exec -u git gitea gitea admin user create \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASSWORD}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false >/dev/null 2>&1 || {
      log_warn "Admin user creation failed (may already exist)"
      return 0
    }

  docker exec -u git gitea gitea admin user must-change-password \
    --unset "${GITEA_ADMIN_USER}" >/dev/null 2>&1 || true

  log_info "✅ Gitea admin user '${GITEA_ADMIN_USER}' created"
}

# ── Generate tea token and configure tea CLI ──────────────────────────────
configure_tea() {
  log_step "Configuring tea CLI with auto-generated token"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would configure tea CLI login"
    return 0
  fi

  if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_warn "No admin credentials — skipping tea auto-configuration"
    log_info "  Configure manually: tea login add --name gitea --url https://git.${VPN_DOMAIN} --token <token>"
    return 0
  fi

  # Wait for tea container
  local i=0
  while [[ $i -lt 15 ]]; do
    if docker ps --filter "name=gitea-tea" --filter "status=running" --format '{{.Names}}' | grep -q '^gitea-tea$'; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  if ! docker ps --filter "name=gitea-tea" --filter "status=running" --format '{{.Names}}' | grep -q '^gitea-tea$'; then
    log_warn "tea container not running — skipping configuration"
    return 0
  fi

  # Check if tea is already logged in
  if docker exec gitea-tea tea login list 2>/dev/null | grep -q "gitea"; then
    log_info "tea already has a login configured"
    return 0
  fi

  # Generate API token via Gitea API
  log_info "Generating access token via Gitea API..."
  local token_response
  token_response=$(docker exec gitea curl -sf \
    -X POST \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"name": "tea-cli", "scopes": ["all"]}' \
    "http://localhost:3000/api/v1/users/${GITEA_ADMIN_USER}/tokens" 2>/dev/null) || {
      log_warn "Token generation failed — Gitea API may not be ready"
      log_info "  Configure manually: tea login add --name gitea --url https://git.${VPN_DOMAIN} --token <token>"
      return 0
    }

  local tea_token
  tea_token=$(echo "$token_response" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)

  if [[ -z "$tea_token" ]]; then
    log_warn "Could not extract token from API response"
    log_info "  Configure manually: tea login add --name gitea --url https://git.${VPN_DOMAIN} --token <token>"
    return 0
  fi

  # Configure tea with the generated token
  docker exec gitea-tea tea login add \
    --name gitea \
    --url "https://git.${VPN_DOMAIN}" \
    --token "${tea_token}" \
    --no-version-check 2>/dev/null || true

  log_info "✅ tea CLI configured with auto-generated token for https://git.${VPN_DOMAIN}"
}

# ── Create tea CLI wrapper ───────────────────────────────────────────────────
setup_tea_alias() {
  log_step "Setting up tea wrapper for ${ADMIN_USER}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create /usr/local/bin/tea wrapper"
    return 0
  fi

  cat > /usr/local/bin/tea <<'EOF'
#!/bin/bash
# Wrapper for tea CLI (Gitea) in Docker
if [ -t 0 ] && [ -t 1 ]; then
  exec docker exec -it gitea-tea tea "$@"
else
  exec docker exec gitea-tea tea "$@"
fi
EOF
  chmod +x /usr/local/bin/tea

  log_info "Created /usr/local/bin/tea wrapper"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  install_env_file
  sync_app_ini_db_password
  deploy_gitea
  create_admin_user
  setup_tea_alias
  configure_tea

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
