#!/usr/bin/env bash
# =============================================================================
# core/02-wireguard.sh — systemd-networkd + WireGuard configuration
# =============================================================================
# Configures:
#   - eth0 via DHCP (Hetzner Cloud)
#   - wg0 WireGuard tunnel (10.100.0.1/24, port 51820)
#   - Disables legacy networking and wg-quick
#
# Security rationale:
#   - WireGuard is the preferred way to reach internal services
#   - eth0 exposes UDP/51820 and SSH (during bootstrap) per nftables
#   - systemd-networkd manages WireGuard natively (no wg-quick race conditions)
#   - Private key file has 0600 permissions, owned by root
#
# Reliability:
#   - WireGuard module is loaded explicitly before networkd restart
#   - A systemd service ensures wg0 comes up on boot
#   - If wg0 fails, SSH remains accessible via WAN (bootstrap mode)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="wireguard"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

VPN_DOMAIN="${VPN_DOMAIN:-example.com}"

# ── Generate or load WireGuard server keys ───────────────────────────────────
# Keys are generated on the server if not provided (more secure: never leave server)
generate_server_keys() {
  log_step "Generating/loading WireGuard server keys"
  
  local keydir="/etc/wireguard"
  local privkey="$keydir/private.key"
  local pubkey="$keydir/public.key"
  
  mkdir -p "$keydir"
  chmod 0700 "$keydir"
  
  # Generate keys if not exist
  if [[ ! -f "$privkey" ]]; then
    log_info "Generating new WireGuard server keypair..."
    wg genkey > "$privkey"
    chmod 0600 "$privkey"
  fi
  
  if [[ ! -f "$pubkey" ]]; then
    wg pubkey < "$privkey" > "$pubkey"
  fi
  
  # Export for use in other functions
  WG_PRIVATE_KEY="$(cat "$privkey")"
  WG_PUBLIC_KEY="$(cat "$pubkey")"
  
  log_info "Server public key: ${WG_PUBLIC_KEY}"
}

# ── Disable legacy networking ───────────────────────────────────────────────
# IMPORTANT: This is called AFTER systemd-networkd is already running!
# We only disable (not stop) to prevent network interruption.
disable_legacy_networking() {
  log_step "Disabling legacy networking services (networkd already active)"

  # Disable ifupdown networking - do NOT use --now, networkd is handling it
  if systemctl is-enabled --quiet networking.service 2>/dev/null; then
    # Just disable for next boot, don't stop now (networkd took over)
    systemctl disable networking.service 2>/dev/null || true
    log_info "Disabled networking.service (will not start on next boot)"
  else
    log_debug "networking.service already disabled"
  fi

  # Disable wg-quick if enabled (we use systemd-networkd for WireGuard)
  if systemctl is-enabled --quiet 'wg-quick@wg0.service' 2>/dev/null; then
    systemctl disable 'wg-quick@wg0.service' 2>/dev/null || true
    log_info "Disabled wg-quick@wg0.service"
  else
    log_debug "wg-quick@wg0 already disabled"
  fi
}

# ── Install WireGuard private key ────────────────────────────────────────────
# This function is now a no-op since generate_server_keys handles everything
install_wireguard_key() {
  log_step "Installing WireGuard private key"
  
  # Keys are already generated/loaded by generate_server_keys()
  if [[ -z "${WG_PRIVATE_KEY:-}" ]]; then
    log_fatal "WG_PRIVATE_KEY not set — generate_server_keys() must be called first"
  fi
  
  log_info "WireGuard private key installed"
}

# ── Configure eth0 (WAN) ────────────────────────────────────────────────────
configure_wan() {
  log_step "Configuring eth0 (WAN) via systemd-networkd"

  local netfile="/etc/systemd/network/10-wan.network"

  # Hetzner Cloud uses DHCP with MAC-based client identifier.
  # DNS set to privacy-respecting resolvers (AdGuard + Cloudflare).
  local content
  content="$(cat <<'NET'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6PrivacyExtensions=false
DNS=94.140.14.14 1.1.1.1

[DHCPv4]
ClientIdentifier=mac
NET
)"

  if file_matches "$netfile" "$content"; then
    log_info "eth0 network config already up to date"
    return 0
  fi

  install_content "$content" "$netfile" "0644" "root:root"
}

# ── Configure WireGuard netdev ───────────────────────────────────────────────
configure_wg_netdev() {
  log_step "Configuring WireGuard netdev (wg0)"

  local netdev="/etc/systemd/network/99-wg0.netdev"

  if [[ -z "${WG_PRIVATE_KEY:-}" ]]; then
    log_fatal "WG_PRIVATE_KEY not set — generate_server_keys() must be called first"
  fi

  # systemd-networkd creates the WireGuard interface and manages its lifecycle.
  # IMPORTANT: We embed PrivateKey directly instead of using PrivateKeyFile=
  # because systemd-networkd on Debian runs as user systemd-network and cannot
  # read 0600 root:root files. The .netdev file itself is 0640 root:systemd-network.
  # ListenPort 51820 is the ONLY port exposed on WAN (enforced by nftables).
  # NOTE: No peers here - vpn-client.sh adds them after bootstrap
  local content
  content="$(cat <<NETDEV
[NetDev]
Name=wg0
Kind=wireguard

[WireGuard]
ListenPort=51820
PrivateKey=${WG_PRIVATE_KEY}
NETDEV
)"

  # Only write if netdev doesn't exist (preserve existing peers added by vpn-client.sh)
  if [[ -f "$netdev" ]]; then
    log_info "WireGuard netdev already exists, preserving peer configuration"
    # Ensure permissions are correct
    chmod 0640 "$netdev" 2>/dev/null || true
    chown root:systemd-network "$netdev" 2>/dev/null || true
    return 0
  fi

  # Write the netdev file with permissions readable by systemd-network group
  # 0640 root:systemd-network allows systemd-networkd to read it
  install_content "$content" "$netdev" "0640" "root:systemd-network"
}

# ── Configure WireGuard network ──────────────────────────────────────────────
configure_wg_network() {
  log_step "Configuring WireGuard network (wg0)"

  local netfile="/etc/systemd/network/99-wg0.network"

  # Address: server side of VPN tunnel
  # IPForward=yes: allow routing through this interface (VPN → Docker)
  # DNS=10.100.0.1: point VPN clients to local dnsmasq
  # Domains=~<domain>: route *.<domain> DNS queries to local resolver
  local content
  content="$(cat <<NET
[Match]
Name=wg0

[Network]
Address=10.100.0.1/24
IPForward=yes
DNS=10.100.0.1
Domains=~${VPN_DOMAIN}
NET
)"

  if file_matches "$netfile" "$content"; then
    log_info "WireGuard network config already up to date"
    return 0
  fi

  install_content "$content" "$netfile" "0644" "root:root"
}

# ── Enable and start systemd-networkd ────────────────────────────────────────
enable_networkd() {
  log_step "Enabling systemd-networkd"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would enable and restart systemd-networkd"
    return 0
  fi

  # ── Ensure temporary DNS during transition ────────────────────────────────
  # This prevents DNS failures while networkd takes over
  log_info "Setting up temporary DNS for transition..."
  if [[ ! -L /etc/resolv.conf ]]; then
    # Not a symlink, we can safely add fallback DNS
    if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
      cp /etc/resolv.conf /etc/resolv.conf.bak.$$ 2>/dev/null || true
      {
        echo "# Temporary DNS during network transition"
        echo "nameserver 1.1.1.1"
        echo "nameserver 8.8.8.8"
      } > /etc/resolv.conf
      log_info "Set temporary DNS in /etc/resolv.conf"
    fi
  fi

  # ── Load WireGuard kernel module ──────────────────────────────────────────
  # CRITICAL: systemd-networkd cannot create wg0 without the module loaded.
  # On minimal Debian installs the module may not auto-load.
  log_info "Loading WireGuard kernel module..."
  if ! lsmod | grep -q '^wireguard'; then
    modprobe wireguard || {
      log_error "Failed to load wireguard kernel module"
      log_error "Check: dmesg | grep -i wireguard"
      log_error "The kernel may need wireguard-dkms or a newer kernel"
    }
  fi
  
  # Verify module is loaded
  if lsmod | grep -q '^wireguard'; then
    log_info "✅ WireGuard kernel module loaded"
  else
    log_warn "⚠️  WireGuard module not loaded — wg0 will not work"
  fi

  # ── Ensure wireguard module loads on boot ─────────────────────────────────
  if [[ ! -f /etc/modules-load.d/wireguard.conf ]]; then
    echo "wireguard" > /etc/modules-load.d/wireguard.conf
    log_info "Added wireguard to /etc/modules-load.d/"
  fi

  systemctl enable systemd-networkd.service
  systemctl enable systemd-networkd-wait-online.service

  # Restart to pick up new configs
  # WARNING: This will momentarily drop network on a remote system.
  # On initial bootstrap this is expected; on re-runs it's idempotent.
  systemctl restart systemd-networkd.service

  # Give networkd a moment to configure interfaces
  sleep 3

  # ── Wait for eth0 (WAN) to come online first ─────────────────────────────
  # This is critical: without eth0 DHCP we lose DNS and apt breaks.
  log_info "Waiting for eth0 to get DHCP address..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if ip addr show eth0 2>/dev/null | grep -q 'inet '; then
      log_info "✅ eth0 has an IP address"
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [[ $i -ge 60 ]]; then
    log_fatal "eth0 did not get DHCP address within 60s — network broken, aborting"
  fi

  # ── Test basic IP connectivity ────────────────────────────────────────────
  log_info "Testing IP connectivity..."
  if ping -c1 -W3 1.1.1.1 &>/dev/null; then
    log_info "✅ IP connectivity working (can reach 1.1.1.1)"
  else
    log_warn "⚠️  Cannot ping 1.1.1.1 — network may have issues"
  fi

  # ── Verify DNS (warn only, dns module will fix it) ────────────────────────
  log_info "Checking DNS resolution..."
  local dns_ok=false
  for attempt in 1 2 3; do
    if host -W 3 deb.debian.org 1.1.1.1 &>/dev/null; then
      dns_ok=true
      break
    fi
    if getent hosts deb.debian.org &>/dev/null; then
      dns_ok=true
      break
    fi
    sleep 2
  done
  if [[ "$dns_ok" == "true" ]]; then
    log_info "✅ DNS resolution working"
  else
    # NOT fatal — the dns module will configure dnsmasq/resolved properly
    log_warn "⚠️  DNS resolution not working yet — will be configured in dns module"
  fi

  # ── Create wg0 interface manually if networkd didn't create it ────────────
  # systemd-networkd should create wg0 from the .netdev file, but sometimes
  # it doesn't work reliably. We try multiple approaches.
  if ! ip link show wg0 &>/dev/null; then
    log_info "wg0 not created by networkd, trying manual creation..."
    
    # Try networkctl reconfigure first
    networkctl reconfigure wg0 2>/dev/null || true
    sleep 2
    
    if ! ip link show wg0 &>/dev/null; then
      # Manual fallback: create the interface ourselves
      log_info "Creating wg0 interface manually..."
      ip link add wg0 type wireguard 2>/dev/null || true
      
      if ip link show wg0 &>/dev/null; then
        # Configure it with wg tool
        wg setconf wg0 <(cat <<EOF
[Interface]
ListenPort = 51820
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
PublicKey = ${WG_PEER_PUBKEY}
AllowedIPs = 10.100.0.2/32
EOF
) 2>/dev/null || log_warn "wg setconf failed"
        
        # Add the IP address
        ip addr add 10.100.0.1/24 dev wg0 2>/dev/null || true
        ip link set wg0 up 2>/dev/null || true
        
        log_info "✅ wg0 created and configured manually"
      fi
    fi
  fi

  # Check wg0 status
  if ip link show wg0 &>/dev/null; then
    if ip addr show wg0 | grep -q '10.100.0.1'; then
      log_info "✅ WireGuard interface wg0 is up with 10.100.0.1/24"
    else
      # Has interface but no address — add it
      ip addr add 10.100.0.1/24 dev wg0 2>/dev/null || true
      ip link set wg0 up 2>/dev/null || true
      log_info "✅ wg0 interface configured with 10.100.0.1/24"
    fi
  else
    log_warn "⚠️  wg0 interface could not be created"
    log_warn "   This is OK during bootstrap — SSH remains accessible via WAN"
    log_warn "   Debug: journalctl -u systemd-networkd | grep -i wg"
    log_warn "   Debug: networkctl list"
    log_warn "   A reboot may be required for wg0 to come up"
  fi

  # ── Kill legacy dhclient ──────────────────────────────────────────────────
  # dhclient was started by networking.service (ifupdown) and conflicts
  # with systemd-networkd's built-in DHCP client.
  if pgrep -x dhclient &>/dev/null; then
    log_info "Killing legacy dhclient (systemd-networkd handles DHCP now)..."
    pkill -x dhclient 2>/dev/null || true
    sleep 1
    if pgrep -x dhclient &>/dev/null; then
      log_warn "⚠️  dhclient still running after SIGTERM, sending SIGKILL..."
      pkill -9 -x dhclient 2>/dev/null || true
    fi
    log_info "Legacy dhclient terminated"
  fi
}

# ── Create systemd service to ensure wg0 comes up on boot ────────────────────
create_wg_boot_service() {
  log_step "Creating WireGuard boot reliability service"

  local unit_file="/etc/systemd/system/wg0-ensure.service"

  # The service reads the peer pubkey from the netdev file at runtime
  # This is more robust than embedding it in the service file
  local content
  content="$(cat <<'UNIT'
[Unit]
Description=Ensure WireGuard wg0 interface is up
After=systemd-networkd.service network-online.target
Wants=network-online.target
ConditionPathExists=/etc/systemd/network/99-wg0.netdev
ConditionPathExists=/etc/wireguard/private.key

[Service]
Type=oneshot
RemainAfterExit=yes

# Wait for networkd to settle
ExecStartPre=/bin/sleep 3

# Try networkctl reconfigure first (preferred method)
ExecStart=/bin/bash -c 'ip link show wg0 &>/dev/null && exit 0; networkctl reconfigure wg0 2>/dev/null; sleep 2; ip link show wg0 &>/dev/null && exit 0; exit 1'

# If networkctl failed, create wg0 manually using the netdev config
ExecStart=/bin/bash -c '\
  ip link show wg0 &>/dev/null && exit 0; \
  PEER_PUBKEY=$(grep -A1 "\\[WireGuardPeer\\]" /etc/systemd/network/99-wg0.netdev | grep PublicKey | cut -d= -f2 | tr -d " "); \
  [ -z "$PEER_PUBKEY" ] && echo "ERROR: No peer pubkey found" && exit 1; \
  ip link add wg0 type wireguard || exit 1; \
  wg set wg0 listen-port 51820 private-key /etc/wireguard/private.key peer "$PEER_PUBKEY" allowed-ips 10.100.0.2/32 || exit 1; \
  ip addr add 10.100.0.1/24 dev wg0 || true; \
  ip link set wg0 up || exit 1; \
  echo "wg0 created manually"'

# Final status check
ExecStart=/bin/bash -c 'ip link show wg0 && wg show wg0 && echo "✅ wg0 is up" || echo "❌ wg0 failed to come up"'

[Install]
WantedBy=multi-user.target
UNIT
)"

  if file_matches "$unit_file" "$content"; then
    log_info "wg0-ensure.service already up to date"
    return 0
  fi

  install_content "$content" "$unit_file" "0644" "root:root"

  if [[ "$DRY_RUN" != "true" ]]; then
    systemctl daemon-reload
    systemctl enable wg0-ensure.service
    log_info "wg0-ensure.service enabled (will ensure wg0 on boot)"
  fi
}

# ── Configure DNS for VPN clients ────────────────────────────────────────────
# dnsmasq listens ONLY on wg0 (10.100.0.1:53) for VPN clients.
# Resolves *.domain → Traefik IP (10.20.0.10) for internal services.
# All other queries → upstream DNS (1.1.1.1, 9.9.9.9).
configure_vpn_dns() {
  log_step "Configuring DNS for VPN clients (dnsmasq on wg0)"

  local dnsmasq_conf="/etc/dnsmasq.d/vpn.conf"
  local traefik_ip="10.20.0.10"
  local vpn_gateway="10.100.0.1"

  local content
  content="$(cat <<EOF
# =============================================================================
# VPN DNS Configuration - generated by bootstrap
# =============================================================================
# dnsmasq listens ONLY on WireGuard interface (10.100.0.1) for VPN clients.
# This provides split-horizon DNS:
#   - *.${VPN_DOMAIN} → ${traefik_ip} (Traefik reverse proxy)
#   - All other queries → upstream DNS servers

# ── Interface binding ───────────────────────────────────────────────────────
# Listen only on WireGuard interface, NOT on localhost or eth0
interface=wg0
bind-interfaces
listen-address=${vpn_gateway}

# Do NOT use /etc/resolv.conf (would create loop with systemd-resolved)
no-resolv

# ── Upstream DNS servers ────────────────────────────────────────────────────
server=1.1.1.1
server=9.9.9.9

# ── Internal DNS records ────────────────────────────────────────────────────
# Resolve *.${VPN_DOMAIN} to Traefik (VPN-only services)
address=/${VPN_DOMAIN}/${traefik_ip}

# ── Performance & Security ──────────────────────────────────────────────────
cache-size=1000
neg-ttl=60
no-poll
domain-needed
bogus-priv
EOF
)"

  mkdir -p /etc/dnsmasq.d

  if file_matches "$dnsmasq_conf" "$content"; then
    log_info "dnsmasq VPN config already up to date"
  else
    install_content "$content" "$dnsmasq_conf" "0644" "root:root"
  fi

  # Enable and restart dnsmasq
  if [[ "$DRY_RUN" != "true" ]]; then
    # dnsmasq was stopped earlier to not conflict with systemd-resolved
    # Now we configure it to listen only on wg0, so no conflict
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    # Verify it's listening on wg0
    sleep 1
    if ss -ulnp | grep -q "${vpn_gateway}:53"; then
      log_info "✅ dnsmasq listening on ${vpn_gateway}:53 for VPN clients"
    else
      log_warn "⚠️  dnsmasq may not be listening on ${vpn_gateway}:53 yet (wg0 may not be up)"
    fi
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  # CRITICAL ORDER:
  # 1. Generate server keys (if not exist)
  # 2. Install configs FIRST (while legacy networking still works)
  # 3. Start systemd-networkd (takes over interfaces)
  # 4. Create boot service for wg0 reliability
  # 5. THEN disable legacy networking (safe because networkd is running)
  
  generate_server_keys      # Generate or load WireGuard server keypair
  install_wireguard_key
  configure_wan
  configure_wg_netdev
  configure_wg_network
  enable_networkd
  create_wg_boot_service    # Ensures wg0 comes up on boot
  configure_vpn_dns         # DNS for VPN clients: *.domain → Traefik
  disable_legacy_networking # Safe now: networkd is already running

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
