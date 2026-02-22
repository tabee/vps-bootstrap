#!/usr/bin/env bash
# =============================================================================
# status-dashboard.sh — Formatted system status dashboard
# =============================================================================
# Displays a colorful, organized overview of system components.
#
# Run with: make status
# =============================================================================

set -euo pipefail

# ── Colors and symbols ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

OK="${GREEN}●${NC}"
WARN="${YELLOW}●${NC}"
ERR="${RED}●${NC}"
INFO="${BLUE}●${NC}"

# ── Box drawing characters ──────────────────────────────────────────────────
# Using Unicode box-drawing characters for clean borders
BOX_TL="┌"
BOX_TR="┐"
BOX_BL="└"
BOX_BR="┘"
BOX_H="─"
BOX_V="│"
BOX_LT="├"
BOX_RT="┤"

WIDTH=68

draw_top() {
  echo -e "${CYAN}${BOX_TL}$(printf '%*s' $((WIDTH-2)) '' | tr ' ' "$BOX_H")${BOX_TR}${NC}"
}

draw_bottom() {
  echo -e "${CYAN}${BOX_BL}$(printf '%*s' $((WIDTH-2)) '' | tr ' ' "$BOX_H")${BOX_BR}${NC}"
}

draw_separator() {
  echo -e "${CYAN}${BOX_LT}$(printf '%*s' $((WIDTH-2)) '' | tr ' ' "$BOX_H")${BOX_RT}${NC}"
}

draw_line() {
  local content="$1"
  # Strip ANSI codes for length calculation
  local stripped
  stripped=$(echo -e "$content" | sed 's/\x1b\[[0-9;]*m//g')
  local pad=$((WIDTH - 4 - ${#stripped}))
  [[ $pad -lt 0 ]] && pad=0
  echo -e "${CYAN}${BOX_V}${NC}  ${content}$(printf '%*s' $pad '')  ${CYAN}${BOX_V}${NC}"
}

draw_title() {
  local title="$1"
  local pad=$(( (WIDTH - 4 - ${#title}) / 2 ))
  local pad2=$((WIDTH - 4 - ${#title} - pad))
  echo -e "${CYAN}${BOX_V}${NC}$(printf '%*s' $pad '')${BOLD}${title}${NC}$(printf '%*s' $pad2 '')${CYAN}${BOX_V}${NC}"
}

draw_empty() {
  echo -e "${CYAN}${BOX_V}$(printf '%*s' $((WIDTH-2)) '')${BOX_V}${NC}"
}

# ── Status checks ───────────────────────────────────────────────────────────
check_wireguard() {
  if ip link show wg0 &>/dev/null; then
    local peer_count
    peer_count=$(wg show wg0 peers 2>/dev/null | wc -l || echo 0)
    local latest_handshake
    latest_handshake=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo 0)
    
    if [[ "$latest_handshake" != "0" && -n "$latest_handshake" ]]; then
      local now
      now=$(date +%s)
      local diff=$((now - latest_handshake))
      if [[ $diff -lt 180 ]]; then
        echo -e "$OK ${GREEN}UP${NC} — $peer_count peer(s), last handshake ${diff}s ago"
      else
        echo -e "$WARN ${YELLOW}UP${NC} — $peer_count peer(s), no recent handshake"
      fi
    else
      echo -e "$INFO ${BLUE}UP${NC} — $peer_count peer(s) configured, awaiting connection"
    fi
  else
    echo -e "$ERR ${RED}DOWN${NC} — Interface not found"
  fi
}

check_ssh() {
  if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
    local listen_ips
    listen_ips=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | cut -d: -f1 | sort -u | tr '\n' ' ' || echo "")
    
    if echo "$listen_ips" | grep -q "10.100.0.1"; then
      if echo "$listen_ips" | grep -qE "0.0.0.0|\*"; then
        echo -e "$WARN ${YELLOW}ACTIVE${NC} — Listening on 0.0.0.0 (not locked down)"
      else
        echo -e "$OK ${GREEN}LOCKED${NC} — VPN-only (10.100.0.1)"
      fi
    elif echo "$listen_ips" | grep -qE "0.0.0.0|\*"; then
      echo -e "$WARN ${YELLOW}EXPOSED${NC} — Listening on all interfaces"
    else
      echo -e "$INFO ${BLUE}ACTIVE${NC} — Listening on: $listen_ips"
    fi
  else
    echo -e "$ERR ${RED}STOPPED${NC} — SSH daemon not running"
  fi
}

check_firewall() {
  if systemctl is-active nftables &>/dev/null; then
    local wan_rules
    wan_rules=$(nft list chain inet filter input 2>/dev/null | grep -c "iifname.*eth0" || echo 0)
    local policy
    policy=$(nft list chain inet filter input 2>/dev/null | head -1 | grep -oP 'policy \K\w+' || echo "unknown")
    
    if [[ "$policy" == "drop" ]]; then
      echo -e "$OK ${GREEN}ACTIVE${NC} — Policy: DROP, $wan_rules WAN rules"
    else
      echo -e "$WARN ${YELLOW}ACTIVE${NC} — Policy: $policy"
    fi
  else
    echo -e "$ERR ${RED}INACTIVE${NC} — nftables not running"
  fi
}

check_docker() {
  if systemctl is-active docker &>/dev/null; then
    local container_count
    container_count=$(docker ps -q 2>/dev/null | wc -l || echo 0)
    local network_mode
    network_mode=$(docker info 2>/dev/null | grep -i "iptables" | head -1 || echo "")
    
    if [[ "$network_mode" == *"false"* ]]; then
      echo -e "$OK ${GREEN}ACTIVE${NC} — $container_count containers, iptables disabled"
    else
      echo -e "$INFO ${BLUE}ACTIVE${NC} — $container_count containers"
    fi
  else
    echo -e "$ERR ${RED}STOPPED${NC} — Docker daemon not running"
  fi
}

check_traefik() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "traefik"; then
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' traefik 2>/dev/null || echo "unknown")
    
    if [[ "$health" == "healthy" ]]; then
      echo -e "$OK ${GREEN}HEALTHY${NC} — Reverse proxy running"
    elif [[ "$health" == "unknown" ]]; then
      echo -e "$INFO ${BLUE}RUNNING${NC} — Health check not configured"
    else
      echo -e "$WARN ${YELLOW}$health${NC} — May need attention"
    fi
  else
    echo -e "$ERR ${RED}STOPPED${NC} — Container not running"
  fi
}

check_gitea() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gitea"; then
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' gitea 2>/dev/null || echo "unknown")
    
    if [[ "$health" == "healthy" ]]; then
      echo -e "$OK ${GREEN}HEALTHY${NC} — Git server running"
    elif [[ "$health" == "unknown" ]]; then
      echo -e "$INFO ${BLUE}RUNNING${NC}"
    else
      echo -e "$WARN ${YELLOW}$health${NC}"
    fi
  else
    echo -e "$ERR ${RED}STOPPED${NC} — Container not running"
  fi
}

check_postgres() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "postgres"; then
    echo -e "$OK ${GREEN}RUNNING${NC} — Database ready"
  else
    echo -e "$ERR ${RED}STOPPED${NC} — Container not running"
  fi
}

check_fail2ban() {
  if systemctl is-active fail2ban &>/dev/null; then
    local banned
    banned=$(fail2ban-client status 2>/dev/null | grep -c "Currently banned" || echo 0)
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list://' | tr -d '[:space:]' || echo "")
    echo -e "$OK ${GREEN}ACTIVE${NC} — Jails: ${jails:-none}"
  else
    echo -e "$DIM${DIM}○ NOT INSTALLED${NC}"
  fi
}

check_auditd() {
  if systemctl is-active auditd &>/dev/null; then
    local rules
    rules=$(auditctl -l 2>/dev/null | wc -l || echo 0)
    echo -e "$OK ${GREEN}ACTIVE${NC} — $rules audit rules loaded"
  else
    echo -e "$DIM${DIM}○ NOT INSTALLED${NC}"
  fi
}

check_upgrades() {
  if systemctl is-active unattended-upgrades &>/dev/null; then
    echo -e "$OK ${GREEN}ENABLED${NC} — Auto-security updates"
  elif dpkg -l unattended-upgrades &>/dev/null; then
    echo -e "$WARN ${YELLOW}INSTALLED${NC} — Service not running"
  else
    echo -e "$DIM${DIM}○ NOT INSTALLED${NC}"
  fi
}

check_vpn_health() {
  if systemctl is-active vpn-health-check.timer &>/dev/null; then
    local last_run
    last_run=$(systemctl show vpn-health-check.service --property=ExecMainExitTimestamp 2>/dev/null | cut -d= -f2 || echo "never")
    echo -e "$OK ${GREEN}ACTIVE${NC} — Timer enabled"
  else
    echo -e "$DIM${DIM}○ NOT CONFIGURED${NC}"
  fi
}

# ── System info ─────────────────────────────────────────────────────────────
get_uptime() {
  uptime -p 2>/dev/null | sed 's/up //' || echo "unknown"
}

get_load() {
  cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "unknown"
}

get_memory() {
  free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo "unknown"
}

get_disk() {
  df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo "unknown"
}

# ── Main dashboard ──────────────────────────────────────────────────────────
main() {
  clear 2>/dev/null || true
  echo ""
  
  draw_top
  draw_empty
  draw_title "VPS Status Dashboard"
  draw_line "${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
  draw_empty
  draw_separator
  
  # System overview
  draw_empty
  draw_line "${BOLD}System${NC}"
  draw_line "  Uptime:     $(get_uptime)"
  draw_line "  Load:       $(get_load)"
  draw_line "  Memory:     $(get_memory)"
  draw_line "  Disk:       $(get_disk)"
  draw_empty
  draw_separator
  
  # Core services
  draw_empty
  draw_line "${BOLD}Core Services${NC}"
  draw_line "  WireGuard:  $(check_wireguard)"
  draw_line "  SSH:        $(check_ssh)"
  draw_line "  Firewall:   $(check_firewall)"
  draw_line "  Docker:     $(check_docker)"
  draw_empty
  draw_separator
  
  # Application services
  draw_empty
  draw_line "${BOLD}Application Services${NC}"
  draw_line "  Traefik:    $(check_traefik)"
  draw_line "  Gitea:      $(check_gitea)"
  draw_line "  PostgreSQL: $(check_postgres)"
  draw_empty
  draw_separator
  
  # Security services
  draw_empty
  draw_line "${BOLD}Security Services${NC}"
  draw_line "  Fail2ban:   $(check_fail2ban)"
  draw_line "  Auditd:     $(check_auditd)"
  draw_line "  Auto-Update:$(check_upgrades)"
  draw_line "  VPN Health: $(check_vpn_health)"
  draw_empty
  
  draw_bottom
  echo ""
  
  # Legend
  echo -e "  ${OK} OK   ${WARN} Warning   ${ERR} Error   ${INFO} Info   ${DIM}○ Not installed${NC}"
  echo ""
}

main "$@"
