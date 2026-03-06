# Optional Services

This document describes the optional services that can be enabled in `terraform.tfvars`.

All services are:
- 🔒 Only accessible via WireGuard VPN
- 🔐 HTTPS with automatic Let's Encrypt certificates
- 🐳 Running in Docker containers (except gogcli)

---

## Quick Reference

| Service | Enable Flag | URL | Purpose |
|---------|-------------|-----|---------|
| Gitea | `enable_gitea = true` | https://git.domain.com | Git server |
| n8n | `enable_n8n = true` | https://n8n.domain.com | Workflow automation |
| whoami | `enable_whoami = true` | https://whoami.domain.com | Test service |
| gogcli | `enable_gogcli = true` | SSH only | Google Workspace CLI |

---

## Gitea (Git Server)

Self-hosted Git server with web UI, API, and SSH access.

### Enable

```hcl
# terraform.tfvars
enable_gitea = true
```

### Access

| Method | URL/Command |
|--------|-------------|
| Web UI | https://git.your-domain.com |
| Git SSH | `git clone ssh://git@git.your-domain.com:2222/user/repo.git` |
| API | https://git.your-domain.com/api/v1/ |

### First Setup

1. Open https://git.your-domain.com
2. Create admin account (first user becomes admin)
3. Configure settings in admin panel

### Credentials

```bash
# Show database password and secret key
terraform output -json credentials | jq '.gitea'
```

### API Access (for AI Agents)

```bash
# Create access token in Gitea UI: Settings → Applications → Generate Token

# Example: Create issue
curl -H "Authorization: token YOUR_TOKEN" \
  https://git.your-domain.com/api/v1/repos/user/repo/issues \
  -d '{"title": "Bug report", "body": "Description here"}'
```

---

## n8n (Workflow Automation)

Low-code workflow automation platform. Connect services, automate tasks.

### Enable

```hcl
# terraform.tfvars
enable_n8n = true
```

### Access

| Method | URL |
|--------|-----|
| Web UI | https://n8n.your-domain.com |
| Webhook | https://n8n.your-domain.com/webhook/... |

### First Setup

1. Open https://n8n.your-domain.com
2. Create account (first user becomes admin)
3. Start building workflows

### Credentials

```bash
# Show database password and encryption key
terraform output -json credentials | jq '.n8n'
```

### Use Cases

- Webhook receivers (GitHub, Stripe, etc.)
- Scheduled tasks (cron-like)
- API integrations
- Data transformations

---

## whoami (Test Service)

Simple test container that returns request information. Useful for verifying Traefik and DNS setup.

### Enable

```hcl
# terraform.tfvars
enable_whoami = true  # This is the default
```

### Access

```bash
# Via VPN
curl https://whoami.your-domain.com
```

### Expected Output

```
Hostname: whoami-container-id
IP: 10.20.0.x
RemoteAddr: 10.20.0.1:xxxxx
GET / HTTP/1.1
Host: whoami.your-domain.com
...
```

### Disable After Testing

```hcl
# terraform.tfvars
enable_whoami = false
```

```bash
terraform apply
```

---

## gogcli (Google Workspace CLI)

CLI tool for Gmail, Drive, Calendar, Sheets, etc. **No HTTP endpoint** — access exclusively via SSH.

### Enable

```hcl
# terraform.tfvars
enable_gogcli = true
```

### Security Model

Unlike other services, gogcli has **no web interface**. Access is via SSH only:

```bash
# From your local machine (via VPN):
ssh admin@10.100.0.1 "gog gmail search 'is:unread' --json"

# From another VPS (e.g., OpenClaw AI agent):
ssh admin@10.100.0.1 "gog drive list --json"
```

This means:
- ✅ OAuth tokens stay on the VPS
- ✅ AI agents see only JSON responses
- ✅ No credentials exposed to LLMs

### Setup

1. **Create Google OAuth Credentials:**
   - [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
   - Create OAuth 2.0 Client ID → "Desktop app"
   - Download JSON file

2. **Copy credentials to server:**
   ```bash
   scp client_secret_*.json admin@10.100.0.1:/opt/gogcli/
   ```

3. **Authorize (once per Google account):**
   ```bash
   ssh admin@10.100.0.1
   gog auth credentials /opt/gogcli/client_secret_*.json
   gog auth add your@gmail.com
   # Follow the authorization URL
   ```

4. **Test:**
   ```bash
   gog gmail labels list
   gog drive list
   gog calendar events --days 7
   ```

### Available Services

| Service | Example Command |
|---------|-----------------|
| `gmail` | `gog gmail search 'is:unread' --max 10 --json` |
| `drive` | `gog drive list --json` |
| `calendar` | `gog calendar events --days 7 --json` |
| `sheets` | `gog sheets get SPREADSHEET_ID` |
| `docs` | `gog docs list` |
| `contacts` | `gog contacts list` |
| `tasks` | `gog tasks list` |

### Use with AI Agents

Perfect for AI agents that need Google Workspace access without credential exposure:

```bash
# Agent executes via SSH (SSH key on agent's server, not in LLM):
ssh admin@10.100.0.1 "gog gmail search 'from:boss@company.com' --max 5 --json"

# LLM sees only:
[{"id": "abc123", "subject": "Meeting tomorrow", "from": "boss@company.com"}]

# LLM does NOT see:
# • Google OAuth Client Secret
# • Google Access/Refresh Tokens
# • SSH Private Key
```

---

## Credentials Management

All service passwords are auto-generated by Terraform:

```bash
# Show all credentials
terraform output -json credentials | jq

# Specific service
terraform output -json credentials | jq '.gitea'
terraform output -json credentials | jq '.n8n'
terraform output -json credentials | jq '.gogcli'
```

⚠️ **Store these credentials securely (e.g., password manager)!**

---

## Enable/Disable Services

### Enable a Service

```hcl
# terraform.tfvars
enable_n8n = true
```

```bash
terraform apply
```

### Disable a Service

```hcl
# terraform.tfvars
enable_n8n = false
```

```bash
terraform apply
```

This will:
1. Stop and remove Docker containers
2. Keep data volumes (for potential re-enable)

### Completely Remove Service Data

```bash
ssh admin@10.100.0.1
sudo -i
docker volume rm n8n_data  # or gitea_data, etc.
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  VPN Clients (10.100.0.0/24)                                │
│       │                                                     │
│       ▼                                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Traefik (Reverse Proxy)                               │ │
│  │    ├── git.domain.com  → Gitea (10.20.0.30)           │ │
│  │    ├── n8n.domain.com  → n8n (10.20.0.40)             │ │
│  │    └── whoami.domain.com → whoami (10.20.0.x)         │ │
│  └────────────────────────────────────────────────────────┘ │
│       │                                                     │
│       │ Not via Traefik:                                   │
│       │                                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  SSH (Port 22, VPN only)                               │ │
│  │    └── gog command → gogcli binary                     │ │
│  └────────────────────────────────────────────────────────┘ │
│       │                                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Gitea SSH (Port 2222, VPN only)                       │ │
│  │    └── git clone ssh://git@...:2222/...               │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```
