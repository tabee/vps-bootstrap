#!/usr/bin/env bash
# =============================================================================
# user-lockdown.sh — Create admin user and disable root SSH login
# =============================================================================
# This script:
#   1. Creates a new admin user with sudo privileges
#   2. Copies root's SSH authorized_keys to the new user
#   3. Disables root SSH login
#   4. Validates the new user can sudo before finalizing
#
# Run with: make user-lockdown
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# ── Safety checks ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

# Check we're connected via VPN (not WAN)
if [[ -n "${SSH_CLIENT:-}" ]]; then
  local_ip="$(echo "$SSH_CLIENT" | awk '{print $1}')"
  if [[ ! "$local_ip" =~ ^10\.100\.0\. ]]; then
    log_error "Safety check failed: You must be connected via VPN (10.100.0.x)"
    log_error "Current connection from: $local_ip"
    log_error "Connect via: ssh root@10.100.0.1"
    exit 1
  fi
fi

# ── Get username ─────────────────────────────────────────────────────────────
log_step "User Lockdown — Create admin user and disable root SSH"
echo ""

read -rp "Enter username for new admin user: " NEW_USER

# Validate username
if [[ -z "$NEW_USER" ]]; then
  log_error "Username cannot be empty"
  exit 1
fi

if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  log_error "Invalid username. Use lowercase letters, numbers, underscore, dash."
  exit 1
fi

if [[ "$NEW_USER" == "root" ]]; then
  log_error "Cannot use 'root' as username"
  exit 1
fi

# ── Check if user already exists ─────────────────────────────────────────────
if id "$NEW_USER" &>/dev/null; then
  log_warn "User '$NEW_USER' already exists"
  read -rp "Continue with existing user? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Aborted"
    exit 0
  fi
else
  # Create user
  log_step "Creating user '$NEW_USER'..."
  useradd -m -s /bin/bash -G sudo "$NEW_USER"
  log_info "✅ User '$NEW_USER' created with sudo privileges"
fi

# ── Setup SSH key ────────────────────────────────────────────────────────────
log_step "Setting up SSH key for '$NEW_USER'..."

USER_HOME="/home/${NEW_USER}"
USER_SSH_DIR="${USER_HOME}/.ssh"
USER_AUTH_KEYS="${USER_SSH_DIR}/authorized_keys"

mkdir -p "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"

# Copy root's authorized_keys
if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys "$USER_AUTH_KEYS"
  chmod 600 "$USER_AUTH_KEYS"
  chown -R "${NEW_USER}:${NEW_USER}" "$USER_SSH_DIR"
  log_info "✅ SSH authorized_keys copied from root"
else
  log_error "No /root/.ssh/authorized_keys found!"
  log_error "You need to add an SSH key for the new user manually."
  exit 1
fi

# ── Verify sudo works ────────────────────────────────────────────────────────
log_step "Verifying sudo works for '$NEW_USER'..."

# Enable passwordless sudo temporarily for verification
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${NEW_USER}-temp"
chmod 440 "/etc/sudoers.d/99-${NEW_USER}-temp"

if sudo -u "$NEW_USER" sudo -n true 2>/dev/null; then
  log_info "✅ User '$NEW_USER' can use sudo"
else
  log_error "Sudo verification failed!"
  rm -f "/etc/sudoers.d/99-${NEW_USER}-temp"
  exit 1
fi

# ── Ask about passwordless sudo ──────────────────────────────────────────────
echo ""
log_warn "Security decision: Passwordless sudo"
echo "  Option 1: Keep passwordless sudo (convenient but less secure)"
echo "  Option 2: Require password for sudo (more secure)"
echo ""
read -rp "Keep passwordless sudo? [y/N]: " keep_nopasswd

if [[ "$keep_nopasswd" =~ ^[Yy]$ ]]; then
  # Rename temp file to permanent
  mv "/etc/sudoers.d/99-${NEW_USER}-temp" "/etc/sudoers.d/99-${NEW_USER}"
  log_info "✅ Passwordless sudo enabled for '$NEW_USER'"
else
  # Remove temp file, user will need password
  rm -f "/etc/sudoers.d/99-${NEW_USER}-temp"
  
  # Set a password for the user
  log_step "Setting password for '$NEW_USER'..."
  echo ""
  passwd "$NEW_USER"
  log_info "✅ Password set. User will need password for sudo."
fi

# ── Test SSH login before disabling root ─────────────────────────────────────
echo ""
log_warn "════════════════════════════════════════════════════════════════"
log_warn "CRITICAL: Before disabling root SSH, verify you can login as '$NEW_USER'"
log_warn "════════════════════════════════════════════════════════════════"
echo ""
echo "  In a NEW terminal, test:"
echo "    ssh ${NEW_USER}@10.100.0.1"
echo "    sudo whoami   # should print 'root'"
echo ""
read -rp "Have you verified SSH login works for '$NEW_USER'? [y/N]: " verified

if [[ ! "$verified" =~ ^[Yy]$ ]]; then
  log_warn "Aborted. Root SSH login remains enabled."
  log_info "Run 'make user-lockdown' again after verifying SSH access."
  exit 0
fi

# ── Disable root SSH login ───────────────────────────────────────────────────
log_step "Disabling root SSH login..."

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SSHD="${SSHD_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"

cp "$SSHD_CONFIG" "$BACKUP_SSHD"
log_info "Backup: $BACKUP_SSHD"

# Update sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

# Also add AllowUsers directive if not present
if ! grep -q "^AllowUsers" "$SSHD_CONFIG"; then
  echo "" >> "$SSHD_CONFIG"
  echo "# User lockdown - only allow specific user" >> "$SSHD_CONFIG"
  echo "AllowUsers ${NEW_USER}" >> "$SSHD_CONFIG"
else
  # Update existing AllowUsers
  sed -i "s/^AllowUsers.*/AllowUsers ${NEW_USER}/" "$SSHD_CONFIG"
fi

# Validate sshd config
if sshd -t; then
  log_info "✅ SSHD config valid"
else
  log_error "SSHD config invalid! Restoring backup..."
  cp "$BACKUP_SSHD" "$SSHD_CONFIG"
  exit 1
fi

# Reload sshd
systemctl reload sshd
log_info "✅ SSHD reloaded"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
log_step "════════════════════════════════════════════════════════════════"
log_info "🎉 User lockdown complete!"
log_step "════════════════════════════════════════════════════════════════"
echo ""
echo "  ✅ User:           $NEW_USER"
echo "  ✅ SSH access:     ssh ${NEW_USER}@10.100.0.1"
echo "  ✅ Root login:     DISABLED"
echo "  ✅ Sudo:           $(if [[ -f /etc/sudoers.d/99-${NEW_USER} ]]; then echo 'passwordless'; else echo 'requires password'; fi)"
echo ""
echo "  To become root:    sudo -i"
echo "  To run commands:   sudo <command>"
echo ""
log_warn "Your current root session will remain active."
log_warn "New root SSH connections are now blocked."
echo ""
