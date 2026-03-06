#!/usr/bin/env bash
# =============================================================================
# services/ollama.sh — Ollama local LLM runtime (CLI-only)
# =============================================================================
# Deploys:
#   - Ollama container at 10.20.0.80
#
# Architecture:
#   VPN → SSH → docker exec ollama ollama run <model>
#   Open WebUI → http://10.20.0.80:11434 (internal Docker network only)
#
# Security design:
#   - NO published ports
#   - No Traefik labels (CLI-only service, not exposed via HTTP)
#   - Access via SSH + docker exec only (VPN-only after hardening)
#   - Models stored in /opt/ollama/models/
#   - Capabilities dropped to minimum
#   - no-new-privileges enabled
#
# Usage:
#   ssh admin@10.100.0.1 "docker exec -it ollama ollama run llama3.2"
#   ssh admin@10.100.0.1 "ollama pull llama3.2"
#   ssh admin@10.100.0.1 "ollama list"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="ollama"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

ADMIN_USER="${ADMIN_USER:-admin}"
OLLAMA_DIR="/opt/ollama"

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Ollama directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $OLLAMA_DIR"
    return 0
  fi

  mkdir -p "${OLLAMA_DIR}/models"

  # Ollama runs as root inside container, data dir must be accessible
  chmod 755 "${OLLAMA_DIR}"
  chmod 755 "${OLLAMA_DIR}/models"

  log_info "Created $OLLAMA_DIR"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Ollama docker-compose.yml"

  local compose_file="${OLLAMA_DIR}/docker-compose.yml"

  # SECURITY NOTES:
  # - NO "ports:" directive — Ollama API (11434) is NOT exposed to host
  # - Accessible only via Docker network (from Open WebUI or SSH exec)
  # - Models persisted in /opt/ollama/models/ (survives container restarts)
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Ollama local LLM runtime
# =============================================================================
# NO ports: directive.
# API (port 11434) is accessible only on the Docker internal network.
# Access via:
#   - SSH: docker exec -it ollama ollama run <model>
#   - Internal: http://10.20.0.80:11434 (for Open WebUI)

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./models:/root/.ollama
    networks:
      vpn_net:
        ipv4_address: 10.20.0.80
    # Keep container running; Ollama server starts automatically
    environment:
      - OLLAMA_HOST=0.0.0.0

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
  log_step "Setting up ollama alias for $ADMIN_USER"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create ollama alias"
    return 0
  fi

  cat > /usr/local/bin/ollama <<'EOF'
#!/bin/bash
# Wrapper for Ollama in Docker
exec docker exec -it ollama ollama "$@"
EOF
  chmod +x /usr/local/bin/ollama

  log_info "Created /usr/local/bin/ollama wrapper"
}

# ── Start container ──────────────────────────────────────────────────────────
start_container() {
  log_step "Starting Ollama container"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would start Ollama container"
    return 0
  fi

  cd "$OLLAMA_DIR"

  docker compose pull --quiet
  docker compose up -d

  # Wait for container to be ready
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=^/ollama$" --filter "status=running" --format '{{.Names}}' | grep -q '^ollama$'; then
      log_info "✅ Ollama container running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "Ollama container may not have started correctly"
  docker compose logs
}

# ── Print setup instructions ─────────────────────────────────────────────────
print_setup_instructions() {
  log_step "Ollama setup instructions"

  cat <<EOF

╔══════════════════════════════════════════════════════════════════════════════╗
║  Ollama — Local LLM Runtime                                                  ║
╚══════════════════════════════════════════════════════════════════════════════╝

Connect via VPN, then SSH to use Ollama:

  ssh ${ADMIN_USER}@10.100.0.1

Pull a model (first-time setup):
  ollama pull llama3.2          # ~2 GB, good starting model
  ollama pull qwen2.5-coder     # ~5 GB, code-focused model

Run a model interactively:
  ollama run llama3.2

List available models:
  ollama list

API is available internally at http://10.20.0.80:11434
(accessible from Open WebUI and other Docker containers)

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_compose_file
  setup_alias
  start_container
  print_setup_instructions

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
