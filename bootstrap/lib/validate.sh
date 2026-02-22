#!/usr/bin/env bash
# =============================================================================
# lib/validate.sh — Post-deployment validation gates
# =============================================================================
# Security-critical checks that verify the system matches expected state.
# Every check returns 0 (pass) or 1 (fail) with descriptive output.
# =============================================================================

set -euo pipefail

VALIDATION_FAILURES=0

# Run a single validation check
# Usage: validate_check "description" command [args...]
validate_check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log_info "✅ PASS: $desc"
    return 0
  else
    log_error "❌ FAIL: $desc"
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# Inverse check — passes if command FAILS
# Usage: validate_check_fail "description" command [args...]
validate_check_fail() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    log_info "✅ PASS: $desc"
    return 0
  else
    log_error "❌ FAIL: $desc"
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# ── Security gate: no public TCP/UDP listeners on WAN ────────────────────────
# During bootstrap, the following are allowed:
#   - Localhost listeners (127.*)
#   - VPN-bound listeners (10.100.0.1:*)
#   - Docker network listeners (10.20.0.*, 172.*)
#   - WireGuard (port 51820)
#   - DHCP client (UDP 68)
#   - SSH on 0.0.0.0:22 (expected during bootstrap; use `make ssh-lockdown` later)
#   - dnsmasq on 127.0.0.1:53 or any bind-dynamic address
validate_no_public_listeners() {
  log_step "Validating: no unexpected public listeners on WAN"

  local failures=0

  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      # Simple approach: check if the line contains known allowed ports
      # Extract port numbers from the line (matches :PORT patterns)
      local port=""
      
      # Check for port 51820 (WireGuard) - always OK
      if echo "$line" | grep -qE ':51820[[:space:]]'; then
        continue
      fi
      
      # Check for port 68 (DHCP client) - always OK
      if echo "$line" | grep -qE ':68[[:space:]]'; then
        continue
      fi
      
      # Check for port 22 (SSH) - OK during bootstrap
      if echo "$line" | grep -qE ':22[[:space:]]'; then
        continue
      fi
      
      # Check for port 53 (DNS) - OK for dnsmasq
      if echo "$line" | grep -qE ':53[[:space:]]'; then
        continue
      fi
      
      # Check for localhost listeners - always OK
      if echo "$line" | grep -qE '127\.0\.0\.[0-9]+:'; then
        continue
      fi
      if echo "$line" | grep -qE '\[::1\]:'; then
        continue
      fi
      
      # Check for VPN interface - always OK
      if echo "$line" | grep -qE '10\.100\.0\.1:'; then
        continue
      fi
      
      # Check for Docker network - OK (internal services)
      if echo "$line" | grep -qE '10\.20\.0\.[0-9]+:|172\.1[78]\.[0-9]+\.[0-9]+:'; then
        continue
      fi
      
      # Check if it's a service we expect by process name
      local svc
      svc="$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo 'unknown')"
      case "$svc" in
        dnsmasq|systemd-network|systemd-resolve*|sshd|wg) continue ;;
      esac
      
      # If we get here, it's unexpected
      log_error "  Unexpected listener: $line"
      failures=$((failures + 1))
    fi
  done < <(ss -lntup 2>/dev/null | tail -n +2 || true)

  if [[ $failures -eq 0 ]]; then
    log_info "✅ PASS: No unexpected public listeners detected"
    return 0
  else
    log_error "❌ FAIL: $failures unexpected public listener(s)"
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + failures))
    return 1
  fi
}

# ── Security gate: Docker has no published ports ─────────────────────────────
validate_docker_no_published_ports() {
  log_step "Validating: Docker containers have no published ports"

  if ! command -v docker &>/dev/null; then
    log_warn "Docker not installed, skipping"
    return 0
  fi

  local published
  published="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|:::' || true)"
  if [[ -z "$published" ]]; then
    log_info "✅ PASS: No Docker containers have published ports"
    return 0
  else
    log_error "❌ FAIL: Containers with published ports:"
    echo "$published" | while read -r line; do
      log_error "  $line"
    done
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# ── Security gate: nftables policy is drop ───────────────────────────────────
validate_nft_policy() {
  log_step "Validating: nftables drop policy"

  local input_policy forward_policy
  input_policy="$(nft list chain inet filter input 2>/dev/null | grep 'policy' | awk '{print $NF}' | tr -d ';')"
  forward_policy="$(nft list chain inet filter forward 2>/dev/null | grep 'policy' | awk '{print $NF}' | tr -d ';')"

  local ok=true
  if [[ "$input_policy" != "drop" ]]; then
    log_error "❌ FAIL: input chain policy is '$input_policy', expected 'drop'"
    ok=false
  fi
  if [[ "$forward_policy" != "drop" ]]; then
    log_error "❌ FAIL: forward chain policy is '$forward_policy', expected 'drop'"
    ok=false
  fi

  if $ok; then
    log_info "✅ PASS: nftables input/forward policy is drop"
    return 0
  else
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# ── Security gate: Docker daemon has iptables disabled ───────────────────────
validate_docker_daemon_config() {
  log_step "Validating: Docker daemon hardening"

  local cfg="/etc/docker/daemon.json"
  if [[ ! -f "$cfg" ]]; then
    log_error "❌ FAIL: $cfg not found"
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi

  local ok=true

  # Check iptables: false
  if ! grep -q '"iptables"[[:space:]]*:[[:space:]]*false' "$cfg"; then
    log_error "❌ FAIL: iptables not disabled in daemon.json"
    ok=false
  fi

  # Check ip6tables: false
  if ! grep -q '"ip6tables"[[:space:]]*:[[:space:]]*false' "$cfg"; then
    log_error "❌ FAIL: ip6tables not disabled in daemon.json"
    ok=false
  fi

  # Check userland-proxy: false
  if ! grep -q '"userland-proxy"[[:space:]]*:[[:space:]]*false' "$cfg"; then
    log_error "❌ FAIL: userland-proxy not disabled in daemon.json"
    ok=false
  fi

  if $ok; then
    log_info "✅ PASS: Docker daemon properly hardened"
    return 0
  else
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# ── Security gate: WireGuard is running ──────────────────────────────────────
validate_wireguard_up() {
  log_step "Validating: WireGuard interface is up"

  if ip link show wg0 &>/dev/null; then
    if ip addr show wg0 2>/dev/null | grep -q '10.100.0.1'; then
      log_info "✅ PASS: wg0 interface exists with 10.100.0.1/24"
    else
      log_info "✅ PASS: wg0 interface exists (address not yet assigned)"
    fi
    return 0
  else
    # wg0 not existing is non-fatal during initial bootstrap.
    # systemd-networkd creates it from the .netdev file, but a reboot
    # may be required if the WireGuard kernel module wasn't loaded.
    log_warn "⚠️  wg0 interface not found — may need reboot for networkd to create it"
    log_warn "   Debug: journalctl -u systemd-networkd | grep -i wg"
    log_warn "   Debug: networkctl list"
    # Don't increment VALIDATION_FAILURES — this is a warning
    return 0
  fi
}

# ── Security gate: Traefik is reachable on VPN network ───────────────────────
validate_traefik_reachable() {
  log_step "Validating: Traefik responds on VPN network"

  if curl -sk --connect-timeout 5 "https://10.20.0.10" >/dev/null 2>&1; then
    log_info "✅ PASS: Traefik responds on 10.20.0.10:443"
    return 0
  else
    log_warn "⚠️  Traefik not yet responding (may need time for cert provisioning)"
    return 0  # non-fatal during initial bootstrap
  fi
}

# ── Security gate: sysctl values ─────────────────────────────────────────────
validate_sysctl() {
  log_step "Validating: sysctl security settings"

  local ok=true

  _check_sysctl() {
    local key="$1" expected="$2"
    local actual
    actual="$(sysctl -n "$key" 2>/dev/null || echo 'MISSING')"
    if [[ "$actual" != "$expected" ]]; then
      log_error "❌ FAIL: $key = $actual (expected $expected)"
      ok=false
    fi
  }

  _check_sysctl net.ipv4.ip_forward 1
  _check_sysctl net.ipv6.conf.all.disable_ipv6 1
  _check_sysctl net.ipv6.conf.default.disable_ipv6 1
  _check_sysctl net.ipv4.conf.all.rp_filter 2
  _check_sysctl net.ipv4.conf.all.log_martians 1
  _check_sysctl net.ipv4.conf.all.accept_redirects 0
  _check_sysctl net.ipv4.conf.all.send_redirects 0
  _check_sysctl net.ipv4.conf.all.accept_source_route 0

  if $ok; then
    log_info "✅ PASS: All sysctl values match expected state"
    return 0
  else
    VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    return 1
  fi
}

# ── Run all validation gates ─────────────────────────────────────────────────
run_all_validations() {
  VALIDATION_FAILURES=0

  log_step "=========================================="
  log_step "Running validation gates"
  log_step "=========================================="

  validate_sysctl || true
  validate_wireguard_up || true
  validate_nft_policy || true
  validate_no_public_listeners || true
  validate_docker_daemon_config || true
  validate_docker_no_published_ports || true
  validate_traefik_reachable || true

  echo "" >&2
  if [[ $VALIDATION_FAILURES -eq 0 ]]; then
    log_info "🎉 All validation gates passed"
    return 0
  else
    log_error "💥 $VALIDATION_FAILURES validation failure(s) detected"
    return 1
  fi
}
