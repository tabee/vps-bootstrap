# Optional Services

All services run as Docker containers behind Traefik reverse proxy with automatic HTTPS.

## Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │              INTERNET               │
                    └─────────────────────────────────────┘
                                    │
           ┌────────────────────────┼────────────────────────┐
           │                        │                        │
           ▼                        ▼                        ▼
    HTTPS (443)              WireGuard (51820)          SSH (2222)
           │                        │                     Gitea
           ▼                        ▼
    ┌─────────────┐          ┌─────────────┐
    │   TRAEFIK   │          │  VPN ONLY   │
    │  (public)   │          │  (private)  │
    └─────────────┘          └─────────────┘
           │                        │
    ┌──────┼──────┐                 │
    ▼      ▼      ▼                 ▼
  Gitea   n8n  whoami           SSH → CLI
  :3000  :5678  :80                 │
                              ┌─────┴─────┐
                              │  gogcli   │
                              │  admin    │
                              │  scripts  │
                              └───────────┘
```

| Access | Services | Method |
|--------|----------|--------|
| 🌐 **Web (Public)** | Gitea, n8n, whoami | Browser → `https://service.domain` |
| 🔒 **VPN (Private)** | gogcli, admin CLI | VPN connect → `ssh admin@10.100.0.1` |

> **TODO:** CLI-Addon für direkten Service-Zugriff via VPN (ohne Browser).

---

## Quick Reference

| Service | Port | URL | Enable Variable |
|---------|------|-----|-----------------|
| Gitea | 3000 | `https://gitea.DOMAIN` | `install_gitea = true` |
| n8n | 5678 | `https://n8n.DOMAIN` | `install_n8n = true` |
| whoami | 80 | `https://whoami.DOMAIN` | `install_whoami = true` |
| gogcli | - | CLI tool | `install_gogcli = true` |

---

## Gitea

Lightweight Git server with web interface.

### Configuration

```hcl
install_gitea = true
gitea_version = "1.23"  # Optional, default: 1.23
```

### Access

- URL: `https://gitea.YOUR_DOMAIN`
- First user registered becomes admin
- Data stored in: `/opt/gitea/`

### SSH Clone

Uses port 2222 to avoid conflict with system SSH:

```bash
git clone ssh://git@YOUR_DOMAIN:2222/user/repo.git
```

---

## n8n

Workflow automation platform (self-hosted Zapier alternative).

### Configuration

```hcl
install_n8n = true
n8n_version = "latest"  # Optional, default: latest
```

### Access

- URL: `https://n8n.YOUR_DOMAIN`
- Create account on first visit
- Data stored in: `/opt/n8n/`

### Security Note

n8n is exposed to the internet. Consider restricting access via additional Traefik middleware if needed.

---

## whoami

Simple diagnostic container that echoes HTTP request headers. Useful for testing Traefik routing.

### Configuration

```hcl
install_whoami = true
```

### Access

- URL: `https://whoami.YOUR_DOMAIN`
- Shows: IP, headers, hostname

---

## gogcli

GOG.com command-line download client. Installed as binary, not a container.

> ⚠️ **Access:** Nur via VPN + SSH erreichbar (kein Web-Interface).

```
┌──────────┐     VPN      ┌────────────┐     SSH      ┌─────────┐
│  Client  │ ──────────── │  10.100.0.1│ ──────────── │ gogcli  │
│ (lokal)  │   WireGuard  │   Server   │  admin user  │  CLI    │
└──────────┘              └────────────┘              └─────────┘
```

### Configuration

```hcl
install_gogcli   = true
gogcli_version   = "1.1.3"  # Optional, default: 1.1.3
```

### Usage

```bash
# 1. Connect VPN
# 2. SSH into server
ssh admin@10.100.0.1

# 3. Authenticate (one-time, interactive)
gog login

# 4. Use CLI
gog owned              # List games
gog download <id>      # Download game
```

### Authentication & Credentials

Die Authentifizierung erfolgt interaktiv via `gog login`. Credentials werden lokal gespeichert:

- **Token-Datei:** `~/.config/gog/token.json`
- **Manifest-Cache:** `~/.cache/gog/`

📖 **Vollständige Dokumentation:**
- GitHub: [Magnushhoie/gogcli](https://github.com/Magnushhoie/gogcli)
- Auth-Details: [gogcli Wiki – Authentication](https://github.com/Magnushhoie/gogcli#authentication)

> **Tipp:** Für automatisierte Downloads (Cronjobs) kann das Token manuell in `~/.config/gog/token.json` hinterlegt werden.

### Binary Location

- `/usr/local/bin/gog`

---

## Adding Services

Custom services should follow this pattern:

1. Create `bootstrap/services/your-service.sh`
2. Add variables to `variables.tf` and `terraform.tfvars.example`
3. Add conditional call in `main.tf`

### Template

```bash
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="myservice"
SERVICE_VERSION="${1:-latest}"
DOMAIN="${2}"

# Create directories
mkdir -p /opt/"$SERVICE_NAME"

# Create docker-compose.yml
cat > /opt/"$SERVICE_NAME"/docker-compose.yml << EOF
services:
  $SERVICE_NAME:
    image: myimage:$SERVICE_VERSION
    container_name: $SERVICE_NAME
    restart: unless-stopped
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.$SERVICE_NAME.rule=Host(\`$SERVICE_NAME.$DOMAIN\`)"
      - "traefik.http.routers.$SERVICE_NAME.entrypoints=websecure"
      - "traefik.http.routers.$SERVICE_NAME.tls.certresolver=letsencrypt"
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF

cd /opt/"$SERVICE_NAME" && docker compose up -d
```

---

## Troubleshooting

### Service not accessible?

```bash
# Check container status
docker ps -a | grep SERVICE_NAME

# View logs
docker logs SERVICE_NAME

# Check Traefik routing
docker logs traefik 2>&1 | grep SERVICE_NAME
```

### Certificate issues?

```bash
# Check ACME log
cat /opt/traefik/acme.json | jq '.letsencrypt.Certificates[].domain'
```

### Port conflicts?

```bash
# Check what's using a port
ss -tlnp | grep :PORT
```
