#!/usr/bin/env bash
# =============================================================================
# lib/logging.sh — Structured logging with severity levels
# =============================================================================
# Provides consistent, timestamped log output for all bootstrap modules.
# Supports dry-run mode indication and module context.
# =============================================================================

set -euo pipefail

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  readonly _CLR_RED='\033[0;31m'
  readonly _CLR_YEL='\033[0;33m'
  readonly _CLR_GRN='\033[0;32m'
  readonly _CLR_BLU='\033[0;34m'
  readonly _CLR_CYN='\033[0;36m'
  readonly _CLR_RST='\033[0m'
else
  readonly _CLR_RED='' _CLR_YEL='' _CLR_GRN='' _CLR_BLU='' _CLR_CYN='' _CLR_RST=''
fi

# Current module context (set by each module)
BOOTSTRAP_MODULE="${BOOTSTRAP_MODULE:-bootstrap}"

# Dry-run mode flag (set by apply.sh or module)
DRY_RUN="${DRY_RUN:-false}"

_log() {
  local level="$1" color="$2" msg="$3"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local prefix=""
  [[ "$DRY_RUN" == "true" ]] && prefix="[DRY-RUN] "
  printf '%b[%s] [%-5s] [%s] %s%s%b\n' \
    "$color" "$ts" "$level" "$BOOTSTRAP_MODULE" "$prefix" "$msg" "$_CLR_RST" >&2
}

log_info()  { _log "INFO"  "$_CLR_GRN" "$*"; }
log_warn()  { _log "WARN"  "$_CLR_YEL" "$*"; }
log_error() { _log "ERROR" "$_CLR_RED" "$*"; }
log_debug() { _log "DEBUG" "$_CLR_BLU" "$*"; }
log_step()  { _log "STEP"  "$_CLR_CYN" "$*"; }

log_fatal() {
  _log "FATAL" "$_CLR_RED" "$*"
  exit 1
}

# Run a command, or print it if dry-run
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would run: $*"
    return 0
  fi
  log_debug "Running: $*"
  "$@"
}

# Check if running as root
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_fatal "This script must be run as root (current UID=$EUID)"
  fi
}

# Banner for module start
module_start() {
  local name="$1"
  BOOTSTRAP_MODULE="$name"
  echo "" >&2
  log_step "=========================================="
  log_step "Starting module: $name"
  log_step "=========================================="
}

# Banner for module completion
module_done() {
  local name="${1:-$BOOTSTRAP_MODULE}"
  log_step "Module $name completed successfully"
}

# Return the SSH client IP (first word of $SSH_CLIENT), or empty string
get_ssh_client_ip() {
  local ip="${SSH_CLIENT:-}"
  printf '%s' "${ip%% *}"
}
