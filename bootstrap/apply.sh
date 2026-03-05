#!/usr/bin/env bash
# =============================================================================
# apply.sh — Main bootstrap orchestrator
# =============================================================================
# Executes all modules in order to build a hardened VPS from a
# fresh Debian 12 installation.
#
# Usage:
#   sudo ./bootstrap/apply.sh              # Full apply
#   sudo ./bootstrap/apply.sh --dry-run    # Dry-run (no changes)
#   sudo ./bootstrap/apply.sh --skip-harden  # Skip final hardening
#
# Architecture:
#   PHASE 1: Basis-Sicherheit (sofort aktiv)
#     01-system.sh    → Pakete, IPv6-off, Fail2ban, Admin-User
#     02-wireguard.sh → VPN (Fluchtweg für Admin)
#     03-firewall.sh  → nftables (UDP 51820 only)
#
#   PHASE 2: Services (nach VPN + Firewall)
#     04-docker.sh    → Docker + vpn_net
#     05-traefik.sh   → Reverse Proxy + TLS
#     [Optional]      → gitea.sh, n8n.sh, whoami.sh
#
#   PHASE 3: Lockdown (am Ende, nach VPN-Test)
#     06-harden.sh    → SSH VPN-only, Root-Lockdown
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="apply"

# ── Parse arguments ─────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
SKIP_HARDEN="${SKIP_HARDEN:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=true
      export DRY_RUN
      shift
      ;;
    --skip-harden)
      SKIP_HARDEN=true
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --dry-run, -n     Show what would be done without making changes
  --skip-harden     Skip final hardening (SSH remains accessible via WAN)
  --help, -h        Show this help message

Environment:
  Set these in .env or export before running:
    ENABLE_GITEA=true/false   Install Gitea git server
    ENABLE_N8N=true/false     Install n8n workflow automation
    ENABLE_WHOAMI=true/false  Install whoami test service
    ENABLE_GOGCLI=true/false  Install Google Workspace CLI (SSH-Zugriff)
    ADMIN_USER=admin          SSH user after hardening
EOF
      exit 0
      ;;
    *)
      log_fatal "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

export DRY_RUN

# ── Load environment ────────────────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Service flags (can be set in .env or environment)
ENABLE_GITEA="${ENABLE_GITEA:-false}"
ENABLE_N8N="${ENABLE_N8N:-false}"
ENABLE_WHOAMI="${ENABLE_WHOAMI:-true}"
ENABLE_GOGCLI="${ENABLE_GOGCLI:-false}"
ADMIN_USER="${ADMIN_USER:-admin}"

# ── Lock-file to prevent concurrent execution ───────────────────────────────
LOCKFILE="/var/run/bootstrap.lock"

acquire_lock() {
  exec 200>"$LOCKFILE"
  if ! flock -n 200; then
    log_fatal "Another bootstrap process is already running (lockfile: $LOCKFILE)"
  fi
  echo $$ >&200
}

release_lock() {
  flock -u 200 2>/dev/null || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}

trap release_lock EXIT

# ── Run single module ───────────────────────────────────────────────────────
run_core_module() {
  local mod="$1"
  local script="${SCRIPT_DIR}/core/${mod}.sh"

  if [[ ! -f "$script" ]]; then
    log_fatal "Core module not found: $script"
  fi

  log_step "▶ ${mod}"
  bash "$script"
}

run_service_module() {
  local mod="$1"
  local script="${SCRIPT_DIR}/services/${mod}.sh"

  if [[ ! -f "$script" ]]; then
    log_warn "Service module not found: $script"
    return 0
  fi

  log_step "▶ ${mod} (service)"
  bash "$script"
}

# ── Main execution ──────────────────────────────────────────────────────────
main() {
  require_root
  acquire_lock
  
  # Banner
  echo "" >&2
  log_step "╔══════════════════════════════════════════════════════════════╗"
  log_step "║           VPS Bootstrap - Debian 12                         ║"
  log_step "╚══════════════════════════════════════════════════════════════╝"
  echo "" >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY-RUN MODE — no changes will be made"
    echo "" >&2
  fi

  # Initialize backup timestamp
  export BACKUP_TIMESTAMP
  BACKUP_TIMESTAMP="$(date -u '+%Y%m%d_%H%M%S')"
  
  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 1: Basis-Sicherheit
  # ─────────────────────────────────────────────────────────────────────────
  log_step "════════════════════════════════════════════════════════════════"
  log_step "  PHASE 1: Basis-Sicherheit"
  log_step "════════════════════════════════════════════════════════════════"
  
  run_core_module "01-system"
  run_core_module "02-wireguard"
  run_core_module "03-firewall"
  
  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 2: Services
  # ─────────────────────────────────────────────────────────────────────────
  log_step "════════════════════════════════════════════════════════════════"
  log_step "  PHASE 2: Docker + Services"
  log_step "════════════════════════════════════════════════════════════════"
  
  run_core_module "04-docker"
  run_core_module "05-traefik"
  
  # Optional services
  [[ "$ENABLE_GITEA" == "true" ]] && run_service_module "gitea"
  [[ "$ENABLE_N8N" == "true" ]] && run_service_module "n8n"
  [[ "$ENABLE_WHOAMI" == "true" ]] && run_service_module "whoami"
  [[ "$ENABLE_GOGCLI" == "true" ]] && run_service_module "gogcli"
  
  # ─────────────────────────────────────────────────────────────────────────
  # PHASE 3: Lockdown
  # ─────────────────────────────────────────────────────────────────────────
  if [[ "$SKIP_HARDEN" == "true" ]]; then
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn "  PHASE 3: Hardening SKIPPED (--skip-harden)"
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn "  ⚠️  SSH is still accessible via public IP!"
    log_warn "  Run manually when VPN is configured:"
    log_warn "    sudo bash ${SCRIPT_DIR}/core/06-harden.sh"
  else
    log_step "════════════════════════════════════════════════════════════════"
    log_step "  PHASE 3: Lockdown (VPN Checkpoint)"
    log_step "════════════════════════════════════════════════════════════════"
    
    # VPN checkpoint: Ensure at least one peer is configured
    if ! grep -q "WireGuardPeer" /etc/systemd/network/99-wg0.netdev 2>/dev/null; then
      log_warn "╔════════════════════════════════════════════════════════════════╗"
      log_warn "║  WARNUNG: Kein WireGuard-Client konfiguriert!                 ║"
      log_warn "╠════════════════════════════════════════════════════════════════╣"
      log_warn "║  Härtung wird NICHT ausgeführt (Lockout-Schutz).             ║"
      log_warn "║                                                               ║"
      log_warn "║  VPN-Client erstellen:                                        ║"
      log_warn "║    sudo ${SCRIPT_DIR}/scripts/vpn-client.sh add admin        ║"
      log_warn "║                                                               ║"
      log_warn "║  Config anzeigen:                                             ║"
      log_warn "║    sudo ${SCRIPT_DIR}/scripts/vpn-client.sh show admin       ║"
      log_warn "║                                                               ║"
      log_warn "║  Nach VPN-Verbindung Härtung manuell ausführen:              ║"
      log_warn "║    sudo bash ${SCRIPT_DIR}/core/06-harden.sh                 ║"
      log_warn "╚════════════════════════════════════════════════════════════════╝"
    else
      run_core_module "06-harden"
    fi
  fi
  
  # ─────────────────────────────────────────────────────────────────────────
  # Summary
  # ─────────────────────────────────────────────────────────────────────────
  echo "" >&2
  log_step "╔══════════════════════════════════════════════════════════════╗"
  log_step "║           Bootstrap Complete ✓                              ║"
  log_step "╚══════════════════════════════════════════════════════════════╝"
  echo "" >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry-run complete. No changes were made."
  else
    log_info "System bootstrapped successfully."
    echo "" >&2
    log_info "VPN Client Config:"
    log_info "  Show:  sudo ${SCRIPT_DIR}/scripts/vpn-client.sh show admin"
    log_info "  QR:    sudo ${SCRIPT_DIR}/scripts/vpn-client.sh qr admin"
    echo "" >&2
    log_info "After connecting VPN:"
    log_info "  SSH:   ssh ${ADMIN_USER}@10.100.0.1"
    log_info "  Root:  sudo -i"
  fi
}

main "$@"
