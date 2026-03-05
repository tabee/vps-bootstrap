#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh — Local smoke tests for bootstrap scripts
# =============================================================================
# These tests verify the bootstrap scripts are syntactically correct and
# structurally sound WITHOUT requiring root or a live system.
#
# Run with: bash tests/smoke.sh
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

# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           VPS Bootstrap — Smoke Tests                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Structure tests ──────────────────────────────────────────────────────
echo "── Structure ──"
assert_file_exists "apply.sh"
assert_file_exists ".env.example"
assert_root_file_exists ".gitignore"
assert_root_file_exists "README.md"
assert_root_file_exists "main.tf"
assert_root_file_exists "variables.tf"
assert_root_file_exists "outputs.tf"
assert_root_file_exists "terraform.tfvars.example"
assert_file_exists "lib/logging.sh"
assert_file_exists "lib/backup.sh"

# Core modules
assert_file_exists "core/01-system.sh"
assert_file_exists "core/02-wireguard.sh"
assert_file_exists "core/03-firewall.sh"
assert_file_exists "core/04-docker.sh"
assert_file_exists "core/05-traefik.sh"
assert_file_exists "core/06-harden.sh"

# Service modules
assert_file_exists "services/gitea.sh"
assert_file_exists "services/n8n.sh"
assert_file_exists "services/whoami.sh"

# Scripts
assert_file_exists "scripts/vpn-client.sh"
echo ""

# ── 2. Syntax tests ─────────────────────────────────────────────────────────
echo "── Bash Syntax ──"
for script in apply.sh \
              lib/logging.sh lib/backup.sh \
              core/01-system.sh core/02-wireguard.sh \
              core/03-firewall.sh core/04-docker.sh \
              core/05-traefik.sh core/06-harden.sh \
              services/gitea.sh services/n8n.sh services/whoami.sh \
              scripts/vpn-client.sh; do
  assert_executable "$script"
done
echo ""

# ── 3. Security assertions ──────────────────────────────────────────────────
echo "── Security Assertions ──"

# nftables ruleset must have DROP policy
assert "nftables: input policy drop" \
  grep -q 'policy drop' "${BOOTSTRAP_DIR}/core/03-firewall.sh"

assert "nftables: forward policy drop" \
  grep -q 'policy drop' "${BOOTSTRAP_DIR}/core/03-firewall.sh"

# Docker daemon must disable iptables
assert "Docker: iptables false" \
  grep -q '"iptables": false' "${BOOTSTRAP_DIR}/core/04-docker.sh"

assert "Docker: ip6tables false" \
  grep -q '"ip6tables": false' "${BOOTSTRAP_DIR}/core/04-docker.sh"

# Traefik must disable dashboard
assert "Traefik: dashboard disabled" \
  grep -q 'dashboard: false' "${BOOTSTRAP_DIR}/core/05-traefik.sh"

# Traefik must use new Hetzner Cloud API (not old dns.hetzner.com)
assert "Traefik: Hetzner Cloud API" \
  grep -q 'api.hetzner.cloud' "${BOOTSTRAP_DIR}/core/05-traefik.sh"

# 06-harden must only listen on VPN
assert "SSH hardening: VPN only" \
  grep -q '10.100.0.1' "${BOOTSTRAP_DIR}/core/06-harden.sh"

assert "SSH hardening: no root" \
  grep -q 'PermitRootLogin no' "${BOOTSTRAP_DIR}/core/06-harden.sh"

echo ""

# ── 4. VPN client script completeness ───────────────────────────────────────
echo "── VPN Client Script ──"
vpn_script="${BOOTSTRAP_DIR}/scripts/vpn-client.sh"
assert "vpn-client: has add command" grep -q 'cmd_add' "$vpn_script"
assert "vpn-client: has remove command" grep -q 'cmd_remove' "$vpn_script"
assert "vpn-client: has list command" grep -q 'cmd_list' "$vpn_script"
assert "vpn-client: has sync command" grep -q 'cmd_sync' "$vpn_script"
assert "vpn-client: has qr command" grep -q 'cmd_qr' "$vpn_script"
assert "vpn-client: generates PSK" grep -q 'wg genpsk' "$vpn_script"
echo ""

# ── 5. Terraform configuration ──────────────────────────────────────────────
echo "── Terraform Configuration ──"
assert "variables.tf: has ssh_host" grep -q 'ssh_host' "${ROOT_DIR}/variables.tf"
assert "variables.tf: has domain" grep -q 'domain' "${ROOT_DIR}/variables.tf"
assert "variables.tf: has vpn_clients" grep -q 'vpn_clients' "${ROOT_DIR}/variables.tf"
assert "variables.tf: has enable_gitea" grep -q 'enable_gitea' "${ROOT_DIR}/variables.tf"
assert "main.tf: uses null_resource" grep -q 'null_resource' "${ROOT_DIR}/main.tf"
assert "main.tf: syncs vpn_clients" grep -q 'vpn-client.sh sync' "${ROOT_DIR}/main.tf"
assert "outputs.tf: has credentials output" grep -q 'credentials' "${ROOT_DIR}/outputs.tf"
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════════════"
echo "  Total: $((PASS + FAIL)) tests"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "══════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "❌ Some tests failed!"
  exit 1
else
  echo ""
  echo "✅ All tests passed!"
  exit 0
fi
