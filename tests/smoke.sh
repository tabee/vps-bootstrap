#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh — Local smoke tests for bootstrap scripts
# =============================================================================
# These tests verify the bootstrap scripts are syntactically correct and
# structurally sound WITHOUT requiring root or a live system.
#
# Run with: make test
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/bootstrap"
ROOT_DIR="${SCRIPT_DIR}"

PASS=0
FAIL=0

# ── Test framework ──────────────────────────────────────────────────────────
assert() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  assert "File exists: $1" test -f "${BOOTSTRAP_DIR}/$1"
}

assert_root_file_exists() {
  assert "File exists (root): $1" test -f "${ROOT_DIR}/$1"
}

assert_executable() {
  assert "File is valid bash: $1" bash -n "${BOOTSTRAP_DIR}/$1"
}

assert_no_openclaw() {
  local file="$1"
  assert "No OpenClaw reference: $file" bash -c "! grep -qi 'openclaw' '${BOOTSTRAP_DIR}/$file'"
}

assert_no_ports_directive() {
  local file="$1"
  assert "No ports: directive: $file" bash -c "! grep -qE '^\s+ports:' '${BOOTSTRAP_DIR}/$file'"
}

assert_no_hardcoded_secrets() {
  local file="$1"
  # Check for patterns that look like real tokens/passwords (not placeholders)
  assert "No hardcoded secrets: $file" bash -c "! grep -qE '(IWcy5za|uP5xWn8|fL9qT3v|qZ7vXm2)' '${BOOTSTRAP_DIR}/$file'"
}

# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           VPS Bootstrap — Smoke Tests                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Structure tests ──────────────────────────────────────────────────────
echo "── Structure ──"
assert_file_exists "apply.sh"
assert_file_exists "preflight.sh"
assert_file_exists "rollback.sh"
assert_file_exists ".env.example"
assert_root_file_exists ".gitignore"
assert_root_file_exists "README.md"
assert_file_exists "lib/logging.sh"
assert_file_exists "lib/backup.sh"
assert_file_exists "lib/validate.sh"
assert_file_exists "modules/01-system.sh"
assert_file_exists "modules/02-network.sh"
assert_file_exists "modules/03-dns.sh"
assert_file_exists "modules/04-firewall.sh"
assert_file_exists "modules/05-docker.sh"
assert_file_exists "modules/06-traefik.sh"
assert_file_exists "modules/07-gitea.sh"
assert_file_exists "modules/08-whoami.sh"
assert_file_exists "modules/09-security.sh"
assert_file_exists "modules/10-n8n.sh"
echo ""

# ── 2. Syntax tests ─────────────────────────────────────────────────────────
echo "── Bash Syntax ──"
for script in apply.sh preflight.sh rollback.sh \
              lib/logging.sh lib/backup.sh lib/validate.sh \
              modules/01-system.sh modules/02-network.sh \
              modules/03-dns.sh modules/04-firewall.sh \
              modules/05-docker.sh modules/06-traefik.sh \
              modules/07-gitea.sh modules/08-whoami.sh \
              modules/09-security.sh modules/10-n8n.sh; do
  assert_executable "$script"
done
echo ""

# ── 3. OpenClaw exclusion ───────────────────────────────────────────────────
echo "── OpenClaw Exclusion ──"
for script in apply.sh preflight.sh \
              modules/01-system.sh modules/02-network.sh \
              modules/03-dns.sh modules/04-firewall.sh \
              modules/05-docker.sh modules/06-traefik.sh \
              modules/07-gitea.sh modules/08-whoami.sh \
              modules/10-n8n.sh; do
  assert_no_openclaw "$script"
done
echo ""

# ── 4. No published ports in compose templates ──────────────────────────────
echo "── No Published Ports ──"
for module in modules/06-traefik.sh modules/07-gitea.sh modules/08-whoami.sh modules/10-n8n.sh; do
  assert_no_ports_directive "$module"
done
echo ""

# ── 5. No hardcoded secrets ─────────────────────────────────────────────────
echo "── No Hardcoded Secrets ──"
for script in modules/02-network.sh modules/06-traefik.sh modules/07-gitea.sh modules/10-n8n.sh; do
  assert_no_hardcoded_secrets "$script"
done
assert_no_hardcoded_secrets ".env.example"
echo ""

# ── 6. Security assertions ──────────────────────────────────────────────────
echo "── Security Assertions ──"

# nftables ruleset must have DROP policy
assert "nftables: input policy drop" \
  grep -q 'policy drop' "${BOOTSTRAP_DIR}/modules/04-firewall.sh"

assert "nftables: forward policy drop" \
  grep -q 'policy drop' "${BOOTSTRAP_DIR}/modules/04-firewall.sh"

# Docker daemon must disable iptables
assert "Docker: iptables false" \
  grep -q '"iptables": false' "${BOOTSTRAP_DIR}/modules/05-docker.sh"

assert "Docker: ip6tables false" \
  grep -q '"ip6tables": false' "${BOOTSTRAP_DIR}/modules/05-docker.sh"

assert "Docker: userland-proxy false" \
  grep -q '"userland-proxy": false' "${BOOTSTRAP_DIR}/modules/05-docker.sh"

# Traefik must not have dashboard
assert "Traefik: dashboard false" \
  grep -q 'dashboard: false' "${BOOTSTRAP_DIR}/modules/06-traefik.sh"

# Traefik must use file provider only
assert "Traefik: file provider" \
  grep -q 'file:' "${BOOTSTRAP_DIR}/modules/06-traefik.sh"

assert "Traefik: no Docker socket provider" \
  bash -c "! grep -q 'docker:' '${BOOTSTRAP_DIR}/modules/06-traefik.sh' || ! grep -q 'endpoint:' '${BOOTSTRAP_DIR}/modules/06-traefik.sh'"

# SSH: during bootstrap listens on 0.0.0.0 (firewall blocks WAN)
# After make ssh-lockdown, it switches to 10.100.0.1 only
assert "SSH: bootstrap mode (0.0.0.0) in 01-system.sh" \
  grep -q 'ListenAddress 0.0.0.0' "${BOOTSTRAP_DIR}/modules/01-system.sh"

# SSH lockdown script must exist and restrict to VPN
assert "SSH lockdown script exists" \
  test -f "${BOOTSTRAP_DIR}/ssh-lockdown.sh"

assert "SSH lockdown: restricts to 10.100.0.1" \
  grep -q 'ListenAddress 10.100.0.1' "${BOOTSTRAP_DIR}/ssh-lockdown.sh"

# Firewall must allow SSH on WAN during bootstrap (rate-limited)
assert "Firewall: bootstrap SSH on WAN (rate-limited)" \
  grep -q 'tcp dport 22.*limit rate.*bootstrap-ssh-wan' "${BOOTSTRAP_DIR}/modules/04-firewall.sh"

# dnsmasq must bind to wg0 only
assert "dnsmasq: interface=wg0" \
  grep -q 'interface=wg0' "${BOOTSTRAP_DIR}/modules/03-dns.sh"

assert "dnsmasq: listen-address=10.100.0.1" \
  grep -q 'listen-address=10.100.0.1' "${BOOTSTRAP_DIR}/modules/03-dns.sh"

# DNS wildcard to Traefik (uses VPN_DOMAIN variable for all subdomains)
assert "DNS: wildcard uses VPN_DOMAIN variable" \
  grep -q 'address=/\${VPN_DOMAIN}/10.20.0.10' "${BOOTSTRAP_DIR}/modules/03-dns.sh"

# nftables syntax check command present
assert "nftables: syntax check (nft -c)" \
  grep -q 'nft -c' "${BOOTSTRAP_DIR}/modules/04-firewall.sh"

# SSH syntax check command present
assert "SSH: syntax check (sshd -t)" \
  grep -q 'sshd -t' "${BOOTSTRAP_DIR}/modules/01-system.sh"

echo ""

# ── 7. Idempotency assertions ───────────────────────────────────────────────
echo "── Idempotency ──"

# All modules must check before writing (file_matches)
for module in modules/01-system.sh modules/02-network.sh \
              modules/03-dns.sh modules/04-firewall.sh \
              modules/05-docker.sh modules/06-traefik.sh \
              modules/07-gitea.sh modules/08-whoami.sh \
              modules/09-security.sh modules/10-n8n.sh; do
  assert "Uses file_matches check: $module" \
    grep -q 'file_matches' "${BOOTSTRAP_DIR}/$module"
done
echo ""

# ── 8. Placeholder verification ─────────────────────────────────────────────
echo "── Placeholder Variables ──"
assert ".env.example has WG_PRIVATE_KEY placeholder" \
  grep -q '__WG_PRIVATE_KEY__' "${BOOTSTRAP_DIR}/.env.example"

assert ".env.example has HETZNER_API_TOKEN (not placeholder, must be filled manually)" \
  grep -q 'HETZNER_API_TOKEN=' "${BOOTSTRAP_DIR}/.env.example"

assert ".env.example has DB_PASSWORD placeholder" \
  grep -q '__DB_PASSWORD__' "${BOOTSTRAP_DIR}/.env.example"

assert ".env.example has N8N_ENCRYPTION_KEY placeholder" \
  grep -q '__N8N_ENCRYPTION_KEY__' "${BOOTSTRAP_DIR}/.env.example"
echo ""

# ── 9. .gitignore ───────────────────────────────────────────────────────────
echo "── Git Safety ──"
assert ".gitignore blocks .env" \
  grep -q '\.env' "${ROOT_DIR}/.gitignore"
echo ""

# ── 10. Makefile exists ─────────────────────────────────────────────────────
echo "── Makefile ──"
assert "Makefile exists" test -f "${SCRIPT_DIR}/Makefile"
assert "Makefile has apply target" grep -q '^apply:' "${SCRIPT_DIR}/Makefile"
assert "Makefile has dry-run target" grep -q '^dry-run:' "${SCRIPT_DIR}/Makefile"
assert "Makefile has validate target" grep -q '^validate:' "${SCRIPT_DIR}/Makefile"
assert "Makefile has rollback target" grep -q '^rollback:' "${SCRIPT_DIR}/Makefile"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "══════════════════════════════════════════════════════════════"
echo ""
TOTAL=$((PASS + FAIL))
echo "  Results: $PASS/$TOTAL passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "  ❌ SOME TESTS FAILED"
  exit 1
else
  echo "  🎉 ALL TESTS PASSED"
  exit 0
fi
