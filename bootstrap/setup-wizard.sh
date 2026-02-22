#!/usr/bin/env bash
# =============================================================================
# setup-wizard.sh — Interactive setup wizard for VPS Bootstrap
# =============================================================================
# Guides new users through the initial configuration process.
# Creates .env file with proper secrets and validates inputs.
#
# Run with: make setup
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

BOOTSTRAP_MODULE="setup-wizard"

ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# ── Colors for interactive prompts ──────────────────────────────────────────
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

print_banner() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}       ${BOLD}VPS Bootstrap Setup Wizard${NC}                            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}       Interactive configuration for your VPS               ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

prompt() {
  local varname="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local secret="${4:-false}"
  local value=""
  
  if [[ -n "$default" ]]; then
    echo -en "${GREEN}?${NC} ${prompt_text} ${YELLOW}[$default]${NC}: "
  else
    echo -en "${GREEN}?${NC} ${prompt_text}: "
  fi
  
  if [[ "$secret" == "true" ]]; then
    read -rs value
    echo ""
  else
    read -r value
  fi
  
  if [[ -z "$value" && -n "$default" ]]; then
    value="$default"
  fi
  
  eval "$varname=\"$value\""
}

validate_email() {
  local email="$1"
  if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    return 0
  fi
  return 1
}

validate_not_empty() {
  local value="$1"
  [[ -n "$value" ]]
}

generate_secret() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

# ── Main wizard flow ────────────────────────────────────────────────────────
main() {
  print_banner
  
  # Check if .env already exists
  if [[ -f "$ENV_FILE" ]]; then
    echo -e "${YELLOW}⚠${NC}  An existing .env file was found."
    echo ""
    prompt OVERWRITE "Do you want to overwrite it? (yes/no)" "no"
    if [[ "$OVERWRITE" != "yes" ]]; then
      echo ""
      echo -e "${GREEN}✓${NC} Keeping existing configuration."
      echo "  Run 'make apply' to continue with the current settings."
      exit 0
    fi
    echo ""
    cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}✓${NC} Backup created: ${ENV_FILE}.backup.*"
    echo ""
  fi
  
  echo -e "${BOLD}Step 1/4: Server Information${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  
  # Detect public IP
  DETECTED_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
  prompt SERVER_IP "Server public IP address" "$DETECTED_IP"
  
  if ! validate_not_empty "$SERVER_IP"; then
    echo -e "${RED}✗${NC} Server IP cannot be empty"
    exit 1
  fi
  
  prompt VPN_DOMAIN "VPN domain (e.g., example.com)" "example.com"
  
  echo ""
  echo -e "${BOLD}Step 2/4: Hetzner DNS API${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  echo "  Let's Encrypt uses DNS-01 challenge via Hetzner DNS API."
  echo "  Create an API token at: https://dns.hetzner.com/settings/api-token"
  echo ""
  
  prompt HETZNER_API_TOKEN "Hetzner DNS API Token" "" "true"
  
  if ! validate_not_empty "$HETZNER_API_TOKEN"; then
    echo -e "${RED}✗${NC} Hetzner API token is required for TLS certificates"
    exit 1
  fi
  
  echo ""
  echo -e "${BOLD}Step 3/4: Let's Encrypt${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  
  prompt ACME_EMAIL "Email for Let's Encrypt notifications" "admin@${VPN_DOMAIN}"
  
  if ! validate_email "$ACME_EMAIL"; then
    echo -e "${RED}✗${NC} Invalid email format"
    exit 1
  fi
  
  echo ""
  echo -e "${BOLD}Step 4/4: WireGuard VPN${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  
  # Generate WireGuard keys
  echo "  Generating WireGuard key pair..."
  WG_PRIVATE_KEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)
  WG_PUBLIC_KEY=$(echo "$WG_PRIVATE_KEY" | wg pubkey 2>/dev/null || echo "GENERATE_ON_APPLY")
  
  echo ""
  echo "  Do you already have a WireGuard client key pair?"
  prompt HAS_CLIENT_KEY "Enter 'yes' if you have an existing client public key" "no"
  
  if [[ "$HAS_CLIENT_KEY" == "yes" ]]; then
    prompt WG_PEER_PUBKEY "Client public key"
  else
    # Generate client keys
    echo ""
    echo "  Generating client key pair..."
    CLIENT_PRIVATE_KEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)
    WG_PEER_PUBKEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey 2>/dev/null || echo "GENERATE_MANUALLY")
    echo ""
    echo -e "${YELLOW}⚠${NC}  Save this client private key (you will need it for your VPN client):"
    echo ""
    echo -e "     ${BOLD}${CLIENT_PRIVATE_KEY}${NC}"
    echo ""
  fi
  
  # Generate other secrets
  echo "  Generating database password..."
  DB_PASSWORD=$(generate_secret)
  
  echo "  Generating Gitea secrets..."
  GITEA_SECRET_KEY=$(generate_secret)
  GITEA_INTERNAL_TOKEN=$(generate_secret)$(generate_secret)
  
  echo ""
  echo "─────────────────────────────────────────────────"
  echo -e "${BOLD}Configuration Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  echo -e "  Server IP:         ${GREEN}$SERVER_IP${NC}"
  echo -e "  Domain:            ${GREEN}$VPN_DOMAIN${NC}"
  echo -e "  ACME Email:        ${GREEN}$ACME_EMAIL${NC}"
  echo -e "  Hetzner Token:     ${GREEN}*****${HETZNER_API_TOKEN: -4}${NC}"
  echo -e "  WG Server Key:     ${GREEN}${WG_PUBLIC_KEY:0:20}...${NC}"
  echo -e "  WG Client Key:     ${GREEN}${WG_PEER_PUBKEY:0:20}...${NC}"
  echo ""
  
  prompt CONFIRM "Create .env with these settings? (yes/no)" "yes"
  
  if [[ "$CONFIRM" != "yes" ]]; then
    echo ""
    echo -e "${YELLOW}✗${NC} Setup cancelled."
    exit 1
  fi
  
  # Write .env file
  cat > "$ENV_FILE" <<EOF
# =============================================================================
# .env — VPS Bootstrap Configuration
# =============================================================================
# Generated by setup-wizard.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# DO NOT COMMIT THIS FILE — it contains secrets!
# =============================================================================

# ── Server Configuration ────────────────────────────────────────────────────
SERVER_IP=${SERVER_IP}
VPN_DOMAIN=${VPN_DOMAIN}

# ── Hetzner DNS API ─────────────────────────────────────────────────────────
HETZNER_API_TOKEN=${HETZNER_API_TOKEN}

# ── Let's Encrypt ───────────────────────────────────────────────────────────
ACME_EMAIL=${ACME_EMAIL}

# ── WireGuard VPN ───────────────────────────────────────────────────────────
WG_PRIVATE_KEY=${WG_PRIVATE_KEY}
WG_PEER_PUBKEY=${WG_PEER_PUBKEY}

# ── Database ────────────────────────────────────────────────────────────────
DB_PASSWORD=${DB_PASSWORD}

# ── Gitea ───────────────────────────────────────────────────────────────────
GITEA_SECRET_KEY=${GITEA_SECRET_KEY}
GITEA_INTERNAL_TOKEN=${GITEA_INTERNAL_TOKEN}
EOF

  chmod 0600 "$ENV_FILE"
  
  echo ""
  echo -e "${GREEN}✓${NC} Configuration saved to ${ENV_FILE}"
  echo ""
  echo "─────────────────────────────────────────────────"
  echo -e "${BOLD}Next Steps${NC}"
  echo "─────────────────────────────────────────────────"
  echo ""
  echo "  1. Run the bootstrap:"
  echo -e "     ${CYAN}make apply${NC}"
  echo ""
  echo "  2. Configure your WireGuard client:"
  echo -e "     ${CYAN}make show-client${NC}"
  echo ""
  echo "  3. After VPN works, lock down SSH:"
  echo -e "     ${CYAN}make ssh-lockdown${NC}"
  echo ""
  echo "  4. Create admin user (optional but recommended):"
  echo -e "     ${CYAN}make user-lockdown${NC}"
  echo ""
}

main "$@"
