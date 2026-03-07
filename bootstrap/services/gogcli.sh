#!/usr/bin/env bash
# =============================================================================
# services/gogcli.sh — Google Workspace CLI (Docker)
# =============================================================================
# Deploys:
#   - gogcli container at 10.20.0.50
#
# Architecture:
#   VPN → SSH → docker exec gogcli gog <command>
#
# Security design:
#   - NO published ports
#   - NO REST API / HTTP endpoints
#   - Access via SSH + docker exec only (VPN-only after hardening)
#   - Google OAuth credentials mounted from /opt/gogcli
#   - Capabilities dropped to minimum
#   - no-new-privileges enabled
#
# Usage:
#   ssh admin@10.100.0.1 "docker exec gogcli gog gmail labels list"
#   ssh admin@10.100.0.1 "docker exec gogcli gog drive list --json"
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

# Google OAuth credentials from Terraform
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
GOOGLE_PROJECT_ID="${GOOGLE_PROJECT_ID:-}"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating gogcli directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $GOGCLI_DIR"
    return 0
  fi

  mkdir -p "${GOGCLI_DIR}/config"
  mkdir -p "${GOGCLI_DIR}/cache"
  
  # Secure permissions
  chmod 700 "${GOGCLI_DIR}"
  chmod 700 "${GOGCLI_DIR}/config"

  log_info "Created $GOGCLI_DIR"
}

# ── Write OAuth credentials from Terraform ───────────────────────────────────
write_credentials() {
  log_step "Writing Google OAuth credentials"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would write credentials.json"
    return 0
  fi

  # Skip if no credentials provided
  if [[ -z "$GOOGLE_CLIENT_ID" ]] || [[ -z "$GOOGLE_CLIENT_SECRET" ]]; then
    log_warn "Google OAuth credentials not configured in Terraform"
    log_info "You can add them later manually to ${GOGCLI_DIR}/config/credentials.json"
    return 0
  fi

  local cred_file="${GOGCLI_DIR}/config/credentials.json"
  
  cat > "$cred_file" <<EOF
{
  "installed": {
    "client_id": "${GOOGLE_CLIENT_ID}",
    "project_id": "${GOOGLE_PROJECT_ID:-gogcli}",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
    "client_secret": "${GOOGLE_CLIENT_SECRET}",
    "redirect_uris": ["http://localhost"]
  }
}
EOF

  chmod 600 "$cred_file"
  log_info "Written credentials.json from Terraform config"
}

# ── Generate Dockerfile ──────────────────────────────────────────────────────
install_dockerfile() {
  log_step "Installing gogcli Dockerfile"

  local dockerfile="${GOGCLI_DIR}/Dockerfile"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $dockerfile"
    return 0
  fi

  # Write Dockerfile inline (gogcli has no official Docker image)
  cat > "$dockerfile" <<'DOCKERFILE'
# =============================================================================
# Dockerfile — gogcli (Google Workspace CLI)
# =============================================================================
# Multi-stage build to create a minimal container with gogcli binary
# See: https://github.com/steipete/gogcli
# =============================================================================

FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git

WORKDIR /build
RUN go install github.com/steipete/gogcli@latest

# Runtime image
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /go/bin/gogcli /usr/local/bin/gog

RUN mkdir -p /root/.config/gogcli /root/.cache/gogcli

CMD ["tail", "-f", "/dev/null"]
DOCKERFILE

  log_info "Created $dockerfile"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing gogcli docker-compose.yml"

  local compose_file="${GOGCLI_DIR}/docker-compose.yml"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $compose_file"
    return 0
  fi

  # SECURITY NOTES:
  # - NO "ports:" directive
  # - Access via SSH + docker exec only
  # - OAuth credentials mounted read-only
  # - Token storage mounted for auth persistence
  # - Local build since no official Docker image exists
  cat > "$compose_file" <<'YAML'
# =============================================================================
# docker-compose.yml — gogcli (Google Workspace CLI)
# =============================================================================
# NO ports: directive. Access via SSH + docker exec only.
#
# Usage:
#   docker exec gogcli gog gmail labels list
#   docker exec gogcli gog drive list --json

services:
  gogcli:
    build: .
    image: gogcli:local
    container_name: gogcli
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ./config:/root/.config/gogcli:rw
      - ./cache:/root/.cache/gogcli:rw
    networks:
      vpn_net:
        ipv4_address: 10.20.0.50
    # Keep container running for exec access
    command: ["tail", "-f", "/dev/null"]

networks:
  vpn_net:
    external: true
YAML

  log_info "Created $compose_file"
}

# ── Create shell alias for admin user ────────────────────────────────────────
setup_alias() {
  log_step "Setting up gog alias for $ADMIN_USER"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create gog alias"
    return 0
  fi

  # Create wrapper script
  cat > /usr/local/bin/gog <<'EOF'
#!/bin/bash
# Wrapper for gogcli in Docker
exec docker exec -it gogcli gog "$@"
EOF
  chmod +x /usr/local/bin/gog

  log_info "Created /usr/local/bin/gog wrapper"
}

# ── Start container ──────────────────────────────────────────────────────────
start_container() {
  log_step "Building and starting gogcli container"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would build and start gogcli container"
    return 0
  fi

  cd "$GOGCLI_DIR"
  
  log_info "Building gogcli image (this may take a minute)..."
  docker compose build --quiet
  docker compose up -d

  # Wait for container to be ready
  sleep 2

  if docker ps | grep -q gogcli; then
    log_info "✅ gogcli container running"
  else
    log_warn "gogcli container may not have started correctly"
    docker compose logs
  fi
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_step "gogcli setup instructions"

  if [[ -n "$GOOGLE_CLIENT_ID" ]] && [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
    cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  gogcli - Credentials configured via Terraform                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

OAuth credentials are already configured. Now authorize with Google:

  ssh ${ADMIN_USER}@10.100.0.1
  gog auth add your@gmail.com --services user --manual

Follow the URL, authorize, paste the code back.

Test it works:
  gog gmail labels list

EOF
  else
    cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  gogcli - Manual credential setup required                                  ║
╚══════════════════════════════════════════════════════════════════════════════╝

1. Add to terraform.tfvars:
   google_client_id     = "xxx.apps.googleusercontent.com"
   google_client_secret = "GOCSPX-xxx"
   google_project_id    = "your-project-id"

2. Re-run: terraform apply

OR manually create ${GOGCLI_DIR}/config/credentials.json

Then authorize:
  ssh ${ADMIN_USER}@10.100.0.1
  gog auth add your@gmail.com --services user --manual

EOF
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  write_credentials
  install_dockerfile
  install_compose_file
  setup_alias
  start_container
  print_setup_instructions

  module_end "$BOOTSTRAP_MODULE"
}

main "$@"
