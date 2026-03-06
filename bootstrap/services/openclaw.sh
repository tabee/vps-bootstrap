#!/usr/bin/env bash
# =============================================================================
# services/openclaw.sh — openclaw AI agent runtime (CLI-only)
# =============================================================================
# Deploys:
#   - openclaw container at 10.20.0.90
#
# Architecture:
#   VPN → SSH → docker exec openclaw <command>
#
# Security design:
#   - NO published ports
#   - NO Traefik labels (CLI-only, not accessible via HTTP)
#   - Access via SSH + docker exec only (VPN-only after hardening)
#   - API keys and config mounted from /opt/openclaw/config/
#   - Capabilities dropped to minimum
#   - no-new-privileges enabled
#
# Usage:
#   ssh admin@10.100.0.1 "docker exec openclaw claw <subcommand>"
#   ssh admin@10.100.0.1 "claw <subcommand>"     # via alias
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="openclaw"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

ADMIN_USER="${ADMIN_USER:-admin}"
OPENCLAW_DIR="/opt/openclaw"

# API keys for AI providers (passed via Terraform → .env)
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

# Optional: Ollama base URL for local models
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://10.20.0.80:11434}"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating openclaw directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $OPENCLAW_DIR"
    return 0
  fi

  mkdir -p "${OPENCLAW_DIR}/config"
  mkdir -p "${OPENCLAW_DIR}/workspace"
  mkdir -p "${OPENCLAW_DIR}/cache"

  # Secure permissions for config (contains API keys)
  chmod 700 "${OPENCLAW_DIR}"
  chmod 700 "${OPENCLAW_DIR}/config"
  chmod 755 "${OPENCLAW_DIR}/workspace"

  log_info "Created $OPENCLAW_DIR"
}

# ── Generate .env file ──────────────────────────────────────────────────────
install_env_file() {
  log_step "Installing openclaw .env file"

  local env_file="${OPENCLAW_DIR}/.env"

  local content
  content="$(cat <<EOF
# openclaw environment
OPENAI_API_KEY=${OPENAI_API_KEY}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
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
  log_step "Installing openclaw docker-compose.yml"

  local compose_file="${OPENCLAW_DIR}/docker-compose.yml"

  # SECURITY NOTES:
  # - NO "ports:" directive
  # - Access via SSH + docker exec only
  # - API keys passed via env_file
  # - Workspace mounted for persistent agent state
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — openclaw AI agent runtime
# =============================================================================
# NO ports: directive. Access via SSH + docker exec only.
#
# Usage:
#   docker exec openclaw claw <subcommand>
#   docker exec -it openclaw bash    # interactive shell

services:
  openclaw:
    image: ghcr.io/tabee/openclaw:latest
    container_name: openclaw
    restart: unless-stopped
    env_file: .env
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ./config:/app/config:rw
      - ./workspace:/app/workspace:rw
      - ./cache:/app/cache:rw
    networks:
      vpn_net:
        ipv4_address: 10.20.0.90
    # Keep container running for exec access
    command: ["tail", "-f", "/dev/null"]

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

# ── Create shell alias for admin user ────────────────────────────────────────
setup_alias() {
  log_step "Setting up claw alias for $ADMIN_USER"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create claw alias"
    return 0
  fi

  cat > /usr/local/bin/claw <<'EOF'
#!/bin/bash
# Wrapper for openclaw in Docker
exec docker exec -it openclaw claw "$@"
EOF
  chmod +x /usr/local/bin/claw

  log_info "Created /usr/local/bin/claw wrapper"
}

# ── Start container ──────────────────────────────────────────────────────────
start_container() {
  log_step "Starting openclaw container"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would start openclaw container"
    return 0
  fi

  cd "$OPENCLAW_DIR"

  docker compose pull --quiet 2>/dev/null || log_warn "Could not pull openclaw image — using local image if available"
  docker compose up -d

  # Wait for container to be ready
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=^/openclaw$" --filter "status=running" --format '{{.Names}}' | grep -q '^openclaw$'; then
      log_info "✅ openclaw container running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "openclaw container may not have started correctly"
  docker compose logs
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_step "openclaw setup instructions"

  cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  openclaw — AI Agent Runtime                                                  ║
╚══════════════════════════════════════════════════════════════════════════════╝

Connect via VPN, then SSH to use openclaw:

  ssh ${ADMIN_USER}@10.100.0.1

Run commands via alias:
  claw <subcommand>

Run commands via docker exec:
  docker exec openclaw claw <subcommand>

Interactive shell:
  docker exec -it openclaw bash

EOF

  if [[ -z "$OPENAI_API_KEY" ]] && [[ -z "$ANTHROPIC_API_KEY" ]]; then
    cat <<EOF
⚠️  No AI provider API keys configured. Add to terraform.tfvars:
  openai_api_key    = "sk-..."       # OpenAI
  anthropic_api_key = "sk-ant-..."   # Anthropic

EOF
  fi

  cat <<EOF
Workspace is persisted at: ${OPENCLAW_DIR}/workspace/
Config is persisted at:    ${OPENCLAW_DIR}/config/

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_env_file
  install_compose_file
  setup_alias
  start_container
  print_setup_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
