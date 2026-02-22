#!/usr/bin/env bash
# =============================================================================
# modules/09-security.sh — Advanced Security Hardening
# =============================================================================
# Implements:
#   - Fail2ban with WireGuard protection
#   - Audit logging (auditd) for critical files
#   - Unattended security upgrades
#   - VPN health monitoring
#
# Security rationale:
#   - Fail2ban prevents brute-force attacks on WireGuard
#   - Auditd provides forensic logging for security events
#   - Unattended-upgrades ensures timely security patches
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="09-security"

# ── Required packages ───────────────────────────────────────────────────────
SECURITY_PACKAGES=(
  rsyslog           # Required for traditional log files (auth.log, kern.log)
  fail2ban
  auditd
  audispd-plugins
  unattended-upgrades
  apt-listchanges
)

install_security_packages() {
  log_step "Installing security packages"

  local to_install=()
  for pkg in "${SECURITY_PACKAGES[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      log_debug "Already installed: $pkg"
    else
      to_install+=("$pkg")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    log_info "All security packages already installed"
    return 0
  fi

  log_info "Installing ${#to_install[@]} package(s): ${to_install[*]}"
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq "${to_install[@]}"
  
  # Ensure rsyslog is running (required for fail2ban log files)
  if systemctl is-enabled rsyslog &>/dev/null; then
    log_info "rsyslog is enabled"
  else
    run_cmd systemctl enable rsyslog
  fi
  run_cmd systemctl start rsyslog || true
  
  # Wait for log files to be created
  sleep 2
}

# ── Fail2ban Configuration ──────────────────────────────────────────────────
configure_fail2ban() {
  log_step "Configuring Fail2ban"

  # Create WireGuard filter
  local wg_filter="/etc/fail2ban/filter.d/wireguard.conf"
  local wg_filter_content
  wg_filter_content="$(cat <<'FILTER'
# =============================================================================
# wireguard.conf — Fail2ban filter for WireGuard handshake floods
# =============================================================================
# Detects excessive invalid handshake attempts logged by the kernel.
# WireGuard itself is cryptographically secure, but rate-limiting prevents
# resource exhaustion from handshake flood attacks.

[Definition]
# Match kernel logs for WireGuard invalid handshake messages
# Example: wireguard: wg0: Invalid handshake initiation from 1.2.3.4:51820
failregex = ^.*wireguard: wg0: Invalid handshake initiation from <HOST>:\d+$
            ^.*wireguard: wg0: Invalid MAC of handshake from <HOST>:\d+$

ignoreregex =

# Date pattern for kernel logs
datepattern = ^%%b %%d %%H:%%M:%%S
              {^LN-BEG}
FILTER
)"

  if file_matches "$wg_filter" "$wg_filter_content"; then
    log_info "WireGuard filter already configured"
  else
    install_content "$wg_filter_content" "$wg_filter" "0644"
    log_info "✅ WireGuard filter installed"
  fi

  # Create Fail2ban jail configuration
  local jail_local="/etc/fail2ban/jail.local"
  local jail_content
  jail_content="$(cat <<'JAIL'
# =============================================================================
# jail.local — Fail2ban jail configuration
# =============================================================================
# Custom jails for WireGuard protection and SSH hardening.
# SSH jail is configured even though SSH is VPN-only (defense in depth).

[DEFAULT]
# Ban duration: 1 hour
bantime = 1h
# Detection window: 10 minutes
findtime = 10m
# Max retries before ban
maxretry = 5
# Use nftables for banning
banaction = nftables-multiport
banaction_allports = nftables-allports

# Ignore VPN subnet (trusted)
ignoreip = 127.0.0.1/8 ::1 10.100.0.0/24

# ── WireGuard Protection ────────────────────────────────────────────────────
[wireguard]
enabled = true
filter = wireguard
port = 51820
protocol = udp
logpath = /var/log/kern.log
maxretry = 10
findtime = 1m
bantime = 24h
# More aggressive: 10 invalid handshakes in 1 minute = 24h ban

# ── SSH Protection (VPN-only, but defense in depth) ─────────────────────────
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 10m
bantime = 1h

# ── SSH aggressive mode ─────────────────────────────────────────────────────
[sshd-aggressive]
enabled = true
port = ssh
filter = sshd[mode=aggressive]
logpath = /var/log/auth.log
maxretry = 3
findtime = 1d
bantime = 1w
JAIL
)"

  if file_matches "$jail_local" "$jail_content"; then
    log_info "Fail2ban jail already configured"
  else
    install_content "$jail_content" "$jail_local" "0644"
    log_info "✅ Fail2ban jail configured"
  fi

  # Enable and start fail2ban
  if [[ "$DRY_RUN" != "true" ]]; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    log_info "✅ Fail2ban enabled and started"
  fi
}

# ── Audit Logging Configuration ─────────────────────────────────────────────
configure_auditd() {
  log_step "Configuring Audit Logging (auditd)"

  local audit_rules="/etc/audit/rules.d/99-vps-bootstrap.rules"
  local audit_content
  audit_content="$(cat <<'AUDIT'
# =============================================================================
# 99-vps-bootstrap.rules — Audit rules for security monitoring
# =============================================================================
# These rules log security-relevant events for forensic analysis.
# View logs with: ausearch -k <key> | aureport -i

# ── Delete all existing rules (clean slate) ─────────────────────────────────
-D

# ── Buffer size ─────────────────────────────────────────────────────────────
-b 8192

# ── Failure mode: 1 = printk, 2 = panic ─────────────────────────────────────
-f 1

# ── SSH Configuration Changes ───────────────────────────────────────────────
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# ── Firewall Changes ────────────────────────────────────────────────────────
-w /etc/nftables.conf -p wa -k firewall
-w /etc/nftables.d/ -p wa -k firewall

# ── WireGuard Configuration ─────────────────────────────────────────────────
-w /etc/wireguard/ -p wa -k wireguard
-w /etc/systemd/network/99-wg0.netdev -p wa -k wireguard
-w /etc/systemd/network/99-wg0.network -p wa -k wireguard

# ── User/Group Changes ──────────────────────────────────────────────────────
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

# ── SSH Authorized Keys ─────────────────────────────────────────────────────
-w /root/.ssh/ -p wa -k ssh_keys
-w /home/ -p wa -k ssh_keys

# ── Docker Configuration ────────────────────────────────────────────────────
-w /etc/docker/daemon.json -p wa -k docker
-w /opt/traefik/ -p wa -k docker
-w /opt/gitea/ -p wa -k docker

# ── Boot/Startup Scripts ────────────────────────────────────────────────────
-w /etc/systemd/system/ -p wa -k systemd
-w /etc/cron.d/ -p wa -k cron
-w /etc/crontab -p wa -k cron

# ── Privilege Escalation ────────────────────────────────────────────────────
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k privilege_escalation

# ── Make rules immutable (requires reboot to change) ────────────────────────
# Uncomment for production:
# -e 2
AUDIT
)"

  if file_matches "$audit_rules" "$audit_content"; then
    log_info "Audit rules already configured"
  else
    install_content "$audit_content" "$audit_rules" "0640"
    log_info "✅ Audit rules installed"
  fi

  # Enable and restart auditd
  if [[ "$DRY_RUN" != "true" ]]; then
    systemctl enable auditd >/dev/null 2>&1 || true
    # auditd doesn't like restart, use reload
    augenrules --load >/dev/null 2>&1 || true
    log_info "✅ Auditd enabled and rules loaded"
  fi
}

# ── Unattended Upgrades Configuration ───────────────────────────────────────
configure_unattended_upgrades() {
  log_step "Configuring Unattended Security Upgrades"

  # Main configuration
  local apt_conf="/etc/apt/apt.conf.d/50unattended-upgrades"
  local apt_content
  apt_content="$(cat <<'APTCONF'
// =============================================================================
// 50unattended-upgrades — Automatic security updates
// =============================================================================
// Automatically installs security updates. Critical for VPS security.

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "Docker:${distro_codename}";
};

// Packages to never upgrade automatically
Unattended-Upgrade::Package-Blacklist {
    // Add packages here that should not be auto-upgraded
};

// Automatically reboot if required (at 3 AM)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Only reboot if no users are logged in
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Remove unused kernel packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Enable logging
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";

// Mail notifications (optional - configure if needed)
// Unattended-Upgrade::Mail "admin@example.com";
// Unattended-Upgrade::MailReport "on-change";
APTCONF
)"

  if file_matches "$apt_conf" "$apt_content"; then
    log_info "Unattended-upgrades already configured"
  else
    install_content "$apt_content" "$apt_conf" "0644"
    log_info "✅ Unattended-upgrades configured"
  fi

  # Enable automatic updates
  local auto_upgrades="/etc/apt/apt.conf.d/20auto-upgrades"
  local auto_content
  auto_content="$(cat <<'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTO
)"

  if file_matches "$auto_upgrades" "$auto_content"; then
    log_info "Auto-upgrades already enabled"
  else
    install_content "$auto_content" "$auto_upgrades" "0644"
    log_info "✅ Auto-upgrades enabled"
  fi

  # Enable the service
  if [[ "$DRY_RUN" != "true" ]]; then
    systemctl enable unattended-upgrades >/dev/null 2>&1 || true
    systemctl start unattended-upgrades >/dev/null 2>&1 || true
    log_info "✅ Unattended-upgrades service enabled"
  fi
}

# ── VPN Health Check Service ────────────────────────────────────────────────
configure_vpn_health_check() {
  log_step "Configuring VPN Health Check"

  # Health check script
  local health_script="/usr/local/bin/vpn-health-check.sh"
  local health_content
  health_content="$(cat <<'HEALTH'
#!/usr/bin/env bash
# =============================================================================
# vpn-health-check.sh — Monitor WireGuard VPN health
# =============================================================================
# Checks if wg0 is up and functional. Logs warnings and can restart if needed.
# Run periodically via systemd timer.

set -euo pipefail

LOG_TAG="vpn-health"
WG_INTERFACE="wg0"
VPN_IP="10.100.0.1"

log() {
  logger -t "$LOG_TAG" -p daemon.info "$1"
}

log_warn() {
  logger -t "$LOG_TAG" -p daemon.warning "$1"
}

log_error() {
  logger -t "$LOG_TAG" -p daemon.err "$1"
}

# Check if interface exists
if ! ip link show "$WG_INTERFACE" &>/dev/null; then
  log_error "CRITICAL: $WG_INTERFACE interface does not exist!"
  
  # Try to bring it up
  log_warn "Attempting to restart systemd-networkd..."
  systemctl restart systemd-networkd
  sleep 5
  
  if ip link show "$WG_INTERFACE" &>/dev/null; then
    log "Recovery successful: $WG_INTERFACE is now up"
  else
    log_error "Recovery FAILED: $WG_INTERFACE still down after restart"
    exit 1
  fi
fi

# Check if interface is UP
if ! ip link show "$WG_INTERFACE" | grep -q "UP"; then
  log_error "CRITICAL: $WG_INTERFACE exists but is not UP!"
  exit 1
fi

# Check if IP is assigned
if ! ip addr show "$WG_INTERFACE" | grep -q "$VPN_IP"; then
  log_error "CRITICAL: $WG_INTERFACE does not have IP $VPN_IP!"
  exit 1
fi

# Check if WireGuard has a peer configured
if ! wg show "$WG_INTERFACE" 2>/dev/null | grep -q "peer"; then
  log_warn "WARNING: No peers configured on $WG_INTERFACE"
fi

# Check last handshake (if peer exists)
LAST_HANDSHAKE=$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
if [[ -n "$LAST_HANDSHAKE" && "$LAST_HANDSHAKE" != "0" ]]; then
  NOW=$(date +%s)
  AGE=$((NOW - LAST_HANDSHAKE))
  
  # Warn if no handshake in last 5 minutes (300 seconds)
  if [[ $AGE -gt 300 ]]; then
    log_warn "WARNING: Last handshake was $AGE seconds ago"
  fi
fi

log "Health check passed: $WG_INTERFACE is UP with $VPN_IP"
exit 0
HEALTH
)"

  if file_matches "$health_script" "$health_content"; then
    log_info "Health check script already installed"
  else
    install_content "$health_content" "$health_script" "0755"
    log_info "✅ Health check script installed"
  fi

  # Systemd service
  local health_service="/etc/systemd/system/vpn-health-check.service"
  local service_content
  service_content="$(cat <<'SERVICE'
[Unit]
Description=VPN Health Check
After=network-online.target systemd-networkd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-health-check.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE
)"

  if file_matches "$health_service" "$service_content"; then
    log_info "Health check service already configured"
  else
    install_content "$service_content" "$health_service" "0644"
  fi

  # Systemd timer (runs every 5 minutes)
  local health_timer="/etc/systemd/system/vpn-health-check.timer"
  local timer_content
  timer_content="$(cat <<'TIMER'
[Unit]
Description=VPN Health Check Timer
Requires=vpn-health-check.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMER
)"

  if file_matches "$health_timer" "$timer_content"; then
    log_info "Health check timer already configured"
  else
    install_content "$timer_content" "$health_timer" "0644"
  fi

  # Enable timer
  if [[ "$DRY_RUN" != "true" ]]; then
    systemctl daemon-reload
    systemctl enable vpn-health-check.timer >/dev/null 2>&1 || true
    systemctl start vpn-health-check.timer >/dev/null 2>&1 || true
    log_info "✅ VPN health check timer enabled (runs every 5 minutes)"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  log_step "=========================================="
  log_step "Starting module: $BOOTSTRAP_MODULE"
  log_step "=========================================="

  install_security_packages
  configure_fail2ban
  configure_auditd
  configure_unattended_upgrades
  configure_vpn_health_check

  log_info "🎉 Security hardening complete"
}

main "$@"
