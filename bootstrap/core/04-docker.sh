#!/usr/bin/env bash
# =============================================================================
# core/04-docker.sh — Docker CE installation and hardened configuration
# =============================================================================
# Installs Docker CE from official repository and configures:
#   - iptables: false     → Docker does NOT manipulate firewall rules
#   - ip6tables: false    → No IPv6 firewall manipulation
#   - userland-proxy: false → No userland TCP proxy for port forwards
#   - json-file logging with rotation
#
# Security rationale:
#   Docker's default behavior creates iptables rules that BYPASS nftables.
#   By disabling Docker's iptables integration:
#     1. nftables has COMPLETE control over packet filtering
#     2. No "ports:" directive can accidentally expose a container to WAN
#     3. All routing is explicit and auditable
#     4. Container network access is governed by nftables forward chain
#
#   userland-proxy: false prevents Docker from spawning a TCP proxy process
#   for each published port, which would listen on 0.0.0.0 and bypass firewall.
#
# Additionally creates the deterministic Docker network "vpn_net":
#   - Subnet: 10.20.0.0/24
#   - Bridge: br-vpn
#   - IP masquerade: disabled (handled by nftables NAT table)
#   - Used by Traefik, Gitea, whoami
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="docker"

# ── Install Docker CE ────────────────────────────────────────────────────────
install_docker() {
  log_step "Installing Docker CE"

  if command -v docker &>/dev/null; then
    local version
    version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
    log_info "Docker already installed (version: $version)"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install Docker CE from official repository"
    return 0
  fi

  log_info "Adding Docker apt repository..."

  # Install prerequisites
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  # Add Docker's official GPG key
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  # Add Docker repository
  local arch
  arch="$(dpkg --print-architecture)"
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF

  # Install Docker packages
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-compose-plugin docker-buildx-plugin

  log_info "Docker CE installed successfully"
}

# ── Configure Docker daemon ─────────────────────────────────────────────────
configure_docker_daemon() {
  log_step "Configuring Docker daemon (hardened)"

  local daemon_json="/etc/docker/daemon.json"

  # CRITICAL SECURITY CONFIGURATION:
  # Each setting prevents Docker from undermining the nftables firewall.
  local content
  content="$(cat <<'JSON'
{
  "iptables": false,
  "ip6tables": false,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
)"

  if file_matches "$daemon_json" "$content"; then
    log_info "daemon.json already up to date"
    return 0
  fi

  install_content "$content" "$daemon_json" "0644"

  if [[ "$DRY_RUN" != "true" ]]; then
    # Restart Docker to pick up new config
    systemctl restart docker.service
    log_info "Docker daemon restarted with hardened config"
  fi
}

# ── Enable Docker service ───────────────────────────────────────────────────
enable_docker() {
  log_step "Enabling Docker service"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would enable docker.service"
    return 0
  fi

  systemctl enable docker.service
  systemctl enable containerd.service

  if ! systemctl is-active --quiet docker.service; then
    systemctl start docker.service
  fi

  log_info "Docker service enabled and running"
}

# ── Create deterministic Docker network ──────────────────────────────────────
create_vpn_network() {
  log_step "Creating Docker network: vpn_net (10.20.0.0/24, bridge br-vpn)"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create Docker network vpn_net"
    return 0
  fi

  # Check if network already exists with correct config
  if docker network inspect vpn_net &>/dev/null; then
    local subnet
    subnet="$(docker network inspect vpn_net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
    local bridge
    bridge="$(docker network inspect vpn_net --format '{{index .Options "com.docker.network.bridge.name"}}')"

    if [[ "$subnet" == "10.20.0.0/24" && "$bridge" == "br-vpn" ]]; then
      log_info "vpn_net already exists with correct configuration"
      return 0
    else
      log_warn "vpn_net exists but with wrong config (subnet=$subnet, bridge=$bridge)"
      log_warn "Removing and recreating..."
      docker network rm vpn_net
    fi
  fi

  # Create the network with deterministic settings:
  # --subnet: fixed IP range so containers get predictable addresses
  # --gateway: host-side bridge IP
  # --opt bridge name: deterministic bridge name for nftables rules
  # --opt masquerade=false: we handle NAT in nftables, not Docker
  docker network create \
    --driver bridge \
    --subnet 10.20.0.0/24 \
    --gateway 10.20.0.1 \
    --opt "com.docker.network.bridge.name=br-vpn" \
    --opt "com.docker.network.bridge.enable_ip_masquerade=false" \
    vpn_net

  log_info "Docker network vpn_net created (subnet=10.20.0.0/24, bridge=br-vpn)"
}

# ── Validate Docker setup ───────────────────────────────────────────────────
validate_docker() {
  log_step "Validating Docker configuration"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping Docker validation in dry-run mode"
    return 0
  fi

  local ok=true

  # Check daemon.json settings
  local cfg="/etc/docker/daemon.json"
  if grep -q '"iptables"[[:space:]]*:[[:space:]]*false' "$cfg" && \
     grep -q '"ip6tables"[[:space:]]*:[[:space:]]*false' "$cfg" && \
     grep -q '"userland-proxy"[[:space:]]*:[[:space:]]*false' "$cfg"; then
    log_info "✅ Docker daemon hardening flags correct"
  else
    log_error "❌ Docker daemon hardening flags incorrect"
    ok=false
  fi

  # Check Docker is running
  if docker info &>/dev/null; then
    log_info "✅ Docker daemon is running"
  else
    log_error "❌ Docker daemon is not running"
    ok=false
  fi

  # Check vpn_net exists
  if docker network inspect vpn_net &>/dev/null; then
    log_info "✅ Docker network vpn_net exists"
  else
    log_error "❌ Docker network vpn_net not found"
    ok=false
  fi

  if $ok; then
    log_info "✅ Docker validation passed"
  else
    log_error "❌ Docker validation failed"
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  install_docker
  configure_docker_daemon
  enable_docker
  create_vpn_network
  validate_docker

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
