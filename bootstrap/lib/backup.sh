#!/usr/bin/env bash
# =============================================================================
# lib/backup.sh — Config backup and restore utilities
# =============================================================================
# Creates timestamped backups before modifying system files.
# Supports atomic file placement via temp + mv.
# =============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/bootstrap}"
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-$(date -u '+%Y%m%d_%H%M%S')}"

# Ensure backup directory exists
ensure_backup_dir() {
  mkdir -p "${BACKUP_DIR}/${BACKUP_TIMESTAMP}"
}

# Back up a file before modifying it
# Usage: backup_file /etc/nftables.conf
backup_file() {
  local src="$1"
  if [[ ! -f "$src" ]]; then
    log_debug "No existing file to back up: $src"
    return 0
  fi
  ensure_backup_dir
  local dest="${BACKUP_DIR}/${BACKUP_TIMESTAMP}/${src//\//__}"
  cp -a "$src" "$dest"
  log_info "Backed up $src → $dest"
}

# Install a file atomically: write to temp, then mv
# Usage: install_file <source> <destination> <mode> [owner]
install_file() {
  local src="$1" dest="$2" mode="$3" owner="${4:-root:root}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install $src → $dest (mode=$mode, owner=$owner)"
    return 0
  fi

  # Back up existing file if present
  backup_file "$dest"

  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"

  local tmpfile
  tmpfile="$(mktemp "${dest}.XXXXXX")"
  cp "$src" "$tmpfile"
  chmod "$mode" "$tmpfile"
  chown "$owner" "$tmpfile"
  mv -f "$tmpfile" "$dest"
  log_info "Installed $dest (mode=$mode, owner=$owner)"
}

# Install file content from stdin or a variable
# Usage: install_content "content" <destination> <mode> [owner]
install_content() {
  local content="$1" dest="$2" mode="$3" owner="${4:-root:root}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would write $dest (mode=$mode, owner=$owner)"
    return 0
  fi

  backup_file "$dest"

  local dest_dir
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"

  local tmpfile
  tmpfile="$(mktemp "${dest}.XXXXXX")"
  printf '%s\n' "$content" > "$tmpfile"
  chmod "$mode" "$tmpfile"
  chown "$owner" "$tmpfile"
  mv -f "$tmpfile" "$dest"
  log_info "Wrote $dest (mode=$mode, owner=$owner)"
}

# Compare file to expected content; return 0 if identical
# Usage: file_matches <file> <expected_content>
file_matches() {
  local file="$1" expected="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local current
  current="$(cat "$file")"
  [[ "$current" == "$expected" ]]
}

# List all backups
list_backups() {
  if [[ -d "$BACKUP_DIR" ]]; then
    ls -1t "$BACKUP_DIR"
  else
    echo "(no backups)"
  fi
}

# Restore from a specific backup timestamp
# Usage: restore_backup <timestamp>
restore_backup() {
  local ts="$1"
  local bdir="${BACKUP_DIR}/${ts}"
  if [[ ! -d "$bdir" ]]; then
    log_fatal "Backup directory not found: $bdir"
  fi

  log_warn "Restoring from backup: $ts"
  for bfile in "$bdir"/*; do
    local original
    original="$(basename "$bfile" | sed 's/__/\//g')"
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "Would restore $original from $bfile"
    else
      cp -a "$bfile" "$original"
      log_info "Restored $original"
    fi
  done
}
