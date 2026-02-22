#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Pre-bootstrap environment validation
# =============================================================================
# Verifies the target system meets all prerequisites before any module runs.
# Must pass before apply.sh proceeds.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="preflight"

PREFLIGHT_ERRORS=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log_info "✅ $desc"
  else
    log_error "❌ $desc"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi
}

check_cmd() {
  local cmd="$1"
  check "Command available: $cmd" command -v "$cmd"
}

# ── Start ────────────────────────────────────────────────────────────────────
module_start "preflight"

# ── 1. Must be root ──────────────────────────────────────────────────────────
check "Running as root" test "$EUID" -eq 0

# ── 2. Debian version check ─────────────────────────────────────────────────
# Debian 12 (bookworm) is fully supported and tested.
# Debian 13 (trixie) may work but is not officially supported.
if grep -q 'VERSION_CODENAME=bookworm' /etc/os-release 2>/dev/null; then
  log_info "✅ OS is Debian 12 (bookworm) — fully supported"
elif grep -q 'VERSION_CODENAME=trixie' /etc/os-release 2>/dev/null; then
  log_warn "⚠️  OS is Debian 13 (trixie) — not officially supported"
  log_warn "   The bootstrap should work, but has not been fully tested."
  log_warn "   If you encounter issues, consider using Debian 12 (bookworm)."
  # WARNING only, not a blocking error
else
  log_error "❌ Unsupported OS — requires Debian 12 or 13"
  log_error "   Found: $(grep VERSION_CODENAME /etc/os-release 2>/dev/null || echo 'unknown')"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# ── 3. Architecture ─────────────────────────────────────────────────────────
check "Architecture is x86_64" test "$(uname -m)" = "x86_64"

# ── 4. Systemd is PID 1 ─────────────────────────────────────────────────────
check "systemd is init" test "$(cat /proc/1/comm)" = "systemd"

# ── 5. Required commands ────────────────────────────────────────────────────
for cmd in systemctl ip sysctl curl wget apt-get; do
  check_cmd "$cmd"
done

# ── 6. Network connectivity ─────────────────────────────────────────────────
check "DNS resolution works" host -W 5 deb.debian.org
check "Internet reachable" curl -sf --connect-timeout 10 -o /dev/null https://deb.debian.org/debian/dists/bookworm/Release

# ── 7. Sufficient disk space (>= 2 GB free on /) ────────────────────────────
check "At least 2 GB free on /" test "$(df --output=avail / | tail -1)" -ge 2097152

# ── 8. Env file exists ──────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  log_info "✅ .env file found"

  # Validate required variables
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"

  for var in HETZNER_API_TOKEN DB_PASSWORD WG_PRIVATE_KEY WG_PEER_PUBKEY \
             GITEA_SECRET_KEY GITEA_INTERNAL_TOKEN ACME_EMAIL; do
    if [[ -z "${!var:-}" ]]; then
      log_error "❌ Required variable $var not set in .env"
      PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
    else
      log_info "✅ Variable $var is set"
    fi
  done
else
  log_error "❌ .env file not found at ${SCRIPT_DIR}/.env"
  log_error "   Copy .env.example to .env and fill in secrets"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# ── 9. Check no conflicting services ────────────────────────────────────────
# Warn if legacy networking is active
if systemctl is-active --quiet networking.service 2>/dev/null; then
  log_warn "⚠️  networking.service is active — will be replaced by systemd-networkd"
fi

# Warn if wg-quick is active (we use systemd-networkd for WireGuard)
if systemctl is-active --quiet 'wg-quick@*' 2>/dev/null; then
  log_warn "⚠️  wg-quick@ is active — will be replaced by systemd-networkd"
fi

# ── Result ───────────────────────────────────────────────────────────────────
echo "" >&2
if [[ $PREFLIGHT_ERRORS -eq 0 ]]; then
  log_info "🎉 All preflight checks passed"
  exit 0
else
  log_fatal "💥 $PREFLIGHT_ERRORS preflight check(s) failed — aborting"
fi
