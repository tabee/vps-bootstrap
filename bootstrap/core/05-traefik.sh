#!/usr/bin/env bash
# =============================================================================
# core/05-traefik.sh — Traefik reverse proxy (file provider only)
# =============================================================================
# Deploys Traefik as the SINGLE INGRESS POINT for all services.
#
# Architecture:
#   VPN Client → dnsmasq → *.<domain> → 10.20.0.10 (Traefik)
#   Traefik → host-header routing → backend containers
#
# Security design:
#   - NO Docker socket provider (prevents container escape → full host control)
#   - File provider only (static routing, no runtime service discovery)
#   - No dashboard (reduces attack surface)
#   - No published ports (container IPs only, routed by nftables)
#   - ipAllowList middleware: only VPN clients can access
#   - TLS via Let's Encrypt DNS-01 challenge (no public port 80 needed)
#   - Read-only root filesystem
#   - Dropped all capabilities except NET_BIND_SERVICE
#   - Runs as non-root user (65532)
#   - no-new-privileges security option
#
# ACME DNS-01:
#   Uses Hetzner DNS API for certificate provisioning.
#   This allows TLS certificates without exposing HTTP/HTTPS to the internet.
#   The HETZNER_API_TOKEN must have DNS zone edit permissions.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="traefik"

TRAEFIK_MODE="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-deploy-acme)
      TRAEFIK_MODE="post-deploy-acme"
      shift
      ;;
    *)
      log_fatal "Unknown option: $1"
      ;;
  esac
done

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

HETZNER_API_TOKEN="${HETZNER_API_TOKEN:-__ACME_DNS_TOKEN__}"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
VPN_DOMAIN="${VPN_DOMAIN:-example.com}"
ENABLE_WHOAMI="${ENABLE_WHOAMI:-true}"
LETSENCRYPT_ENABLED="${LETSENCRYPT_ENABLED:-true}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
LETSENCRYPT_REQUIRE_WHOAMI_CHECK="${LETSENCRYPT_REQUIRE_WHOAMI_CHECK:-true}"
LETSENCRYPT_RENEW_BEFORE_DAYS="${LETSENCRYPT_RENEW_BEFORE_DAYS:-30}"

TRAEFIK_DIR="/opt/traefik"
ACME_STORAGE_FILE="${TRAEFIK_DIR}/letsencrypt/acme.json"
ACME_STATE_FILE="${TRAEFIK_DIR}/.acme-active"

is_true() {
  [[ "${1,,}" == "true" ]]
}

write_acme_state_file() {
  local state="$1"

  if file_matches "$ACME_STATE_FILE" "$state"; then
    log_info "ACME state already set to ${state}"
    return 0
  fi

  install_content "$state" "$ACME_STATE_FILE" "0644"
}

extract_existing_certificate() {
  if [[ ! -s "$ACME_STORAGE_FILE" ]]; then
    return 1
  fi

  jq -r --arg wildcard "*.${VPN_DOMAIN}" --arg root "${VPN_DOMAIN}" '
    [ .. | objects | select(has("Certificates")) | .Certificates[]? |
      select(
        .domain.main == $wildcard or
        .domain.main == $root or
        ((.domain.sans // []) | index($wildcard)) != null or
        ((.domain.sans // []) | index($root)) != null
      ) |
      .certificate
    ] | first // empty
  ' "$ACME_STORAGE_FILE"
}

certificate_days_remaining() {
  local cert_pem
  cert_pem="$(extract_existing_certificate 2>/dev/null || true)"

  if [[ -z "$cert_pem" || "$cert_pem" == "null" ]]; then
    echo -1
    return 0
  fi

  local tmp_cert end_date end_epoch now_epoch
  tmp_cert="$(mktemp)"
  trap 'rm -f "$tmp_cert"' RETURN
  printf '%s\n' "$cert_pem" > "$tmp_cert"

  end_date="$(openssl x509 -in "$tmp_cert" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "$end_date" ]]; then
    echo -1
    return 0
  fi

  end_epoch="$(date -u -d "$end_date" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"

  if [[ -z "$end_epoch" ]]; then
    echo -1
    return 0
  fi

  echo $(((end_epoch - now_epoch) / 86400))
}

initial_acme_state() {
  if ! is_true "$LETSENCRYPT_ENABLED"; then
    log_warn "Let's Encrypt is disabled via configuration"
    echo false
    return 0
  fi

  local days_remaining
  days_remaining="$(certificate_days_remaining)"

  if (( days_remaining < 0 )); then
    log_info "No existing wildcard certificate found - deferring Let's Encrypt activation until HTTPS preflight passes"
    echo false
    return 0
  fi

  if (( days_remaining <= LETSENCRYPT_RENEW_BEFORE_DAYS )); then
    log_warn "Existing certificate expires in ${days_remaining} day(s) - renewal will wait for HTTPS preflight"
    echo false
    return 0
  fi

  log_info "Existing certificate is still valid for ${days_remaining} day(s) - no renewal needed"
  echo true
}

router_tls_block() {
  local acme_active="$1"

  if [[ "$acme_active" == "true" ]]; then
    cat <<'YAML'
      tls:
        certResolver: le
YAML
  else
    echo '      tls: {}'
  fi
}

verify_whoami_https() {
  local whoami_host="whoami.${VPN_DOMAIN}"

  log_step "Checking HTTPS route: https://${whoami_host}"

  if ! is_true "$ENABLE_WHOAMI"; then
    log_fatal "Let's Encrypt preflight requires enable_whoami=true, or disable letsencrypt_require_whoami_check"
  fi

  if ! curl --silent --show-error --fail --insecure \
    --connect-timeout 10 \
    --max-time 20 \
    --output /dev/null \
    --resolve "${whoami_host}:443:10.20.0.10" \
    "https://${whoami_host}/"; then
    log_error "HTTPS preflight failed for https://${whoami_host}"
    log_error "Skipping Let's Encrypt request to avoid unnecessary rate limits"
    return 1
  fi

  log_info "✅ HTTPS preflight for https://${whoami_host} succeeded"
}

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating Traefik directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $TRAEFIK_DIR"
    return 0
  fi

  mkdir -p "${TRAEFIK_DIR}/letsencrypt"
  touch "${ACME_STORAGE_FILE}"
  # letsencrypt directory must be writable by traefik user (65532)
  chown -R 65532:65532 "${TRAEFIK_DIR}/letsencrypt"
  chmod 0700 "${TRAEFIK_DIR}/letsencrypt"
  chmod 0600 "${ACME_STORAGE_FILE}"
  log_info "Created $TRAEFIK_DIR"
}

# ── Generate traefik.yml (static config) ─────────────────────────────────────
install_traefik_config() {
  local acme_active="${1:-false}"

  log_step "Installing Traefik static configuration"

  local config_file="${TRAEFIK_DIR}/traefik.yml"
  local acme_block=""
  local acme_ca_server_block=""

  if [[ "$acme_active" == "true" ]]; then
    if is_true "$LETSENCRYPT_STAGING"; then
      acme_ca_server_block='      caServer: https://acme-staging-v02.api.letsencrypt.org/directory'
      log_warn "Let's Encrypt staging mode enabled (certificates will NOT be browser-trusted)"
    fi

    acme_block="$(cat <<YAML
# ── ACME / Let's Encrypt ────────────────────────────────────────────────────
# DNS-01 challenge via Hetzner DNS API.
# This allows TLS certificate provisioning WITHOUT exposing any HTTP port
# to the public internet. The only public port is UDP/51820 (WireGuard).
certificatesResolvers:
  le:
    acme:
      email: ${ACME_EMAIL}
${acme_ca_server_block}
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: hetzner
        # Wait 60s after setting TXT record before asking Let's Encrypt to validate.
        # Hetzner DNS propagation can take 30-60s — without this delay,
        # secondary validators see stale/wrong TXT records → 403 Unauthorized.
        propagation:
          delayBeforeChecks: 60s
        resolvers:
          - "1.1.1.1:53"
          - "9.9.9.9:53"
YAML
)"
  fi

  local content
  content="$(cat <<YAML
# =============================================================================
# traefik.yml — Traefik static configuration
# =============================================================================
# Generated by bootstrap system. Do not edit manually.

global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

# ── Entrypoints ──────────────────────────────────────────────────────────────
# websecure (443): HTTPS for web services (whoami, gitea)
# gitssh (2222): TCP passthrough for Git SSH
# NO port 80 entrypoint — all traffic is TLS
entryPoints:
  websecure:
    address: ":443"
  gitssh:
    address: ":2222"

# ── File provider ONLY ──────────────────────────────────────────────────────
# SECURITY: No Docker socket provider.
# Docker socket access = root-equivalent privilege escalation vector.
# File provider gives deterministic, auditable routing.
providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

${acme_block}

# ── API / Dashboard ─────────────────────────────────────────────────────────
# DISABLED. Dashboard exposes internal routing information and
# is an unnecessary attack surface for a headless VPN-only deployment.
api:
  dashboard: false
  insecure: false
YAML
)"

  if file_matches "$config_file" "$content"; then
    log_info "traefik.yml already up to date"
    return 0
  fi

  install_content "$content" "$config_file" "0644"
}

# ── Generate dynamic.yml (routing rules) ─────────────────────────────────────
install_dynamic_config() {
  local acme_active="${1:-false}"

  log_step "Installing Traefik dynamic configuration"

  local config_file="${TRAEFIK_DIR}/dynamic.yml"
  local https_tls_block default_tls_store

  https_tls_block="$(router_tls_block "$acme_active")"

  if [[ "$acme_active" == "true" ]]; then
    default_tls_store="$(cat <<YAML
# ── TLS: wildcard certificate ────────────────────────────────────────────────
# Request a single *.${VPN_DOMAIN} wildcard cert via DNS-01 (Hetzner).
# This covers ALL subdomains (git, whoami, 8n8, ...) with one cert.
tls:
  stores:
    default:
      defaultGeneratedCert:
        resolver: le
        domain:
          main: "*.${VPN_DOMAIN}"
          sans:
            - "${VPN_DOMAIN}"
YAML
)"
  else
    default_tls_store=''
  fi

  # Dynamic config defines all routes and middlewares.
  # vpn-only middleware ensures only VPN clients (10.100.0.0/24)
  # and the Docker bridge gateway (10.20.0.1) can access services.
  local content
  content="$(cat <<YAML
# =============================================================================
# dynamic.yml — Traefik dynamic routing configuration
# =============================================================================
# Generated by bootstrap system. Do not edit manually.

# ── HTTP routers & services ──────────────────────────────────────────────────
http:
  middlewares:
    # SECURITY: Only allow access from VPN subnet and Docker bridge gateway.
    # This is a defense-in-depth measure on top of nftables rules.
    # Even if nftables were misconfigured, Traefik would still reject
    # non-VPN traffic.
    vpn-only:
      ipAllowList:
        sourceRange:
          - 10.100.0.0/24
          - 10.20.0.1/32

  routers:
    # whoami: diagnostic/test service
    whoami:
      entryPoints: ["websecure"]
      rule: "Host(\`whoami.${VPN_DOMAIN}\`)"
      middlewares: ["vpn-only"]
      service: whoami-svc
${https_tls_block}

    # Gitea web UI
    git-web:
      entryPoints: ["websecure"]
      rule: "Host(\`git.${VPN_DOMAIN}\`)"
      middlewares: ["vpn-only"]
      service: git-web-svc
${https_tls_block}

  services:
    whoami-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.20:80"

    git-web-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.30:3000"

# ── TCP routers & services ──────────────────────────────────────────────────
tcp:
  middlewares:
    # Same VPN-only restriction for TCP (Git SSH)
    vpn-only-tcp:
      ipAllowList:
        sourceRange:
          - 10.100.0.0/24
          - 10.20.0.1/32

  routers:
    # Git SSH: TCP passthrough to Gitea SSH server
    git-ssh:
      entryPoints: ["gitssh"]
      rule: "HostSNI(\`*\`)"
      middlewares: ["vpn-only-tcp"]
      service: git-ssh-svc

  services:
    git-ssh-svc:
      loadBalancer:
        servers:
          - address: "10.20.0.30:2222"

${default_tls_store}
YAML
)"

  if file_matches "$config_file" "$content"; then
    log_info "dynamic.yml already up to date"
    return 0
  fi

  install_content "$content" "$config_file" "0644"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing Traefik docker-compose.yml"

  local compose_file="${TRAEFIK_DIR}/docker-compose.yml"

  # SECURITY NOTES on compose config:
  # - NO "ports:" directive — container is NOT published to host network
  #   Traffic reaches Traefik via nftables forwarding to its container IP
  # - read_only: true — prevents runtime filesystem modifications
  # - cap_drop ALL + cap_add NET_BIND_SERVICE — minimum privileges
  # - user 65532: runs as nobody (non-root)
  # - no-new-privileges: prevents setuid/setgid escalation inside container
  # - tmpfs /tmp: writable temp area in read-only filesystem
  # - volumes are :ro except letsencrypt (needs write for ACME state)
  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — Traefik reverse proxy
# =============================================================================
# NO ports: directive — Traefik is NOT exposed to host network.
# Reachable only via Docker network IP (10.20.0.10) through nftables.

services:
  traefik:
    image: traefik:v3.6.7
    container_name: traefik
    restart: unless-stopped
    user: "65532:65532"
    security_opt:
      - no-new-privileges:true
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]
    read_only: true
    tmpfs: ["/tmp"]
    environment:
      - HETZNER_API_TOKEN=${HETZNER_API_TOKEN}
      # CRITICAL: Hetzner migrated DNS API to Cloud API (2025+)
      # Without this, LEGO uses the old dns.hetzner.com endpoint which fails
      - HETZNER_API_URL=https://api.hetzner.cloud/v1
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ./letsencrypt:/letsencrypt
    networks:
      vpn_net:
        ipv4_address: 10.20.0.10

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
  log_step "Installing Traefik .env file"

  local env_file="${TRAEFIK_DIR}/.env"

  if [[ "$HETZNER_API_TOKEN" == "__ACME_DNS_TOKEN__" ]]; then
    log_warn "HETZNER_API_TOKEN not set — using placeholder"
  fi

  local content="HETZNER_API_TOKEN=${HETZNER_API_TOKEN}"

  if file_matches "$env_file" "$content"; then
    log_info ".env already up to date"
    return 0
  fi

  install_content "$content" "$env_file" "0600"
}

configure_traefik_stack() {
  local acme_active="$1"

  setup_directories
  install_traefik_config "$acme_active"
  install_dynamic_config "$acme_active"
  install_compose_file
  install_env_file
  write_acme_state_file "$acme_active"
}

# ── Deploy Traefik stack ─────────────────────────────────────────────────────
deploy_traefik() {
  log_step "Deploying Traefik stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy Traefik via docker compose"
    return 0
  fi

  cd "${TRAEFIK_DIR}"

  # NOTE: `docker compose pull` can deadlock under non-interactive Terraform
  # remote-exec sessions with current Compose releases. `up -d` already pulls
  # missing images, so use that directly to avoid indefinite bootstrap hangs.
  docker compose up -d --remove-orphans

  # Wait for container to be healthy
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=traefik" --filter "status=running" --format '{{.Names}}' | grep -q traefik; then
      log_info "Traefik container is running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "Traefik container may not be fully started yet"
}

post_deploy_acme() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  if ! is_true "$LETSENCRYPT_ENABLED"; then
    log_info "Let's Encrypt is disabled - leaving Traefik on default TLS certificate"
    write_acme_state_file "false"
    module_done
    return 0
  fi

  local days_remaining
  days_remaining="$(certificate_days_remaining)"

  if (( days_remaining > LETSENCRYPT_RENEW_BEFORE_DAYS )); then
    log_info "Existing certificate is valid for ${days_remaining} day(s) - skipping renewal attempt"
    write_acme_state_file "true"
    module_done
    return 0
  fi

  if is_true "$LETSENCRYPT_REQUIRE_WHOAMI_CHECK"; then
    verify_whoami_https || log_fatal "Let's Encrypt activation aborted because whoami HTTPS preflight failed"
  else
    log_warn "Skipping whoami HTTPS preflight because letsencrypt_require_whoami_check=false"
  fi

  log_step "Enabling Let's Encrypt certificate management"
  install_traefik_config "true"
  install_dynamic_config "true"
  write_acme_state_file "true"
  deploy_traefik

  days_remaining="$(certificate_days_remaining)"
  if (( days_remaining >= 0 )); then
    log_info "Let's Encrypt certificate available (expires in ${days_remaining} day(s))"
  else
    log_warn "Traefik was switched to Let's Encrypt mode; certificate issuance may still be in progress"
  fi

  module_done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  case "$TRAEFIK_MODE" in
    install)
      module_start "$BOOTSTRAP_MODULE"
      require_root

      local acme_active
      acme_active="$(initial_acme_state)"
      configure_traefik_stack "$acme_active"
      deploy_traefik

      module_done
      ;;
    post-deploy-acme)
      post_deploy_acme
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
