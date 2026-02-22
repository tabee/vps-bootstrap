#!/usr/bin/env bash
# =============================================================================
# rollback.sh — Restore system from bootstrap backup
# =============================================================================
# Restores configuration files from a previous bootstrap run.
#
# Usage:
#   sudo ./bootstrap/rollback.sh                    # Interactive: pick backup
#   sudo ./bootstrap/rollback.sh <timestamp>        # Restore specific backup
#   sudo ./bootstrap/rollback.sh --list             # List available backups
#   sudo ./bootstrap/rollback.sh --dry-run <ts>     # Show what would be restored
#
# IMPORTANT:
#   - This restores CONFIG FILES only, not Docker volumes or data.
#   - After rollback, you must manually restart affected services.
#   - Docker containers are NOT automatically recreated.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="rollback"
DRY_RUN="${DRY_RUN:-false}"

# ── Parse arguments ─────────────────────────────────────────────────────────
ACTION=""
TIMESTAMP=""
AUTO_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l)
      ACTION="list"
      shift
      ;;
    --dry-run|-n)
      DRY_RUN=true
      export DRY_RUN
      shift
      ;;
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --timestamp|-t)
      TIMESTAMP="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS] [TIMESTAMP]"
      echo ""
      echo "Options:"
      echo "  --list, -l            List available backups"
      echo "  --dry-run, -n         Show what would be restored"
      echo "  --auto                Non-interactive mode (for auto-rollback)"
      echo "  --timestamp, -t <ts>  Specify backup timestamp"
      echo "  --help, -h            Show this help message"
      echo ""
      echo "If no timestamp is given, an interactive picker is shown."
      exit 0
      ;;
    *)
      TIMESTAMP="$1"
      shift
      ;;
  esac
done

require_root

# ── List backups ─────────────────────────────────────────────────────────────
if [[ "$ACTION" == "list" ]]; then
  log_info "Available backups:"
  list_backups
  exit 0
fi

# ── Interactive picker ──────────────────────────────────────────────────────
if [[ -z "$TIMESTAMP" ]]; then
  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    log_fatal "No backups found in $BACKUP_DIR"
  fi

  echo "" >&2
  log_info "Available backups:"
  echo "" >&2

  local_backups=()
  while IFS= read -r dir; do
    local_backups+=("$dir")
  done < <(ls -1t "$BACKUP_DIR")

  for i in "${!local_backups[@]}"; do
    local bdir="${BACKUP_DIR}/${local_backups[$i]}"
    local file_count
    file_count="$(find "$bdir" -type f | wc -l)"
    printf '  [%d] %s (%d files)\n' "$((i + 1))" "${local_backups[$i]}" "$file_count" >&2
  done

  echo "" >&2
  read -rp "Select backup number (or 'q' to quit): " selection

  if [[ "$selection" == "q" ]]; then
    log_info "Aborted"
    exit 0
  fi

  local idx=$((selection - 1))
  if [[ $idx -lt 0 || $idx -ge ${#local_backups[@]} ]]; then
    log_fatal "Invalid selection: $selection"
  fi

  TIMESTAMP="${local_backups[$idx]}"
fi

# ── Perform rollback ────────────────────────────────────────────────────────
echo "" >&2
log_step "=========================================="
log_step "Rolling back to: $TIMESTAMP"
log_step "=========================================="
echo "" >&2

restore_backup "$TIMESTAMP"

echo "" >&2
if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry-run complete. No files were restored."
else
  log_info "Rollback complete."
  log_info ""
  log_info "You must now restart affected services:"
  log_info "  systemctl restart systemd-networkd"
  log_info "  systemctl restart nftables"
  log_info "  systemctl restart dnsmasq"
  log_info "  systemctl restart docker"
  log_info "  systemctl restart ssh"
  log_info ""
  log_info "And recreate Docker stacks if compose files changed:"
  log_info "  cd /opt/traefik && docker compose up -d"
  log_info "  cd /opt/gitea   && docker compose up -d"
  log_info "  cd /opt/whoami  && docker compose up -d"
fi
