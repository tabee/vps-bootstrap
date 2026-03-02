#!/bin/bash
# =============================================================================
# scripts/add-vpn-client.sh — Add a new WireGuard client
# =============================================================================
# Usage: ./add-vpn-client.sh <client-name>
#
# 1. Generates keys for the new client
# 2. Finds the next free IP in 10.100.0.0/24
# 3. Adds the peer to /etc/systemd/network/99-wg0.netdev
# 4. Reloads systemd-networkd
# 5. Outputs Client Config & QR Code
# =============================================================================

set -e

CLIENT_NAME="$1"
NETDEV_FILE="/etc/systemd/network/99-wg0.netdev"
SERVER_PUBKEY_FILE="/etc/wireguard/public.key" # Falls existent, sonst aus wg show holen
SERVER_ENDPOINT="95.217.11.109:51820" # TODO: Automatisch ermitteln oder via Env?
DNS_SERVER="10.100.0.1"

if [[ -z "$CLIENT_NAME" ]]; then
  echo "Usage: $0 <client-name>"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# 0. Check prerequisites
if ! command -v wg &> /dev/null; then
  apt-get update && apt-get install -y wireguard-tools
fi
if ! command -v qrencode &> /dev/null; then
  apt-get update && apt-get install -y qrencode
fi

# 1. Server Public Key ermitteln
if [[ -f "$SERVER_PUBKEY_FILE" ]]; then
  SERVER_PUBKEY=$(cat "$SERVER_PUBKEY_FILE")
else
  # Fallback: Aus laufendem Interface holen (wenn wg0 läuft)
  SERVER_PUBKEY=$(wg show wg0 public-key 2>/dev/null || true)
  
  if [[ -z "$SERVER_PUBKEY" ]]; then
     # Letzter Versuch: Private Key ableiten
     if [[ -f "/etc/wireguard/private.key" ]]; then
        SERVER_PUBKEY=$(wg pubkey < /etc/wireguard/private.key)
     else
        echo "Error: Could not find Server Public Key."
        exit 1
     fi
  fi
fi

# 2. Next Free IP
# Scanne netdev file nach AllowedIPs=10.100.0.X
# Wir starten bei .2 (.1 ist Server)
USED_IPS=$(grep "AllowedIPs" "$NETDEV_FILE" | grep -o "10\.100\.0\.[0-9]*" | cut -d. -f4 | sort -n)

NEXT_IP=2
for ip in $USED_IPS; do
  if [[ "$ip" -eq "$NEXT_IP" ]]; then
    NEXT_IP=$((NEXT_IP + 1))
  fi
done

if [[ "$NEXT_IP" -gt 254 ]]; then
  echo "Error: No free IPs in 10.100.0.0/24"
  exit 1
fi

CLIENT_IP="10.100.0.${NEXT_IP}"
echo "🔹 Selected IP: ${CLIENT_IP}/32"

# 3. Generate Client Keys
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
CLIENT_PSK=$(wg genpsk)

echo "🔹 Keys generated for $CLIENT_NAME"

# 4. Add to systemd-networkd config
# Append WireGuardPeer block
# Wir nutzen PreSharedKey für extra Sicherheit

cat >> "$NETDEV_FILE" <<EOF

[WireGuardPeer]
# Client: ${CLIENT_NAME}
PublicKey=${CLIENT_PUBKEY}
PresharedKey=${CLIENT_PSK}
AllowedIPs=${CLIENT_IP}/32
EOF

# Fix permissions just in case
chmod 640 "$NETDEV_FILE"
chown root:systemd-network "$NETDEV_FILE"

echo "🔹 Added peer to $NETDEV_FILE"

# 5. Reload Networkd
echo "🔹 Reloading systemd-networkd..."
networkctl reload
# Warten kurz
sleep 2

# Check ob Peer aktiv
if wg show wg0 peers | grep -q "$CLIENT_PUBKEY"; then
  echo "✅ Peer is active on wg0"
else
  echo "⚠️  Warning: Peer not showing up in 'wg show'. Might need full restart or time to sync."
fi

# 6. Generate Client Config
CLIENT_CONF_CONTENT="[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_IP}/24
DNS = ${DNS_SERVER}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"

echo ""
echo "=================================================================="
echo "   WireGuard Config for: ${CLIENT_NAME} (${CLIENT_IP})"
echo "=================================================================="
echo ""
echo "$CLIENT_CONF_CONTENT"
echo ""
echo "=================================================================="
echo "   SCAN QR CODE BELOW (Mobile)"
echo "=================================================================="
echo ""

qrencode -t ANSIUTF8 <<< "$CLIENT_CONF_CONTENT"

echo ""
echo "✅ Done."
