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
#   sudo ./bootstrap/apply.sh --module 04  # Run single module
#   sudo ./bootstrap/apply.sh --from 05    # Start from module 05
#
# Features:
#   - Lock-file prevents concurrent execution
#   - Automatic rollback on validation failure
#   - Comprehensive logging
#
# Prerequisites:
#   - Fresh Debian 12 (bookworm) x86_64 installation
#   - Root access
#   - Internet connectivity
#   - .env file with secrets (copy from .env.example)
#
# Module execution order:
#   01-system   → Base packages, sysctl, SSH hardening
#   02-network  → systemd-networkd, WireGuard
#   03-dns      → dnsmasq, systemd-resolved
#   04-firewall → nftables ruleset
#   05-docker   → Docker CE, daemon config, vpn_net network
#   06-traefik  → Traefik reverse proxy
#   07-gitea    → Gitea + PostgreSQL
#   08-whoami   → Diagnostic echo service
#   09-security → Fail2ban, auditd, unattended-upgrades
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"
source "${SCRIPT_DIR}/lib/validate.sh"

BOOTSTRAP_MODULE="apply"

# ── Lock-file to prevent concurrent execution ───────────────────────────────
LOCKFILE="/var/run/bootstrap.lock"

acquire_lock() {
  exec 200>"$LOCKFILE"
  if ! flock -n 200; then
    log_fatal "Another bootstrap process is already running (lockfile: $LOCKFILE)"
  fi
  # Write PID to lockfile
  echo $$ >&200
  log_debug "Acquired lock: $LOCKFILE (PID: $$)"
}

release_lock() {
  flock -u 200 2>/dev/null || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}

# Ensure lock is released on exit
trap release_lock EXIT

# ── Parse arguments ─────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
ON_VPN="${ON_VPN:-false}"
SINGLE_MODULE=""
START_FROM=""
SKIP_PREFLIGHT=false
SKIP_VALIDATION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=true
      export DRY_RUN
      shift
      ;;
    --on-vpn)
      ON_VPN=true
      export ON_VPN
      shift
      ;;
    --module|-m)
      SINGLE_MODULE="$2"
      shift 2
      ;;
    --from|-f)
      START_FROM="$2"
      shift 2
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --dry-run, -n           Show what would be done without making changes"
      echo "  --on-vpn                VPN-connected mode: omit WAN SSH rule, auto-run ssh-lockdown"
      echo "  --module, -m <NUM>      Run only the specified module (e.g., 04)"
      echo "  --from, -f <NUM>        Start from the specified module (e.g., 05)"
      echo "  --skip-preflight        Skip preflight checks"
      echo "  --skip-validation       Skip post-deployment validation"
      echo "  --help, -h              Show this help message"
      exit 0
      ;;
    *)
      log_fatal "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

export DRY_RUN

# ── Ordered module list ─────────────────────────────────────────────────────
MODULES=(
  "01-system"
  "02-network"
  "03-dns"
  "04-firewall"
  "05-docker"
  "06-traefik"
  "07-gitea"
  "08-whoami"
  "09-security"
)

# ── Acquire lock ────────────────────────────────────────────────────────────
acquire_lock

# ── Banner ───────────────────────────────────────────────────────────────────
echo "" >&2
log_step "╔══════════════════════════════════════════════════════════════╗"
log_step "║           VPS Bootstrap System                             ║"
log_step "║           Debian 12 → Hardened VPS                         ║"
log_step "╚══════════════════════════════════════════════════════════════╝"
echo "" >&2

if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "DRY-RUN MODE — no changes will be made"
  echo "" >&2
fi

if [[ "$ON_VPN" == "true" ]]; then
  log_warn "VPN-CONNECTED MODE — WAN SSH rule omitted, ssh-lockdown runs automatically"
  echo "" >&2
fi

# ── VPN connection verification (--on-vpn mode) ──────────────────────────────
if [[ "$ON_VPN" == "true" ]]; then
  log_step "Verifying VPN connection..."
  local_ssh_client_ip="$(get_ssh_client_ip)"
  if [[ -n "$local_ssh_client_ip" ]]; then
    if [[ "$local_ssh_client_ip" == 10.100.0.* ]]; then
      log_info "✅ Connected via VPN ($local_ssh_client_ip)"
    else
      log_fatal "Not connected via VPN (client IP: $local_ssh_client_ip) — connect via VPN first (ssh root@10.100.0.1)"
    fi
  else
    log_warn "⚠️  Cannot determine SSH client IP (local console?) — proceeding in VPN mode"
  fi
fi

# ── Environment initialization (first-run: creates .env, generates secrets) ──
log_step "Checking environment..."
if ! bash "${SCRIPT_DIR}/init-env.sh"; then
  exit 1  # init-env.sh already printed actionable instructions
fi

# ── Preflight checks ────────────────────────────────────────────────────────
if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
  log_step "Running preflight checks..."
  if ! bash "${SCRIPT_DIR}/preflight.sh"; then
    log_fatal "Preflight checks failed — aborting"
  fi
else
  log_warn "Preflight checks skipped (--skip-preflight)"
fi

# ── Initialize backup timestamp ─────────────────────────────────────────────
export BACKUP_TIMESTAMP
BACKUP_TIMESTAMP="$(date -u '+%Y%m%d_%H%M%S')"
log_info "Backup timestamp: $BACKUP_TIMESTAMP"

# ── Execute modules ─────────────────────────────────────────────────────────
run_module() {
  local mod="$1"
  local script="${SCRIPT_DIR}/modules/${mod}.sh"

  if [[ ! -f "$script" ]]; then
    log_fatal "Module script not found: $script"
  fi

  # Each module is sourced to share library functions and env
  bash "$script"
}

if [[ -n "$SINGLE_MODULE" ]]; then
  # Run a single module
  log_info "Running single module: $SINGLE_MODULE"
  run_module "$SINGLE_MODULE"
else
  # Run all modules (optionally starting from a specific one)
  local_started=false
  for mod in "${MODULES[@]}"; do
    # Handle --from flag
    if [[ -n "$START_FROM" ]]; then
      local mod_num="${mod%%-*}"
      local start_num="${START_FROM}"
      if [[ "$mod_num" -lt "$start_num" ]] && [[ "$local_started" != "true" ]]; then
        log_info "Skipping module: $mod (--from $START_FROM)"
        continue
      fi
      local_started=true
    fi

    run_module "$mod"
  done
fi

# ── Post-deployment validation ───────────────────────────────────────────────
if [[ "$SKIP_VALIDATION" != "true" && "$DRY_RUN" != "true" ]]; then
  echo "" >&2
  # Re-source validate.sh to get fresh functions
  source "${SCRIPT_DIR}/lib/validate.sh"
  BOOTSTRAP_MODULE="validation"
  
  if ! run_all_validations; then
    log_error "❌ Validation failed!"
    echo "" >&2
    log_warn "╔════════════════════════════════════════════════════════════════╗"
    log_warn "║  AUTO-ROLLBACK: Validation failed, reverting to backup state  ║"
    log_warn "╚════════════════════════════════════════════════════════════════╝"
    echo "" >&2
    
    # Attempt automatic rollback
    if [[ -d "/var/backups/bootstrap/${BACKUP_TIMESTAMP}" ]]; then
      log_info "Rolling back to: /var/backups/bootstrap/${BACKUP_TIMESTAMP}"
      if bash "${SCRIPT_DIR}/rollback.sh" --timestamp "$BACKUP_TIMESTAMP" --auto; then
        log_info "Rollback completed. Please investigate the issue."
      else
        log_error "Rollback failed! Manual intervention required."
        log_error "Backup location: /var/backups/bootstrap/${BACKUP_TIMESTAMP}"
      fi
    else
      log_warn "No backup found for automatic rollback."
      log_warn "Manual investigation required."
    fi
    
    exit 1
  fi
else
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Skipping validation in dry-run mode"
  else
    log_warn "Post-deployment validation skipped (--skip-validation)"
  fi
fi

# ── Auto ssh-lockdown in VPN-connected mode ──────────────────────────────────
if [[ "$ON_VPN" == "true" && "$DRY_RUN" != "true" ]]; then
  echo "" >&2
  log_step "Running SSH lockdown (--on-vpn mode)..."
  if bash "${SCRIPT_DIR}/ssh-lockdown.sh" --force; then
    log_info "✅ SSH locked down to VPN only"
  else
    log_warn "⚠️  SSH lockdown failed — run 'make ssh-lockdown' manually"
  fi
fi

# ── Final summary ───────────────────────────────────────────────────────────
echo "" >&2
log_step "╔══════════════════════════════════════════════════════════════╗"
log_step "║           Bootstrap Complete                                ║"
log_step "╚══════════════════════════════════════════════════════════════╝"
echo "" >&2

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry-run complete. No changes were made."
  log_info "Run without --dry-run to apply changes."
elif [[ "$ON_VPN" == "true" ]]; then
  log_info "System bootstrapped successfully (VPN-connected mode)."
  log_info "Backup stored at: /var/backups/bootstrap/${BACKUP_TIMESTAMP}/"
  echo "" >&2
  log_info "✅ SSH is restricted to VPN only (10.100.0.1)"
  log_info "✅ WAN SSH rule was NOT added to firewall"
  echo "" >&2
  log_info "Next steps:"
  log_info "  1. Verify final state:"
  log_info "       make validate"
  log_info "       make status"
  log_info ""
  log_info "  2. Test services (via VPN):"
  log_info "       curl -sk https://whoami.\${VPN_DOMAIN}"
  log_info "       curl -sk https://git.\${VPN_DOMAIN}"
else
  log_info "System bootstrapped successfully."
  log_info "Backup stored at: /var/backups/bootstrap/${BACKUP_TIMESTAMP}/"
  echo "" >&2
  log_warn "⚠️  IMPORTANT: SSH is currently accessible via WAN (bootstrap mode)"
  log_warn "   This is intentional for recovery access."
  echo "" >&2
  log_info "Next steps:"
  log_info "  1. Configure WireGuard on your client:"
  log_info "       make show-client"
  log_info "       # Copy output to /etc/wireguard/wg0.conf on client"
  log_info "       sudo wg-quick up wg0"
  log_info ""
  log_info "  2. Test VPN connectivity:"
  log_info "       ping 10.100.0.1"
  log_info "       ssh root@10.100.0.1"
  log_info ""
  log_info "  3. Test services (via VPN):"
  log_info "       curl -sk https://whoami.\${VPN_DOMAIN}"
  log_info "       curl -sk https://git.\${VPN_DOMAIN}"
  log_info ""
  log_info "  4. After VPN works, lock down SSH (removes WAN access):"
  log_info "       make ssh-lockdown"
  log_info ""
  log_info "  5. Verify final state:"
  log_info "       make validate"
  log_info "       make status"
fi
