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

# Let's Encrypt / ACME policy
letsencrypt_enabled              = true
letsencrypt_staging              = false
letsencrypt_require_whoami_check = true
letsencrypt_renew_before_days    = 30

# Optional services (see docs/SERVICES.md)
enable_gitea  = false   # Git server
enable_n8n    = false   # Workflow automation
enable_whoami = true    # Test service
enable_gogcli = false   # Google Workspace CLI
enable_mkdocs = false   # Documentation site (requires Gitea)
enable_kuma   = false   # Uptime monitoring
enable_pihole = false   # DNS ad blocker

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
| `letsencrypt_enabled` | | Master switch for Let's Encrypt issuance/renewal |
| `letsencrypt_staging` | | Use Let's Encrypt staging to avoid production rate limits |
| `letsencrypt_require_whoami_check` | | Require successful HTTPS preflight on `whoami.<domain>` before first issue/renew |
| `letsencrypt_renew_before_days` | | Only renew when the current cert expires within this window |
| `vpn_clients` | | VPN devices (default: `["admin"]`) |
| `admin_user` | | SSH user after hardening (default: `admin`) |
| `use_vpn` | | Set `true` after first deploy for updates via VPN |

### Let's Encrypt behavior

- `letsencrypt_enabled = false` → no Let's Encrypt request is made.
- `letsencrypt_staging = true` → safe test mode, avoids production rate limits, but browsers will show the cert as untrusted.
- `letsencrypt_require_whoami_check = true` → bootstrap first verifies `https://whoami.<domain>` locally via Traefik. If that check fails, bootstrap aborts **before** contacting Let's Encrypt.
- `letsencrypt_renew_before_days = 30` → if an existing wildcard cert is still valid for more than 30 days, no renewal attempt is made.

> If `letsencrypt_require_whoami_check = true`, keep `enable_whoami = true`. The `whoami` service is used as the HTTPS preflight target.

**Services:** See [docs/SERVICES.md](docs/SERVICES.md)

> **All services run as Docker containers** — no binaries installed on host.

For `gogcli`: Add Google OAuth credentials to `terraform.tfvars`:
```hcl
enable_gogcli        = true
google_client_id     = "xxx.apps.googleusercontent.com"
google_client_secret = "GOCSPX-xxx"
google_project_id    = "your-project"
```
See [docs/SERVICES.md](docs/SERVICES.md#gogcli) for details.

---

## VPN Setup

After `terraform apply`, the VPN config is displayed. Import it:

**Mobile:** Scan QR code with WireGuard app ([iOS](https://apps.apple.com/app/wireguard/id1441195209) / [Android](https://play.google.com/store/apps/details?id=com.wireguard.android))

**Desktop:** Copy config to WireGuard client

Ensure your config has:
```ini
DNS = 10.100.0.1          # Server's dnsmasq (default)
# DNS = 10.20.0.71        # Or: Pi-hole for ad blocking
AllowedIPs = 10.100.0.0/24, 10.20.0.0/24
```

> **Pi-hole:** Enable ad blocking by changing DNS to `10.20.0.71` (requires `enable_pihole = true`).

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

## CLI-Dienste

Nach VPN-Verbindung via SSH erreichbar. **Kein sudo erforderlich.**

Wichtig: `tea`, `n8n`, `gog`, `psql-*` sind **Host-Wrapper**. Sie rufen intern `docker exec` auf die jeweiligen Container auf.
Du brauchst auf deinem lokalen Rechner also kein installiertes `tea`/`n8n`.

### Zugriff vom Host (One-Shot)

```bash
# Vom lokalen Rechner (mit aktivem WireGuard):
ssh developer@10.100.0.1 'tea --help'
ssh developer@10.100.0.1 'n8n list:workflow --help'
ssh developer@10.100.0.1 'gog version'
```

### Interaktiv auf dem VPS

```bash
ssh developer@10.100.0.1
tea --help
n8n --help
```

Hinweis: User mit Gruppe `vpn-cli` bekommen automatisch eine normale Bash-Shell (`/bin/bash`) für CLI-Nutzung, Datei-Transfer (scp/sftp) und Write-Workflows.
User ohne `vpn-cli` (z. B. nur `vpn-web`) bleiben in der restricted Shell (`rbash`).

Wenn der Zugriff von einem zweiten VPS/Jumphost fehlschlägt (`Permission denied (publickey)`),
prüfe dort den verwendeten `IdentityFile` und die Key-Rechte:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/<private_key>
ssh -G 10.100.0.1 | grep -E 'user|identityfile|identitiesonly'
```

Der Public Key auf dem Jumphost muss zum in Terraform hinterlegten `additional_users[].ssh_pubkey`
passen (oder zum auto-generierten Key aus `terraform output -json additional_users`).

| Dienst | Befehl |
|--------|--------|
| Gitea CLI | `ssh user@10.100.0.1 tea <cmd>` |
| Gitea DB | `ssh user@10.100.0.1 psql-gitea <query>` |
| n8n CLI | `ssh user@10.100.0.1 n8n <cmd>` |
| n8n DB | `ssh user@10.100.0.1 psql-n8n <query>` |
| GOG CLI | `ssh user@10.100.0.1 gog <cmd>` |

**Ersteinrichtung tea:** In Gitea Token erstellen, dann:
```bash
ssh user@10.100.0.1 tea login add --name vps --url https://git.DOMAIN --token TOKEN
```

**Ersteinrichtung gog:**
```bash
ssh -t user@10.100.0.1 gog login
```

Details: [docs/SERVICES.md](docs/SERVICES.md)

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
    ┌───────┬───────┼───────┬───────┬───────┐      │
    ▼       ▼       ▼       ▼       ▼       ▼      ▼
 ┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐ ┌─────────────┐
 │Gitea ││ n8n  ││MkDocs││ Kuma ││whoami││Pihole│ │     SSH     │
 │:3000 ││:5678 ││:8080 ││:3001 ││ :80  ││ :53  │ │   → CLI     │
 └──────┘└──────┘└──────┘└──────┘└──────┘└──────┘ │   → gogcli  │
                                                  │   → admin   │
                                                  └─────────────┘
```

| Access Type | Services | How |
|-------------|----------|-----|
| **Web (Traefik)** | Gitea, n8n, whoami, MkDocs, Kuma | `https://service.domain` from anywhere |
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
│  Docker  → Gitea, n8n, MkDocs, Kuma │
│  SSH     → admin user, gogcli       │
└─────────────────────────────────────┘
```

---

## License

MIT — see [LICENSE](LICENSE)
