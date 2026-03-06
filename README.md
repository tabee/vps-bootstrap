# VPS Bootstrap

**Secure VPS infrastructure with a single command.**

Creates a hardened Debian 12 server with:
- 🔐 WireGuard VPN (only access method after installation)
- 🌐 Automatic HTTPS certificates (Let's Encrypt via Hetzner DNS)
- 🐳 Docker-based services (optional: Gitea, n8n, gogcli)
- 🛡️ Firewall, Fail2ban, automatic security updates

---

## 🤖 OpenClaw-Ready: AI Agents Without Credential Leaks

> **This setup is specifically designed for AI agents (like [OpenClaw](https://openclaw.io)) to securely access services — without secrets ever being sent to an LLM.**

### The Problem

AI agents with LLM backends need access to tools (Git, email, calendar, workflows). But:
- Credentials in agent prompts → LLM sees them → security risk
- API keys in agent config → potentially in training data

### The Solution: Credentials Stay on the VPS

```
┌─────────────────────────┐                              ┌──────────────────────────────┐
│   OpenClaw              │                              │  Your VPS (this repo)        │
│   (separate VPS)        │                              │                              │
│                         │                              │  ┌────────────────────────┐  │
│  ┌───────────────────┐  │   WireGuard VPN (10.100.x)   │  │ 🔒 Credentials here:   │  │
│  │ AI Agent + LLM    │  │ ◄────────────────────────────┤  │                        │  │
│  │                   │  │                              │  │ • SSH Private Keys     │  │
│  │ Sees ONLY:        │  │   SSH: gog gmail search ...  │  │ • Google OAuth Tokens  │  │
│  │ • JSON responses  │  │ ─────────────────────────────►  │ • DB Passwords         │  │
│  │ • API answers     │  │                              │  │ • Service Secrets      │  │
│  │                   │  │   HTTPS: Gitea/n8n API       │  │                        │  │
│  │ Does NOT see:     │  │ ─────────────────────────────►  └────────────────────────┘  │
│  │ • OAuth Secrets   │  │                              │                              │
│  │ • Private Keys    │  │                              │  ┌────────────────────────┐  │
│  │ • DB Passwords    │  │ ◄──── JSON Response ─────────┤  │ Services:              │  │
│  └───────────────────┘  │                              │  │ • Traefik (Reverse     │  │
│                         │                              │  │   Proxy)               │  │
│  WireGuard Client +     │                              │  │ • Gitea (Git API)      │  │
│  SSH Key (local)        │                              │  │ • n8n (Workflows)      │  │
│                         │                              │  │ • gogcli (Google CLI)  │  │
└─────────────────────────┘                              └──────────────────────────────┘
```

### Two Access Patterns

| Pattern | Services | How | What LLM Sees |
|---------|----------|-----|---------------|
| **SSH/CLI** | Google Workspace (gogcli) | `ssh admin@10.100.0.1 "gog gmail ..."` | Only JSON response |
| **HTTPS/API** | Gitea, n8n | API calls via Traefik | Only API response |

### Example: OpenClaw Reads Emails

```bash
# OpenClaw executes (SSH key on OpenClaw-VPS, not with LLM):
ssh admin@10.100.0.1 "gog gmail search 'is:unread' --max 5 --json"

# LLM sees only the response:
[{"id": "abc123", "subject": "Meeting tomorrow", "from": "boss@company.com"}]

# LLM does NOT see:
# • Google OAuth Client Secret (in /opt/gogcli/)
# • Google Access/Refresh Token (in /opt/gogcli/)
# • SSH Private Key (on OpenClaw-VPS)
```

### Example: OpenClaw Creates Git Issue

```bash
# OpenClaw calls (token has only issue rights, not admin):
curl -H "Authorization: token giteaXYZ..." \
  https://git.your-domain.com/api/v1/repos/user/repo/issues \
  -d '{"title": "Bug found"}'

# LLM only knows the restricted API token
# LLM does NOT know:
# • Gitea Admin password
# • PostgreSQL credentials
# • Gitea Secret Key / Internal Token
```

### Set Up OpenClaw as VPN Client

```hcl
# In terraform.tfvars:
vpn_clients = ["admin", "laptop", "openclaw"]
```

```bash
terraform apply

# Get WireGuard config for OpenClaw:
terraform output -json vpn_configs | jq -r '.openclaw'
```

Then install the WireGuard config on the OpenClaw-VPS and add SSH key for `admin@10.100.0.1`.

---

### 📋 TODO

| Service | Tool | Status |
|---------|------|--------|
| Google Workspace | `gog` (gogcli) | ✅ Done |
| Gitea | `tea` CLI | 🔧 Planned |
| n8n | Built-in CLI | 🔧 Planned |

---

## Prerequisites

### 1. Create Server (5 min)

1. Go to [Hetzner Cloud Console](https://console.hetzner.cloud)
2. Create new project (if not exists)
3. Add server:
   - **Location:** Any (e.g., Falkenstein)
   - **Image:** Debian 12
   - **Type:** CX22 or larger (min 2 vCPU, 4 GB RAM)
   - **SSH Key:** Add your public key
4. Create server and **note the IP address**

### 2. Set Up Domain (5 min)

At [Hetzner Cloud Console](https://console.hetzner.cloud) → DNS:

```
example.com      A     123.45.67.89    (your server IP)
*.example.com    A     123.45.67.89    (wildcard for services)
```

**Create DNS API Token:** Console → Project → Security → API Tokens

> ⚠️ The old dns.hetzner.com tokens no longer work since 2025!

### 3. Install Terraform (once)

```bash
# macOS
brew install terraform

# Linux (Debian/Ubuntu)
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform
terraform --version

# Or: https://terraform.io/downloads
```

---

## Installation

> **Important:** Terraform runs on your **local machine** (client), not on the VPS! Terraform connects via SSH to the server and configures it remotely.

### Prepare SSH-Agent (for passphrase-protected keys)

```bash
# Start SSH-Agent
eval "$(ssh-agent -s)"

# Add key (passphrase prompted once)
ssh-add ~/.ssh/id_ed25519

# Verify key is loaded
ssh-add -l
```

### Step 1: Clone Repository

```bash
git clone https://github.com/tabee/vps-bootstrap.git
cd vps-bootstrap
```

### Step 2: Create Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and enter your values:

```hcl
# REQUIRED - Must be set
ssh_host             = "123.45.67.89"        # IP from Hetzner Console
ssh_private_key_path = ""                    # Empty = use SSH-Agent
domain               = "example.com"          # Your domain
hetzner_dns_token    = "xxx"                  # DNS API Token
acme_email           = "you@example.com"      # Email for Let's Encrypt

# OPTIONAL - Enable services (default: off)
enable_gitea  = false  # Git server at git.example.com
enable_n8n    = false  # Workflow automation at n8n.example.com
enable_whoami = true   # Test service at whoami.example.com
enable_gogcli = false  # Google Workspace CLI (via SSH)

# OPTIONAL - VPN clients (default: ["admin"])
vpn_clients = ["admin", "iphone", "laptop"]
```

### Step 3: Set Up Server

```bash
terraform init      # Once: download plugins
terraform apply     # Configure server (~5 minutes)
```

Terraform shows you at the end:
- All generated passwords
- VPN configurations
- Service URLs

### Step 4: Set Up VPN (IMPORTANT!)

⚠️ **After completion, the server is ONLY accessible via VPN!**

```bash
# Show VPN config
terraform output -json access | jq -r '.vpn.config_cmd' | bash

# Or QR code for WireGuard app (iOS/Android)
terraform output -json access | jq -r '.vpn.qr_cmd' | bash
```

1. Install WireGuard app ([iOS](https://apps.apple.com/app/wireguard/id1441195209) / [Android](https://play.google.com/store/apps/details?id=com.wireguard.android))
2. Scan QR code or import config
3. Activate VPN

### Step 5: Test Connection

```bash
# With VPN connected:
ssh admin@10.100.0.1    # SSH over VPN

# Become root (passwordless)
sudo -i

# Test service
curl -k https://whoami.example.com
```

---

## Configuration (terraform.tfvars)

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `ssh_host` | ✓ | - | Server IP address |
| `ssh_private_key_path` | | - | Path to SSH key (empty = SSH-Agent) |
| `domain` | ✓ | - | Your domain |
| `hetzner_dns_token` | ✓ | - | Hetzner DNS API Token |
| `acme_email` | ✓ | - | Email for Let's Encrypt |
| `enable_gitea` | | `false` | Git server (git.domain.com) |
| `enable_n8n` | | `false` | Workflow tool (n8n.domain.com) |
| `enable_whoami` | | `true` | Test service (whoami.domain.com) |
| `enable_gogcli` | | `false` | Google Workspace CLI (via SSH) |
| `vpn_clients` | | `["admin"]` | List of VPN clients |
| `admin_user` | | `"admin"` | SSH username after hardening |

---

## Manage VPN Clients

### Add New Client

```hcl
# In terraform.tfvars:
vpn_clients = ["admin", "iphone", "laptop", "new-device"]
```

```bash
terraform apply
```

### Remove Client

```hcl
# Remove client from list:
vpn_clients = ["admin", "laptop"]  # "iphone" removed
```

```bash
terraform apply  # Client is automatically deleted
```

### List All Clients

```bash
ssh admin@10.100.0.1 'sudo /opt/vps/bootstrap/scripts/vpn-client.sh list'
```

---

## gogcli (Google Workspace CLI)

With `enable_gogcli = true`, [gogcli](https://gogcli.sh) is installed - a CLI for Gmail, Calendar, Drive, Sheets, etc.

### Security Model

**No HTTP endpoint.** Access exclusively via SSH:

```bash
# From your local machine (via VPN):
ssh admin@10.100.0.1 "gog gmail search 'is:unread' --json"

# From another VPS (e.g., OpenClaw):
ssh admin@10.100.0.1 "gog drive list --json"
```

### Setup

1. **Create Google OAuth Credentials:**
   - [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
   - OAuth 2.0 Client ID → "Desktop app"
   - Download JSON file

2. **Copy credentials to server:**
   ```bash
   scp client_secret_*.json admin@10.100.0.1:/opt/gogcli/
   ```

3. **Authorize (once):**
   ```bash
   ssh admin@10.100.0.1
   gog auth credentials /opt/gogcli/client_secret_*.json
   gog auth add your@gmail.com
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
| `gmail` | `gog gmail search 'is:unread' --max 10` |
| `drive` | `gog drive list --json` |
| `calendar` | `gog calendar events --days 7` |
| `sheets` | `gog sheets get SPREADSHEET_ID` |
| `docs` | `gog docs list` |
| `contacts` | `gog contacts list` |
| `tasks` | `gog tasks list` |

---

## Passwords & Credentials

All passwords are securely generated:

```bash
# Show all credentials
terraform output -json credentials | jq

# VPN config for admin
terraform output -json access | jq -r '.vpn.config_cmd' | bash
```

⚠️ **Store these credentials securely (e.g., password manager)!**

---

## SSH Access After Installation

After installation, SSH is **only accessible via VPN**:

```bash
# ❌ No longer possible from outside:
ssh root@123.45.67.89

# ✅ Via VPN:
ssh admin@10.100.0.1

# Become root:
sudo -i
```

---

## Troubleshooting

### VPN Not Connecting

1. **Check DNS:** Does your domain point to the server IP?
   ```bash
   dig +short example.com
   ```
2. **Port open?** UDP 51820 must be reachable
   ```bash
   nc -zu SERVER_IP 51820 && echo "OK" || echo "BLOCKED"
   ```
3. **Config correct?** Check endpoint IP in WireGuard config

### Locked Out?

If VPN doesn't work and SSH is no longer accessible:
1. Hetzner Console → Server → Enable Rescue System
2. Restart server (boots into Rescue)
3. Mount disk and repair SSH config

---

## Security

This server is maximally hardened after installation:

- **Network:** Only UDP 51820 (WireGuard) publicly reachable
- **SSH:** Only via VPN, key-auth only, no root
- **Firewall:** nftables with default-DENY policy
- **Docker:** Cannot manipulate firewall (`iptables: false`)
- **Updates:** Security updates automatic (unattended-upgrades)
- **Intrusion Detection:** Fail2ban blocks brute-force

---

## What Gets Installed?

| Component | Purpose | Port |
|-----------|---------|------|
| WireGuard | VPN tunnel | UDP 51820 (only public port!) |
| nftables | Firewall | - |
| Docker | Container runtime | - |
| Traefik | Reverse proxy + HTTPS | 443 (VPN only) |
| Fail2ban | Brute-force protection | - |
| Unattended Upgrades | Auto-updates | - |
| (optional) Gitea | Git server | 2222 (SSH, VPN only) |
| (optional) n8n | Workflow automation | - |
| (optional) whoami | Test service | - |
| (optional) gogcli | Google Workspace CLI | via SSH |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Internet                                                   │
│       │                                                     │
│       ▼ UDP 51820 (only open port)                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  WireGuard VPN                                         │ │
│  │  10.100.0.1 (Server) ←→ 10.100.0.2+ (Clients)         │ │
│  └────────────────────────────────────────────────────────┘ │
│       │                                                     │
│       ▼ Only accessible via VPN                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Docker (10.20.0.0/24)                                 │ │
│  │    ├── Traefik (443) ─→ git.*, n8n.*, whoami.*        │ │
│  │    ├── Gitea (optional)                                │ │
│  │    ├── n8n (optional)                                  │ │
│  │    └── whoami (optional)                               │ │
│  └────────────────────────────────────────────────────────┘ │
│       │                                                     │
│       │ SSH                                                 │
│       ▼                                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  gogcli (optional, no Docker!)                          │ │
│  │    └── /usr/local/bin/gog → Gmail, Drive, Calendar...  │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## License

MIT License - see [LICENSE](LICENSE)
