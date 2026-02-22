#!/usr/bin/env bash
# =============================================================================
# backup-data.sh — Backup and restore application data
# =============================================================================
# Backs up Gitea data, PostgreSQL database, and Traefik certificates.
#
# Usage:
#   ./backup-data.sh            Create a new backup
#   ./backup-data.sh --restore  Restore from latest or selected backup
#   ./backup-data.sh --list     List available backups
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="backup-data"

# ── Configuration ───────────────────────────────────────────────────────────
BACKUP_DIR="/var/backups/vps-bootstrap"
BACKUP_RETENTION_DAYS=30
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${TIMESTAMP}"

# Docker data directories
GITEA_DATA="/opt/gitea/data"
POSTGRES_DATA="/opt/gitea/postgres"
TRAEFIK_DATA="/opt/traefik"

# Container names
POSTGRES_CONTAINER="postgres"
GITEA_CONTAINER="gitea"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Functions ───────────────────────────────────────────────────────────────

ensure_backup_dir() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"
    log_info "Created backup directory: $BACKUP_DIR"
  fi
}

list_backups() {
  echo ""
  echo -e "${BOLD}Available Backups${NC}"
  echo "─────────────────────────────────────────────────"
  
  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    echo "  No backups found."
    echo ""
    return 1
  fi
  
  local count=0
  for backup in "$BACKUP_DIR"/backup_*; do
    [[ -d "$backup" ]] || continue
    count=$((count + 1))
    
    local name
    name=$(basename "$backup")
    local timestamp
    timestamp=$(echo "$name" | sed 's/backup_//' | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
    local size
    size=$(du -sh "$backup" 2>/dev/null | cut -f1)
    
    # Check what's in the backup
    local components=""
    [[ -f "$backup/gitea_data.tar.gz" ]] && components+="gitea "
    [[ -f "$backup/postgres.sql.gz" ]] && components+="postgres "
    [[ -f "$backup/traefik_data.tar.gz" ]] && components+="traefik "
    
    echo -e "  ${GREEN}●${NC} ${name}"
    echo "      Size: $size | Components: ${components:-none}"
  done
  
  echo ""
  echo "  Total: $count backup(s)"
  echo ""
}

backup_postgres() {
  log_info "Backing up PostgreSQL database..."
  
  if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    log_warn "PostgreSQL container not running, skipping database backup"
    return 0
  fi
  
  local backup_file="$1/postgres.sql.gz"
  
  docker exec "$POSTGRES_CONTAINER" pg_dumpall -U gitea 2>/dev/null | gzip > "$backup_file"
  
  if [[ -f "$backup_file" ]] && [[ -s "$backup_file" ]]; then
    local size
    size=$(du -sh "$backup_file" | cut -f1)
    log_success "PostgreSQL backup complete: $size"
  else
    log_warn "PostgreSQL backup may be empty"
  fi
}

backup_gitea() {
  log_info "Backing up Gitea data..."
  
  if [[ ! -d "$GITEA_DATA" ]]; then
    log_warn "Gitea data directory not found: $GITEA_DATA"
    return 0
  fi
  
  local backup_file="$1/gitea_data.tar.gz"
  
  # Stop Gitea for consistent backup
  local gitea_was_running=false
  if docker ps --format '{{.Names}}' | grep -q "^${GITEA_CONTAINER}$"; then
    gitea_was_running=true
    log_info "Stopping Gitea for backup..."
    docker stop "$GITEA_CONTAINER" >/dev/null 2>&1 || true
    sleep 2
  fi
  
  tar -czf "$backup_file" -C "$(dirname "$GITEA_DATA")" "$(basename "$GITEA_DATA")" 2>/dev/null || true
  
  # Restart Gitea
  if [[ "$gitea_was_running" == "true" ]]; then
    log_info "Restarting Gitea..."
    docker start "$GITEA_CONTAINER" >/dev/null 2>&1 || true
  fi
  
  if [[ -f "$backup_file" ]] && [[ -s "$backup_file" ]]; then
    local size
    size=$(du -sh "$backup_file" | cut -f1)
    log_success "Gitea data backup complete: $size"
  else
    log_warn "Gitea backup may be empty"
  fi
}

backup_traefik() {
  log_info "Backing up Traefik data..."
  
  if [[ ! -d "$TRAEFIK_DATA" ]]; then
    log_warn "Traefik data directory not found: $TRAEFIK_DATA"
    return 0
  fi
  
  local backup_file="$1/traefik_data.tar.gz"
  
  tar -czf "$backup_file" -C "$(dirname "$TRAEFIK_DATA")" "$(basename "$TRAEFIK_DATA")" 2>/dev/null || true
  
  if [[ -f "$backup_file" ]] && [[ -s "$backup_file" ]]; then
    local size
    size=$(du -sh "$backup_file" | cut -f1)
    log_success "Traefik data backup complete: $size"
  else
    log_warn "Traefik backup may be empty"
  fi
}

create_backup() {
  ensure_backup_dir
  
  local backup_path="$BACKUP_DIR/$BACKUP_NAME"
  mkdir -p "$backup_path"
  
  echo ""
  echo -e "${BOLD}Creating Backup: ${BACKUP_NAME}${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  
  backup_postgres "$backup_path"
  backup_gitea "$backup_path"
  backup_traefik "$backup_path"
  
  # Create manifest
  cat > "$backup_path/manifest.json" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname)",
  "backup_name": "$BACKUP_NAME",
  "components": {
    "postgres": $([ -f "$backup_path/postgres.sql.gz" ] && echo "true" || echo "false"),
    "gitea": $([ -f "$backup_path/gitea_data.tar.gz" ] && echo "true" || echo "false"),
    "traefik": $([ -f "$backup_path/traefik_data.tar.gz" ] && echo "true" || echo "false")
  }
}
EOF
  
  # Calculate total size
  local total_size
  total_size=$(du -sh "$backup_path" | cut -f1)
  
  echo ""
  echo "─────────────────────────────────────────────────"
  log_success "Backup complete!"
  echo ""
  echo "  Location: $backup_path"
  echo "  Size:     $total_size"
  echo ""
  
  # Cleanup old backups
  cleanup_old_backups
}

cleanup_old_backups() {
  local count=0
  
  while IFS= read -r -d '' backup; do
    rm -rf "$backup"
    count=$((count + 1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup_*" -mtime +$BACKUP_RETENTION_DAYS -print0)
  
  if [[ $count -gt 0 ]]; then
    log_info "Cleaned up $count old backup(s) (older than ${BACKUP_RETENTION_DAYS} days)"
  fi
}

select_backup() {
  local backups=()
  
  for backup in "$BACKUP_DIR"/backup_*; do
    [[ -d "$backup" ]] && backups+=("$(basename "$backup")")
  done
  
  if [[ ${#backups[@]} -eq 0 ]]; then
    echo -e "${RED}✗${NC} No backups available"
    exit 1
  fi
  
  echo ""
  echo -e "${BOLD}Select Backup to Restore${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  
  local i=1
  for b in "${backups[@]}"; do
    local size
    size=$(du -sh "$BACKUP_DIR/$b" 2>/dev/null | cut -f1)
    echo "  $i) $b ($size)"
    i=$((i + 1))
  done
  echo ""
  
  local selection
  read -rp "Enter number [1-${#backups[@]}]: " selection
  
  if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backups[@]} ]]; then
    echo -e "${RED}✗${NC} Invalid selection"
    exit 1
  fi
  
  SELECTED_BACKUP="${backups[$((selection - 1))]}"
}

restore_postgres() {
  local backup_file="$1/postgres.sql.gz"
  
  if [[ ! -f "$backup_file" ]]; then
    log_warn "PostgreSQL backup not found, skipping"
    return 0
  fi
  
  log_info "Restoring PostgreSQL database..."
  
  if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    log_error "PostgreSQL container not running"
    return 1
  fi
  
  gunzip -c "$backup_file" | docker exec -i "$POSTGRES_CONTAINER" psql -U gitea >/dev/null 2>&1
  
  log_success "PostgreSQL restore complete"
}

restore_gitea() {
  local backup_file="$1/gitea_data.tar.gz"
  
  if [[ ! -f "$backup_file" ]]; then
    log_warn "Gitea backup not found, skipping"
    return 0
  fi
  
  log_info "Restoring Gitea data..."
  
  # Stop Gitea
  if docker ps --format '{{.Names}}' | grep -q "^${GITEA_CONTAINER}$"; then
    log_info "Stopping Gitea..."
    docker stop "$GITEA_CONTAINER" >/dev/null 2>&1 || true
    sleep 2
  fi
  
  # Backup current data before overwrite
  if [[ -d "$GITEA_DATA" ]]; then
    mv "$GITEA_DATA" "${GITEA_DATA}.pre-restore.$(date +%Y%m%d%H%M%S)"
  fi
  
  # Extract backup
  mkdir -p "$(dirname "$GITEA_DATA")"
  tar -xzf "$backup_file" -C "$(dirname "$GITEA_DATA")"
  
  # Fix permissions
  chown -R 1000:1000 "$GITEA_DATA" 2>/dev/null || true
  
  # Start Gitea
  log_info "Starting Gitea..."
  docker start "$GITEA_CONTAINER" >/dev/null 2>&1 || true
  
  log_success "Gitea restore complete"
}

restore_traefik() {
  local backup_file="$1/traefik_data.tar.gz"
  
  if [[ ! -f "$backup_file" ]]; then
    log_warn "Traefik backup not found, skipping"
    return 0
  fi
  
  log_info "Restoring Traefik data..."
  
  # Stop Traefik
  if docker ps --format '{{.Names}}' | grep -q "traefik"; then
    docker stop traefik >/dev/null 2>&1 || true
  fi
  
  # Backup current data
  if [[ -d "$TRAEFIK_DATA" ]]; then
    mv "$TRAEFIK_DATA" "${TRAEFIK_DATA}.pre-restore.$(date +%Y%m%d%H%M%S)"
  fi
  
  # Extract backup
  mkdir -p "$(dirname "$TRAEFIK_DATA")"
  tar -xzf "$backup_file" -C "$(dirname "$TRAEFIK_DATA")"
  
  # Start Traefik
  docker start traefik >/dev/null 2>&1 || true
  
  log_success "Traefik restore complete"
}

restore_backup() {
  if [[ -z "${SELECTED_BACKUP:-}" ]]; then
    select_backup
  fi
  
  local backup_path="$BACKUP_DIR/$SELECTED_BACKUP"
  
  echo ""
  echo -e "${BOLD}Restoring from: ${SELECTED_BACKUP}${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  echo -e "${YELLOW}⚠${NC}  This will overwrite current data!"
  echo ""
  
  read -rp "Are you sure? (yes/no): " confirm
  
  if [[ "$confirm" != "yes" ]]; then
    echo ""
    echo "Restore cancelled."
    exit 0
  fi
  
  echo ""
  
  restore_postgres "$backup_path"
  restore_gitea "$backup_path"
  restore_traefik "$backup_path"
  
  echo ""
  echo "─────────────────────────────────────────────────"
  log_success "Restore complete!"
  echo ""
  echo "  Restored from: $backup_path"
  echo ""
  echo "  Next steps:"
  echo "    - Check service status: make status"
  echo "    - Restart services if needed: docker restart gitea postgres"
  echo ""
}

show_help() {
  echo ""
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --list           List available backups"
  echo "  --restore        Restore from a backup"
  echo "  --restore=NAME   Restore from a specific backup"
  echo "  --help           Show this help"
  echo ""
  echo "Examples:"
  echo "  $0                     # Create a new backup"
  echo "  $0 --list              # List all backups"
  echo "  $0 --restore           # Interactive restore"
  echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  # Check root
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗${NC} This script must be run as root"
    exit 1
  fi
  
  case "${1:-}" in
    --list)
      list_backups
      ;;
    --restore)
      restore_backup
      ;;
    --restore=*)
      SELECTED_BACKUP="${1#--restore=}"
      restore_backup
      ;;
    --help|-h)
      show_help
      ;;
    "")
      create_backup
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
