#!/usr/bin/env bash
# =============================================================================
# ssh-lockdown.sh — Restrict SSH to VPN only and harden firewall
# =============================================================================
# Run this AFTER you have verified:
#   1. WireGuard VPN is working (wg show wg0)
#   2. You can SSH via VPN (ssh root@10.100.0.1)
#
# This script:
#   1. Updates SSH to listen only on 10.100.0.1 (VPN interface)
#   2. Removes the WAN SSH rule from nftables
#   3. Persists the changes
#
# ⚠️  WARNING: Running this without a working VPN will lock you out!
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="ssh-lockdown"

FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f) FORCE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--force]"
      echo "  --force  Skip confirmation prompt and VPN check (for automated use)"
      exit 0
      ;;
    *) log_fatal "Unknown option: $1" ;;
  esac
done

# Colors for emphasis
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── Preflight checks ─────────────────────────────────────────────────────────
preflight_checks() {
  log_step "Running preflight checks for SSH lockdown"

  # Must be root
  if [[ $EUID -ne 0 ]]; then
    log_fatal "This script must be run as root"
  fi

  # Check if wg0 is up
  if ! ip link show wg0 &>/dev/null; then
    echo -e "${RED}❌ ERROR: wg0 interface does not exist!${NC}" >&2
    echo "" >&2
    echo "The WireGuard VPN interface is not up. You cannot lock down SSH" >&2
    echo "without a working VPN or you will lose access to the server." >&2
    echo "" >&2
    echo "Debug commands:" >&2
    echo "  ip link show wg0" >&2
    echo "  wg show wg0" >&2
    echo "  journalctl -u systemd-networkd | grep -i wg" >&2
    echo "" >&2
    exit 1
  fi

  # Check if wg0 has the expected IP
  if ! ip addr show wg0 2>/dev/null | grep -q '10.100.0.1'; then
    echo -e "${YELLOW}⚠️  WARNING: wg0 does not have IP 10.100.0.1${NC}" >&2
    echo "" >&2
    echo "Current wg0 addresses:" >&2
    ip addr show wg0 | grep inet >&2
    echo "" >&2
    if [[ "$FORCE" != "true" ]]; then
      read -p "Continue anyway? This may lock you out! [y/N] " -r
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
      fi
    else
      log_warn "Proceeding despite unexpected wg0 address (--force)"
    fi
  fi

  # Check if we're connected via VPN (not WAN)
  # Skipped in --force mode (caller already verified this)
  if [[ "$FORCE" != "true" ]]; then
    local ssh_client_ip
    ssh_client_ip="$(get_ssh_client_ip)"
    if [[ -n "$ssh_client_ip" ]]; then
      if [[ "$ssh_client_ip" == 10.100.0.* ]]; then
        log_info "✅ Connected via VPN ($ssh_client_ip)"
      else
        echo -e "${RED}❌ ERROR: You are connected via WAN ($ssh_client_ip)!${NC}" >&2
        echo "" >&2
        echo "You are currently connected via the public IP, not the VPN." >&2
        echo "If you lock down SSH now, your current session will be terminated" >&2
        echo "and you won't be able to reconnect." >&2
        echo "" >&2
        echo "First, connect via VPN:" >&2
        echo "  ssh root@10.100.0.1" >&2
        echo "" >&2
        echo "Then run this script again from that VPN session." >&2
        exit 1
      fi
    else
      log_warn "⚠️  Cannot determine SSH client IP (local console?)"
    fi
  fi

  log_info "✅ Preflight checks passed"
}

# ── Update SSH configuration ─────────────────────────────────────────────────
lockdown_ssh() {
  log_step "Configuring SSH to listen only on VPN (10.100.0.1)"

  local sshd_conf="/etc/ssh/sshd_config.d/99-bootstrap.conf"
  local sshd_vpn_conf="/etc/ssh/sshd_config.d/99-vpn-only.conf"

  # Create the VPN-only config
  cat > "$sshd_vpn_conf" << 'EOF'
# =============================================================================
# 99-vpn-only.conf — SSH restricted to VPN interface only
# =============================================================================
# Created by: make ssh-lockdown
# This overrides ListenAddress from 99-bootstrap.conf
#
# To revert: rm /etc/ssh/sshd_config.d/99-vpn-only.conf && systemctl reload ssh

ListenAddress 10.100.0.1
EOF

  chmod 0644 "$sshd_vpn_conf"
  chown root:root "$sshd_vpn_conf"
  log_info "Created $sshd_vpn_conf"

  # Comment out the old ListenAddress in bootstrap.conf
  if [[ -f "$sshd_conf" ]]; then
    sed -i 's/^ListenAddress 0.0.0.0/# ListenAddress 0.0.0.0  # Disabled by ssh-lockdown/' "$sshd_conf"
    log_info "Disabled ListenAddress 0.0.0.0 in $sshd_conf"
  fi

  # Validate SSH config
  if ! sshd -t; then
    log_error "SSH config validation failed!"
    rm -f "$sshd_vpn_conf"
    # Restore original
    if [[ -f "$sshd_conf" ]]; then
      sed -i 's/^# ListenAddress 0.0.0.0  # Disabled by ssh-lockdown/ListenAddress 0.0.0.0/' "$sshd_conf"
    fi
    log_fatal "Reverted changes due to invalid SSH config"
  fi

  # Reload SSH
  systemctl reload ssh
  log_info "✅ SSH now listening only on 10.100.0.1"
}

# ── Update firewall ──────────────────────────────────────────────────────────
lockdown_firewall() {
  log_step "Removing WAN SSH rule from firewall"

  # Remove the bootstrap SSH rule from nftables
  # The rule has a comment "bootstrap-ssh-wan" for easy identification
  if nft list ruleset 2>/dev/null | grep -q 'bootstrap-ssh-wan'; then
    # Delete the rule by handle (more reliable)
    local handle
    handle=$(nft -a list chain inet filter input 2>/dev/null | grep 'bootstrap-ssh-wan' | grep -oP 'handle \K\d+' || true)
    if [[ -n "$handle" ]]; then
      nft delete rule inet filter input handle "$handle"
      log_info "Removed WAN SSH rule (handle $handle) from active ruleset"
    fi
  else
    log_info "WAN SSH rule not found in active ruleset (already removed?)"
  fi

  # Update /etc/nftables.conf to remove the bootstrap SSH rule
  local nft_conf="/etc/nftables.conf"
  if [[ -f "$nft_conf" ]]; then
    if grep -q 'bootstrap-ssh-wan' "$nft_conf"; then
      # Comment out the line instead of removing it (for audit trail)
      sed -i 's/^[[:space:]]*iifname \$WAN_IF tcp dport 22.*bootstrap-ssh-wan.*$/    # REMOVED by ssh-lockdown: WAN SSH disabled/' "$nft_conf"
      log_info "Updated $nft_conf (WAN SSH rule disabled)"
    else
      log_info "WAN SSH rule not found in $nft_conf (already removed?)"
    fi
  fi

  log_info "✅ Firewall updated — SSH blocked on WAN"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo "" >&2
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}" >&2
  echo -e "${YELLOW}║           SSH Lockdown — Restrict SSH to VPN Only           ║${NC}" >&2
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}" >&2
  echo "" >&2
  
  if [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}⚠️  WARNING: This will disable SSH access via the public IP!${NC}" >&2
    echo "" >&2
    echo "After this, you can ONLY connect via WireGuard VPN:" >&2
    echo "  ssh root@10.100.0.1" >&2
    echo "" >&2
    echo "Make sure:" >&2
    echo "  1. Your WireGuard VPN is connected (wg-quick up wg0)" >&2
    echo "  2. You can reach 10.100.0.1 from your client" >&2
    echo "  3. You are currently connected via VPN, not WAN" >&2
    echo "" >&2

    read -p "Are you sure you want to proceed? [y/N] " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  preflight_checks
  lockdown_ssh
  lockdown_firewall

  echo "" >&2
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}" >&2
  echo -e "${GREEN}║           SSH Lockdown Complete                             ║${NC}" >&2
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}" >&2
  echo "" >&2
  echo -e "${GREEN}✅ SSH is now restricted to VPN only (10.100.0.1)${NC}" >&2
  echo "" >&2
  echo "Your current VPN session remains active." >&2
  echo "Test by opening a new terminal and connecting via VPN:" >&2
  echo "  ssh root@10.100.0.1" >&2
  echo "" >&2
  echo "To revert (if needed via Hetzner console):" >&2
  echo "  rm /etc/ssh/sshd_config.d/99-vpn-only.conf" >&2
  echo "  nft add rule inet filter input iifname eth0 tcp dport 22 accept" >&2
  echo "  systemctl reload ssh" >&2
}

main "$@"
