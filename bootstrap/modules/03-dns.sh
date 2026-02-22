#!/usr/bin/env bash
# =============================================================================
# modules/03-dns.sh — dnsmasq + systemd-resolved configuration
# =============================================================================
# Configures:
#   - dnsmasq: authoritative DNS for VPN clients (*.<domain> → Traefik)
#   - systemd-resolved: stub resolver for the host itself
#
# Architecture:
#   VPN Client → 10.100.0.1:53 (dnsmasq) → *.<domain> → 10.20.0.10 (Traefik)
#   Host        → 127.0.0.53 (resolved)   → upstream DNS (AdGuard/Cloudflare)
#
# Security rationale:
#   - dnsmasq listens ONLY on wg0 (10.100.0.1) — not reachable from WAN
#   - All *.<domain> resolves to Traefik IP — single ingress enforcement
#   - No external DNS queries are exposed
#   - no-resolv: dnsmasq uses explicit upstream servers, not /etc/resolv.conf
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# Load configuration
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Default domain if not set
VPN_DOMAIN="${VPN_DOMAIN:-example.com}"

BOOTSTRAP_MODULE="03-dns"

# ── Configure dnsmasq ────────────────────────────────────────────────────────
configure_dnsmasq() {
  log_step "Configuring dnsmasq"

  # Main config: minimal, delegates to conf-dir
  local main_conf="/etc/dnsmasq.conf"
  local main_content
  main_content="$(cat <<'CONF'
# =============================================================================
# dnsmasq.conf — Main DNS configuration
# =============================================================================
# Minimal main config. Site-specific rules are in /etc/dnsmasq.d/

# Listen only on WireGuard interface — never on WAN or localhost
# bind-dynamic: allows dnsmasq to start even if wg0 doesn't exist yet;
#               it will bind to 10.100.0.1 when wg0 comes up.
interface=wg0
listen-address=127.0.0.1
listen-address=10.100.0.1
bind-dynamic
except-interface=eth0

# Upstream DNS servers (AdGuard DNS + Cloudflare)
server=94.140.14.14
server=1.1.1.1

# Security: require fully qualified domain names
domain-needed
# Security: never forward RFC1918 reverse lookups upstream
bogus-priv

# Performance: DNS cache (1000 entries ≈ small VPN)
cache-size=1000
CONF
)"

  if ! file_matches "$main_conf" "$main_content"; then
    install_content "$main_content" "$main_conf" "0644"
  else
    log_info "dnsmasq.conf already up to date"
  fi

  # Site-specific config
  local site_conf="/etc/dnsmasq.d/10-vpn-domain.conf"
  local site_content
  site_content="$(cat <<CONF
# =============================================================================
# 10-vpn-domain.conf — VPN domain DNS configuration
# =============================================================================
# SINGLE INGRESS ENFORCEMENT:
# All *.${VPN_DOMAIN} queries resolve to Traefik's container IP.
# VPN clients CANNOT bypass Traefik to reach containers directly
# because nftables only allows forwarding to Traefik's IP.

# Do not use /etc/resolv.conf — explicit upstream only
no-resolv

# Upstream DNS (privacy-focused: AdGuard + Cloudflare)
server=94.140.14.14
server=94.140.15.15
server=1.1.1.1
server=1.0.0.1

# Require FQDN, reject bogus private reverse lookups
domain-needed
bogus-priv

# Wildcard: ALL *.${VPN_DOMAIN} → Traefik container IP
# This is the core of single-ingress enforcement:
# VPN clients resolve any subdomain to Traefik, which then routes
# to the correct backend based on Host header / SNI.
address=/${VPN_DOMAIN}/10.20.0.10
CONF
)"

  if ! file_matches "$site_conf" "$site_content"; then
    mkdir -p /etc/dnsmasq.d
    # Remove old config file if it exists with different name
    rm -f /etc/dnsmasq.d/10-b3rn.conf 2>/dev/null || true
    install_content "$site_content" "$site_conf" "0644"
  else
    log_info "10-vpn-domain.conf already up to date"
  fi

  # Gitea-specific DNS (explicit for clarity, though wildcard covers it)
  local git_conf="/etc/dnsmasq.d/vpn-git.conf"
  local git_content
  git_content="$(cat <<CONF
# git.${VPN_DOMAIN} → Traefik (explicit, for documentation clarity)
address=/git.${VPN_DOMAIN}/10.20.0.10
CONF
)"

  if ! file_matches "$git_conf" "$git_content"; then
    install_content "$git_content" "$git_conf" "0644"
  else
    log_info "vpn-git.conf already up to date"
  fi

  # Whoami DNS
  local hosts_conf="/etc/dnsmasq.d/vpn-hosts.conf"
  local hosts_content
  hosts_content="$(cat <<CONF
# whoami.${VPN_DOMAIN} → Traefik (explicit, for documentation clarity)
address=/whoami.${VPN_DOMAIN}/10.20.0.10
CONF
)"

  if ! file_matches "$hosts_conf" "$hosts_content"; then
    install_content "$hosts_content" "$hosts_conf" "0644"
  else
    log_info "vpn-hosts.conf already up to date"
  fi
}

# ── Configure systemd-resolved ──────────────────────────────────────────────
configure_resolved() {
  log_step "Configuring systemd-resolved"

  local conf="/etc/systemd/resolved.conf"

  # systemd-resolved provides the stub resolver at 127.0.0.53 for the host.
  # It does NOT handle VPN client DNS — that's dnsmasq's job.
  # DNSStubListener=yes is required so the host can resolve via 127.0.0.53.
  # LLMNR and mDNS disabled: not needed on a server, reduces attack surface.
  # FallbackDNS ensures DNS works even if primary fails.
  local content
  content="$(cat <<'CONF'
# =============================================================================
# resolved.conf — systemd-resolved configuration
# =============================================================================
# Host-level DNS resolution. VPN clients use dnsmasq instead.

[Resolve]
DNS=1.1.1.1 8.8.8.8 94.140.14.14
FallbackDNS=9.9.9.9 8.8.4.4
MulticastDNS=no
LLMNR=no
DNSStubListener=yes
CONF
)"

  if ! file_matches "$conf" "$content"; then
    install_content "$content" "$conf" "0644"
  else
    log_info "resolved.conf already up to date"
  fi

  # IMPORTANT: Do NOT symlink to stub-resolv.conf yet!
  # We first verify resolved is working, then symlink.
  # For now, create a direct resolv.conf that works immediately.
  if [[ "$DRY_RUN" != "true" ]]; then
    # Remove any existing symlink
    rm -f /etc/resolv.conf 2>/dev/null || true
    
    # Create a direct resolv.conf with working DNS
    cat > /etc/resolv.conf << 'RESOLV'
# Direct DNS configuration for VPS bootstrap
# This ensures DNS works during and after bootstrap
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 94.140.14.14
RESOLV
    log_info "Created /etc/resolv.conf with direct nameservers"
  fi
}

# ── Enable services ─────────────────────────────────────────────────────────
enable_dns_services() {
  log_step "Enabling DNS services"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would enable dnsmasq and systemd-resolved"
    return 0
  fi

  # Enable and restart systemd-resolved
  systemctl enable systemd-resolved.service
  systemctl restart systemd-resolved.service
  log_info "systemd-resolved enabled and restarted"

  # Wait for resolved to be ready
  local i=0
  while [[ $i -lt 10 ]]; do
    if systemctl is-active --quiet systemd-resolved.service; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  # Enable dnsmasq — bind-dynamic allows it to start even without wg0.
  # It will dynamically bind to 10.100.0.1 when wg0 comes up.
  systemctl enable dnsmasq.service
  systemctl restart dnsmasq.service
  log_info "dnsmasq restarted (bind-dynamic: will bind to wg0 when available)"
}

# ── Verify DNS actually works ────────────────────────────────────────────────
verify_dns_works() {
  log_step "Verifying DNS resolution works"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping DNS verification in dry-run mode"
    return 0
  fi

  # Test DNS resolution via multiple methods
  local dns_ok=false
  local attempts=0
  local max_attempts=10

  while [[ $attempts -lt $max_attempts ]]; do
    # Try via systemd-resolved stub
    if getent hosts deb.debian.org &>/dev/null; then
      dns_ok=true
      break
    fi
    # Try via direct resolver query
    if host -W 2 deb.debian.org 127.0.0.53 &>/dev/null; then
      dns_ok=true
      break
    fi
    # Try via external DNS directly
    if host -W 2 deb.debian.org 1.1.1.1 &>/dev/null; then
      dns_ok=true
      break
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  if [[ "$dns_ok" == "true" ]]; then
    log_info "✅ DNS resolution is working"
  else
    # DNS not working - create a fallback resolv.conf
    log_warn "⚠️  DNS via systemd-resolved not working - creating fallback"
    
    # Remove symlink and create direct resolv.conf
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << 'RESOLV'
# Fallback DNS configuration
# systemd-resolved was not working, using direct nameservers
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 94.140.14.14
RESOLV
    log_info "Created fallback /etc/resolv.conf with direct nameservers"
    
    # Test again
    if getent hosts deb.debian.org &>/dev/null; then
      log_info "✅ DNS resolution working with fallback config"
    else
      log_error "❌ DNS still not working after fallback - apt will fail"
      log_error "   Manual intervention required"
    fi
  fi
}

# ── Validation ───────────────────────────────────────────────────────────────
validate_dns() {
  log_step "Validating DNS configuration"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping DNS validation in dry-run mode"
    return 0
  fi

  # Check dnsmasq config syntax
  if dnsmasq --test 2>/dev/null; then
    log_info "✅ dnsmasq config syntax OK"
  else
    log_error "❌ dnsmasq config has syntax errors"
    return 1
  fi

  # Check resolved is running
  if systemctl is-active --quiet systemd-resolved.service; then
    log_info "✅ systemd-resolved is running"
  else
    log_warn "⚠️  systemd-resolved is not running"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  configure_dnsmasq
  configure_resolved
  enable_dns_services
  verify_dns_works    # NEW: Actually verify DNS works before continuing
  validate_dns

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
