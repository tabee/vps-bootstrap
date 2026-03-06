# VPS Bootstrap

**Hardened Debian 12 VPS with WireGuard VPN — deploy in 5 minutes.**

After installation, the server is **only accessible via VPN**. All services run behind Traefik with automatic HTTPS.

---

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/tabee/vps-bootstrap.git && cd vps-bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Deploy
terraform init && terraform apply

# 3. Connect VPN (config shown at end of deploy)
# 4. Access server
ssh admin@10.100.0.1
```

---

## Prerequisites

| Requirement | How |
|-------------|-----|
| **Hetzner Server** | [console.hetzner.cloud](https://console.hetzner.cloud) → Debian 12, CX22+, add SSH key |
| **Domain** | Point `*.domain.com` to server IP |
| **DNS API Token** | Hetzner Console → Project → Security → API Tokens |
| **Terraform** | `brew install terraform` or [terraform.io/downloads](https://terraform.io/downloads) |

---

## Configuration

Edit `terraform.tfvars`:

```hcl
# Required
ssh_host          = "123.45.67.89"      # Server IP
domain            = "example.com"
hetzner_dns_token = "your-token"
acme_email        = "you@example.com"

# Optional services (see docs/SERVICES.md)
enable_gitea  = false   # Git server
enable_n8n    = false   # Workflow automation
enable_whoami = true    # Test service
enable_gogcli = false   # Google Workspace CLI

# VPN clients
vpn_clients = ["admin", "laptop", "phone"]

# After first deploy with hardening, set:
# use_vpn = true
```

| Variable | Required | Description |
|----------|:--------:|-------------|
| `ssh_host` | ✓ | Server IP address |
| `domain` | ✓ | Your domain |
| `hetzner_dns_token` | ✓ | DNS API token for Let's Encrypt |
| `acme_email` | ✓ | Email for Let's Encrypt |
| `vpn_clients` | | VPN devices (default: `["admin"]`) |
| `admin_user` | | SSH user after hardening (default: `admin`) |
| `use_vpn` | | Set `true` after first deploy for updates via VPN |

**Services:** See [docs/SERVICES.md](docs/SERVICES.md)

For `gogcli` OAuth setup (Google Console old/new UI):
- with **Download JSON** button
- or without download (create new client secret and build `credentials.json` manually)

See the `gogcli` section in [docs/SERVICES.md](docs/SERVICES.md) for the exact steps.

---

## VPN Setup

After `terraform apply`, the VPN config is displayed. Import it:

**Mobile:** Scan QR code with WireGuard app ([iOS](https://apps.apple.com/app/wireguard/id1441195209) / [Android](https://play.google.com/store/apps/details?id=com.wireguard.android))

**Desktop:** Copy config to WireGuard client

Ensure your config has:
```ini
DNS = 10.100.0.1
AllowedIPs = 10.100.0.0/24, 10.20.0.0/24
```

---

## Managing VPN Clients

```hcl
# Add/remove in terraform.tfvars:
vpn_clients = ["admin", "laptop", "new-device"]
```

```bash
terraform apply

# Show config for specific client:
ssh admin@10.100.0.1 'sudo /opt/vps/bootstrap/scripts/vpn-client.sh show laptop'
```

---

## Post-Installation Updates

After hardening, SSH is only via VPN. For Terraform updates:

```hcl
# terraform.tfvars
use_vpn = true
```

```bash
# With VPN connected:
terraform apply
```

---

## Credentials

```bash
terraform output -json credentials | jq
```

Store securely (password manager).

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| VPN won't connect | Check DNS: `dig +short your-domain.com` → should show server IP |
| Services unreachable | Ensure `AllowedIPs` includes `10.20.0.0/24` |
| Locked out | Hetzner Console → Rescue System → mount & repair |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                              INTERNET                               │
└─────────────────────────────────────────────────────────────────────┘
                    │                              │
                    │ HTTPS (443)                  │ WireGuard (51820)
                    ▼                              ▼
┌─────────────────────────────────┐    ┌─────────────────────────────┐
│            TRAEFIK              │    │         VPN TUNNEL          │
│   (public web services only)    │    │    (admin access only)      │
└─────────────────────────────────┘    └─────────────────────────────┘
                    │                              │
        ┌───────────┼───────────┐                  │
        ▼           ▼           ▼                  ▼
   ┌────────┐  ┌────────┐  ┌─────────┐      ┌─────────────┐
   │ Gitea  │  │  n8n   │  │ whoami  │      │     SSH     │
   │  :3000 │  │ :5678  │  │   :80   │      │   → CLI     │
   └────────┘  └────────┘  └─────────┘      │   → gogcli  │
                                            │   → admin   │
                                            └─────────────┘
```

| Access Type | Services | How |
|-------------|----------|-----|
| **Web (Traefik)** | Gitea, n8n, whoami | `https://service.domain` from anywhere |
| **VPN (SSH)** | gogcli, CLI tools, admin | Connect VPN → `ssh admin@10.100.0.1` |

> **TODO:** CLI-Addon für Service-Zugriff via VPN ohne Browser (Roadmap).

---

## Security

- **Network:** Only UDP 51820 (WireGuard) + HTTPS (443) public
- **SSH:** VPN-only, key-auth, no root login
- **Firewall:** nftables, default-deny
- **Updates:** Automatic security patches

---

## Architecture

```
Internet
    │
    ▼ UDP 51820
┌─────────────────────────────────────┐
│  WireGuard VPN (10.100.0.0/24)      │
└─────────────────────────────────────┘
    │
    ▼ VPN only
┌─────────────────────────────────────┐
│  Traefik → HTTPS services           │
│  Docker  → Gitea, n8n, whoami       │
│  SSH     → admin user, gogcli       │
└─────────────────────────────────────┘
```

---

## License

MIT — see [LICENSE](LICENSE)
