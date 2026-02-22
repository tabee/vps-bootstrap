# VPS Bootstrap System

Modular, idempotent infrastructure bootstrap for a hardened Debian 12/13 VPS running behind a WireGuard VPN with a single-ingress Docker architecture.

> **Note:** This project is generic and can be used with any domain. Configure your domain via `make setup` or in `.env`.

## 🚀 Quick Start

```bash
# 1. Clone repository
git clone <repo-url> /root/vps-bootstrap
cd /root/vps-bootstrap

# 2. Run interactive setup wizard
make setup

# 3. Apply bootstrap
make apply

# 4. Configure VPN client (on your machine)
make show-client

# 5. Connect via VPN, then lock down SSH
make ssh-lockdown

# 6. Create admin user (recommended)
make user-lockdown
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          INTERNET                                           │
│                             │                                               │
│                        UDP/51820 ONLY                                       │
│                             │                                               │
│  ┌──────────────────────────▼──────────────────────────────────────────────┐ │
│  │  eth0 (YOUR_PUBLIC_IP)             VPS: your-hostname                   │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  nftables — policy: DROP all, allow only:                       │   │ │
│  │  │    • WAN → UDP/51820 (WireGuard handshake)                      │   │ │
│  │  │    • VPN → host SSH/DNS                                         │   │ │
│  │  │    • VPN → Traefik IP only (single ingress)                     │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │                                                                        │ │
│  │  ┌────────────────────┐    ┌──────────────────────────────────────┐   │ │
│  │  │  wg0               │    │  br-vpn (10.20.0.0/24)               │   │ │
│  │  │  10.100.0.1/24     │    │                                      │   │ │
│  │  │                    │    │  ┌─────────────┐  ┌──────────────┐  │   │ │
│  │  │  ┌──────────────┐  │    │  │  Traefik    │  │  whoami      │  │   │ │
│  │  │  │ dnsmasq      │  │    │  │  10.20.0.10 │  │  10.20.0.20  │  │   │ │
│  │  │  │ DNS:53       │  │    │  │  :443 :2222 │  │  :80         │  │   │ │
│  │  │  │ *.domain→   │  │    │  └──────┬──────┘  └──────────────┘  │   │ │
│  │  │  └──────────────┘  │    │         │                            │   │ │
│  │  │                    │    │  ┌──────▼──────┐  ┌──────────────┐  │   │ │
│  │  │  ┌──────────────┐  │    │  │  Gitea      │  │  PostgreSQL  │  │   │ │
│  │  │  │ SSH          │  │    │  │  10.20.0.30 │  │  10.20.0.31  │  │   │ │
│  │  │  │ :22 (VPN)    │  │    │  │  :3000 :2222│  │  :5432       │  │   │ │
│  │  │  └──────────────┘  │    │  └─────────────┘  └──────────────┘  │   │ │
│  │  └────────────────────┘    └──────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌────────────────────┐                                                     │
│  │  VPN Client        │                                                     │
│  │  10.100.0.2/32     │◄── WireGuard tunnel                                │
│  └────────────────────┘                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Data Flow

### DNS Resolution

```
VPN Client                    VPS
    │                          │
    ├── DNS query ────────────►│ dnsmasq (10.100.0.1:53)
    │   whoami.example.com      │
    │                          ├── *.example.com → 10.20.0.10 (wildcard)
    │◄── A: 10.20.0.10 ───────┤
    │                          │
    ├── HTTPS GET ────────────►│ nftables: VPN → Traefik:443 ✅
    │   → 10.20.0.10:443       │
    │                          ├── Traefik: Host(`whoami.example.com`)
    │                          ├── ipAllowList: 10.100.0.0/24 ✅
    │                          ├── → whoami container (10.20.0.20:80)
    │◄── 200 OK ──────────────┤
```

### TLS Certificate Provisioning

```
Traefik                       Hetzner DNS API
    │                              │
    ├── DNS-01 challenge ─────────►│ Create TXT _acme-challenge.X.example.com
    │   (via HETZNER_API_TOKEN)    │
    │                              │
    ├── Verify challenge ─────────►│ Let's Encrypt checks DNS
    │                              │
    │◄── Certificate issued ──────┤
    │                              │
    ├── Store in /letsencrypt/     │
    │   acme.json                  │
```

## Security Model

### Network Perimeter

**Bootstrap Mode** (immediately after `make apply`):
| Source | Destination | Port | Protocol | Status |
|--------|-------------|------|----------|--------|
| Internet | eth0 | 51820 | UDP | ✅ WireGuard |
| Internet | eth0 | 22 | TCP | ✅ SSH (rate-limited, for recovery) |
| Internet | eth0 | 80 | TCP | ❌ Blocked |
| Internet | eth0 | 443 | TCP | ❌ Blocked |
| VPN | host | 22 | TCP | ✅ SSH |
| VPN | host | 53 | UDP/TCP | ✅ DNS |
| VPN | 10.20.0.10 | 443 | TCP | ✅ Traefik HTTPS |
| VPN | 10.20.0.10 | 2222 | TCP | ✅ Git SSH |

**Production Mode** (after `make ssh-lockdown`):
| Source | Destination | Port | Protocol | Status |
|--------|-------------|------|----------|--------|
| Internet | eth0 | 51820 | UDP | ✅ WireGuard only |
| Internet | eth0 | 22 | TCP | ❌ Blocked |
| Internet | eth0 | 80 | TCP | ❌ Blocked |
| Internet | eth0 | 443 | TCP | ❌ Blocked |
| Internet | eth0 | 53 | UDP/TCP | ❌ Blocked |
| VPN | host | 22 | TCP | ✅ SSH |
| VPN | host | 53 | UDP/TCP | ✅ DNS |
| VPN | 10.20.0.10 | 443 | TCP | ✅ Traefik HTTPS |
| VPN | 10.20.0.10 | 2222 | TCP | ✅ Git SSH |
| VPN | 10.20.0.20 | any | any | ❌ Blocked (must go via Traefik) |
| VPN | 10.20.0.30 | any | any | ❌ Blocked (must go via Traefik) |

### Docker Hardening

```json
{
  "iptables": false,     // Docker CANNOT create firewall rules
  "ip6tables": false,    // No IPv6 firewall manipulation
  "userland-proxy": false // No TCP proxy bypassing firewall
}
```

**Why this matters:** By default, Docker's `-p`/`ports:` directive creates iptables rules that bypass nftables entirely. A single `ports: "80:80"` would expose a container to the entire internet. With `iptables: false`, Docker cannot touch the firewall — all network policy is in nftables.

### Compose File Security

All `docker-compose.yml` files enforce:
- **No `ports:` directive** — containers are never published to host
- `security_opt: [no-new-privileges:true]` — prevents privilege escalation
- `cap_drop: [ALL]` — drops all Linux capabilities
- Minimal `cap_add` — only what each service needs
- `read_only: true` where possible

### Defense in Depth

Three independent layers prevent unauthorized access:

1. **nftables** — Only forwards VPN traffic to Traefik IP
2. **Traefik ipAllowList** — Only accepts requests from VPN subnet
3. **DNS** — Resolves all domains to Traefik, not individual containers

## Directory Structure

```
bootstrap/
├── apply.sh                 # Main orchestrator (with auto-rollback)
├── preflight.sh             # Pre-bootstrap validation
├── rollback.sh              # Restore from backup
├── setup-wizard.sh          # Interactive setup for first-time users
├── status-dashboard.sh      # Formatted system status display
├── backup-data.sh           # Application data backup/restore
├── ssh-lockdown.sh          # Restrict SSH to VPN only
├── user-lockdown.sh         # Create admin user, disable root
├── init-env.sh              # Auto-generate secrets
├── .env.example             # Secret template (HETZNER_API_TOKEN required)
├── modules/
│   ├── 01-system.sh         # Packages, sysctl, SSH
│   ├── 02-network.sh        # systemd-networkd, WireGuard
│   ├── 03-dns.sh            # dnsmasq, systemd-resolved
│   ├── 04-firewall.sh       # nftables ruleset
│   ├── 05-docker.sh         # Docker CE, daemon, vpn_net
│   ├── 06-traefik.sh        # Traefik reverse proxy
│   ├── 07-gitea.sh          # Gitea + PostgreSQL
│   ├── 08-whoami.sh         # Diagnostic service
│   └── 09-security.sh       # Fail2ban, auditd, auto-updates
└── lib/
    ├── logging.sh            # Structured logging
    ├── backup.sh             # File backup/restore
    └── validate.sh           # Post-deployment checks
```

## Rebuild Procedure

### Prerequisites

- Fresh Debian 12 (bookworm) or Debian 13 (trixie) x86_64 installation
- Root SSH access (will be locked to VPN after bootstrap)
- Internet connectivity
- Domain managed by Hetzner DNS
- Hetzner Cloud API token (with DNS permissions)

### Step 1: Clone Repository

```bash
# Install prerequisites
apt update && apt install -y git make

# Clone and enter directory
git clone https://github.com/tabee/vps-bootstrap.git
cd vps-bootstrap
```

First run automatically creates `.env` and generates secrets:

```bash
make apply
```

On first run, you'll be prompted to fill in `HETZNER_API_TOKEN`:
1. Open `bootstrap/.env`
2. Set `HETZNER_API_TOKEN=<your-hetzner-api-token>` (get from https://console.hetzner.cloud/ → Project → Security → API Tokens)
3. Run `make apply` again

> **Note:** Hetzner migrated DNS management to the Cloud API in 2025. Tokens from the old `dns.hetzner.com` console no longer work. Use the Cloud Console token instead.

### Step 2: Dry Run

```bash
make dry-run
```

Review output. No changes are made.

### Step 3: Apply Bootstrap

```bash
make apply
```

This configures:
- System packages and hardening
- systemd-networkd for eth0 (WAN) + wg0 (WireGuard)
- dnsmasq for VPN DNS
- nftables firewall (DROP policy, allow only WireGuard)
- Docker with custom network (vpn_net)
- Traefik reverse proxy
- Gitea + PostgreSQL containers

⚠️ **SSH remains accessible on all interfaces during bootstrap** to prevent lockout if wg0 fails.
The firewall blocks SSH from WAN, so only VPN/console access is possible.

### Step 4: Validate

```bash
make validate
```

### Step 5: Complete VPN Setup (FROM YOUR CLIENT MACHINE)

Once bootstrap finishes:

```bash
# 1. Get client VPN config (on VPS)
make show-client

# 2. Copy wg0-client.conf to your client machine and connect
wg-quick up wg0

# 3. Test SSH via VPN (from your client)
ssh root@10.100.0.1

# 4. Test services (replace example.com with your domain)
curl -sk https://whoami.example.com
curl -sk https://git.example.com
```

### Step 6: Restrict SSH to VPN Only (ON VPS, after verifying VPN works)

Once you've successfully connected via VPN:

```bash
# On the VPS:
make ssh-lockdown
```

This restricts SSH to listen only on the WireGuard interface (10.100.0.1).
**Important**: Only run this after confirming SSH works via VPN!

### Step 7: Post-Bootstrap Testing

```bash
# After connecting via WireGuard (replace example.com with your domain):
curl -sk https://whoami.example.com
curl -sk https://git.example.com
ssh -p 2222 git@git.example.com
```

## Validation Gates

The `make validate` target verifies:

| Check | Description |
|-------|-------------|
| `validate_sysctl` | IPv4 forwarding on, IPv6 off, hardening flags |
| `validate_wireguard_up` | wg0 interface exists |
| `validate_nft_policy` | Input/forward chains default to DROP |
| `validate_no_public_listeners` | No TCP/UDP listeners on WAN |
| `validate_docker_daemon_config` | iptables/ip6tables/userland-proxy disabled |
| `validate_docker_no_published_ports` | No containers with published ports |
| `validate_traefik_reachable` | Traefik responds on 10.20.0.10:443 |

## Make Targets

### Setup & Configuration
| Target | Description |
|--------|-------------|
| `make setup` | **Interactive setup wizard** — recommended for first-time setup |
| `make init-env` | Create .env from .env.example and auto-generate secrets |
| `make rotate-secrets` | Rotate all auto-generated secrets (WireGuard keys, DB password, Gitea tokens) |
| `make show-client` | Print wg0-client.conf for VPN client setup |

### Bootstrap & Deployment
| Target | Description |
|--------|-------------|
| `make apply` | Run full bootstrap with auto-rollback on failure |
| `make dry-run` | Preview changes without applying |
| `make validate` | Run post-deployment validation gates |
| `make preflight` | Run preflight checks only |
| `make module-XX` | Run a single module (e.g., `make module-04`) |

### Security & Hardening
| Target | Description |
|--------|-------------|
| `make ssh-lockdown` | Restrict SSH to VPN only (run AFTER verifying VPN works!) |
| `make user-lockdown` | Create admin user with sudo and disable root login |

### Monitoring & Status
| Target | Description |
|--------|-------------|
| `make status` | **Formatted dashboard** — shows all services at a glance |

### Backup & Recovery
| Target | Description |
|--------|-------------|
| `make backup-data` | Backup application data (Gitea, PostgreSQL, Traefik certs) |
| `make restore-data` | Restore application data from backup |
| `make list-backups` | List available data backups |
| `make rollback` | Interactive rollback to previous system state |

### Quality & Testing
| Target | Description |
|--------|-------------|
| `make lint` | Run shellcheck on all scripts |
| `make test` | Run smoke tests |

## Module Details

### 01-system
Installs required packages (wireguard, nftables, dnsmasq, docker-ce), configures kernel parameters via sysctl (IPv4 forwarding, IPv6 disabled, anti-spoofing), hardens SSH to VPN-only.

### 02-network
Configures systemd-networkd for eth0 (DHCP) and wg0 (WireGuard). Installs WireGuard private key. Disables legacy networking and wg-quick.

### 03-dns
Configures dnsmasq to listen only on wg0, resolving all `*.<your-domain>` to Traefik IP (10.20.0.10). Configures systemd-resolved as stub resolver for the host.

### 04-firewall
Installs nftables ruleset with DROP policy. Only allows: WAN UDP/51820, VPN→SSH, VPN→DNS, VPN→Traefik (80/443/2222), container-to-container on vpn_net, outbound NAT. Validates syntax with `nft -c` before applying.

### 05-docker
Installs Docker CE from official repo. Configures daemon with `iptables: false`, `ip6tables: false`, `userland-proxy: false`. Creates deterministic `vpn_net` network (10.20.0.0/24, bridge br-vpn, masquerade disabled).

### 06-traefik
Deploys Traefik v3.6.7 as single ingress point. File provider only (no Docker socket). DNS-01 ACME via Hetzner Cloud API (`HETZNER_API_URL=https://api.hetzner.cloud/v1`). No dashboard. Runs as non-root (65532), read-only filesystem, all caps dropped except NET_BIND_SERVICE.

### 07-gitea
Deploys Gitea 1.25.4 + PostgreSQL 16. No published ports. Registration disabled. Sign-in required for all views. SSH on port 2222 via Traefik TCP passthrough.

### 08-whoami
Deploys traefik/whoami as a diagnostic endpoint. Validates the entire ingress pipeline: DNS → nftables → Traefik → container.

### 09-security
Advanced security hardening module:
- **Fail2ban** — Intrusion prevention with custom WireGuard filter, bans IPs after 5 failed attempts
- **auditd** — Comprehensive audit logging for authentication, privilege escalation, and system changes
- **unattended-upgrades** — Automatic security updates with auto-reboot at 3 AM
- **VPN health-check** — Systemd timer that monitors WireGuard connectivity every 5 minutes, auto-restarts on failure

## Security Features

### Active Protection
| Component | Function |
|-----------|----------|
| **Fail2ban** | Blocks IPs after failed WireGuard auth attempts (5 tries = 1 hour ban) |
| **auditd** | Logs all authentication, sudo, and file permission changes |
| **nftables** | Default DROP policy, only WireGuard ingress from WAN |
| **Traefik ipAllowList** | Only accepts connections from VPN subnet |
| **Docker hardening** | iptables disabled, no privilege escalation |

### Automatic Maintenance
| Feature | Description |
|---------|-------------|
| **Auto-updates** | Security patches applied automatically via unattended-upgrades |
| **Auto-reboot** | System reboots at 3 AM if required by kernel updates |
| **VPN health-check** | Monitors wg0 interface, restarts systemd-networkd on failure |
| **Auto-rollback** | Bootstrap automatically rolls back on validation failure |

### Audit Logging
All security-relevant events are logged via auditd:
- Authentication attempts (`/etc/shadow`, `/etc/passwd`)
- Privilege escalation (`sudo`, setuid binaries)
- Network configuration changes
- Module loading
- System time changes

View audit logs:
```bash
ausearch -k auth_changes    # Authentication events
ausearch -k priv_esc        # Privilege escalation
journalctl -u auditd        # Auditd service logs
```

## Idempotency

Every module is designed to be run multiple times safely:

- **File installation:** Checks if content matches before writing
- **Package installation:** Skips already-installed packages
- **Service enablement:** Checks current state before changing
- **Docker networks:** Verifies existing config before creating
- **nftables:** Validates syntax before applying, `flush ruleset` ensures clean state
- **Backups:** Creates timestamped backup before every file modification

## Troubleshooting

### SSH locked out after bootstrap
SSH now listens only on 10.100.0.1 (WireGuard). Connect via VPN first, or use Hetzner console.

### Traefik not getting certificates
Check `HETZNER_API_TOKEN` in `/opt/traefik/.env`. The token must be from **Hetzner Cloud Console** (not the deprecated dns.hetzner.com). Verify DNS zone permissions. Check Traefik logs: `docker logs traefik`.

**Common causes:**
- Token from old DNS Console (no longer works since 2025)
- Let's Encrypt rate limit hit (5 certs per 168h for same identifiers)
- Missing DNS zone in Hetzner Cloud project

### dnsmasq won't start
dnsmasq binds to 10.100.0.1, which requires wg0 to be up. Ensure `systemd-networkd` has created the WireGuard interface: `ip addr show wg0`.

### Containers can't reach internet
Verify nftables NAT rules: `nft list table ip nat`. Ensure the `postrouting` chain masquerades Docker subnet traffic.

### Bootstrap failed and rolled back
Check the rollback log: `ls /var/backups/bootstrap/`. The auto-rollback preserves the failed state for debugging. Review `journalctl -xe` for specific errors.

### VPN health-check keeps restarting networkd
Check WireGuard interface: `wg show wg0`. If no peers connected, this is expected behavior. The health-check only restarts on actual failures, not missing handshakes.

### Fail2ban not starting
Ensure WireGuard logs to `/var/log/wireguard.log`. Check jail status: `fail2ban-client status wireguard`.

### Status dashboard shows ○ NOT INSTALLED
Some security services (fail2ban, auditd) are optional. Run `make module-09` to install them.

## Backup & Recovery

### System Configuration Backups
The bootstrap system automatically backs up all modified files before changes:
```bash
# List available system backups
ls /var/backups/bootstrap/

# Interactive rollback
make rollback
```

### Application Data Backups
Separate backup system for application data (Gitea repos, database, TLS certs):
```bash
# Create backup
make backup-data

# List backups
make list-backups

# Restore (interactive)
make restore-data
```

Backups are stored in `/var/backups/vps-bootstrap/` and retained for 30 days.

## Files and Locations

### Configuration Files
| Path | Purpose |
|------|---------|
| `/etc/systemd/network/` | Network configuration (eth0, wg0) |
| `/etc/nftables.conf` | Firewall ruleset |
| `/etc/dnsmasq.d/` | DNS configuration |
| `/etc/docker/daemon.json` | Docker hardening |
| `/etc/fail2ban/` | Intrusion prevention |
| `/etc/audit/rules.d/` | Audit logging rules |

### Application Data
| Path | Purpose |
|------|---------|
| `/opt/traefik/` | Traefik config, TLS certificates |
| `/opt/gitea/` | Gitea data, PostgreSQL database |
| `/var/log/wireguard.log` | WireGuard authentication logs |
| `/var/backups/bootstrap/` | System configuration backups |
| `/var/backups/vps-bootstrap/` | Application data backups |

## Development

### Running Tests
```bash
make lint    # Shellcheck all scripts
make test    # Smoke tests
```

### System Snapshots

Create a comprehensive system snapshot for debugging or documentation:

```bash
make snapshot        # Create timestamped snapshot
make list-snapshots  # List available snapshots
```

Snapshots are stored in `snapshot/<timestamp>/` and include:
- System info (OS, packages, uptime)
- Network configuration (IP, routes, WireGuard)
- Docker state (containers, images, networks)
- Firewall rules, DNS config, systemd services
- Security status (fail2ban, audit logs)

### Adding a New Module
1. Create `bootstrap/modules/XX-name.sh` following existing patterns
2. Add to `MODULES` array in `bootstrap/apply.sh`
3. Add Make target in `Makefile`
4. Add tests in `tests/smoke.sh`
5. Document in this README

## Project Structure

```
vps-bootstrap/
├── README.md                  # This documentation
├── Makefile                   # Build system (all make targets)
├── LICENSE                    # MIT License
├── .env.example               # Symlink to bootstrap/.env.example
├── .gitignore                 # Git ignore rules (.env, secrets)
├── bootstrap/                 # Main bootstrap system
│   ├── .env.example           # Environment template (HETZNER_API_TOKEN required)
│   ├── apply.sh               # Main orchestrator with auto-rollback
│   ├── preflight.sh           # Pre-flight checks
│   ├── rollback.sh            # Rollback support
│   ├── setup-wizard.sh        # Interactive setup
│   ├── status-dashboard.sh    # System status display
│   ├── backup-data.sh         # Application backup/restore
│   ├── ssh-lockdown.sh        # VPN-only SSH
│   ├── user-lockdown.sh       # Admin user setup
│   ├── init-env.sh            # Secret generation
│   ├── lib/                   # Shared libraries
│   │   ├── logging.sh         # Logging functions
│   │   ├── backup.sh          # Backup utilities
│   │   └── validate.sh        # Validation gates
│   └── modules/               # Bootstrap modules (01-09)
│       ├── 01-system.sh       # Base system, packages, sysctl
│       ├── 02-network.sh      # WireGuard VPN, systemd-networkd
│       ├── 03-dns.sh          # dnsmasq for VPN DNS
│       ├── 04-firewall.sh     # nftables (DROP policy)
│       ├── 05-docker.sh       # Docker CE, vpn_net bridge
│       ├── 06-traefik.sh      # Reverse proxy, ACME certs
│       ├── 07-gitea.sh        # Git server + PostgreSQL
│       ├── 08-whoami.sh       # Diagnostic service
│       ├── 09-security.sh     # Fail2ban, auditd, auto-updates
│       └── snapshot.sh        # System snapshot for debugging
├── snapshot/                  # Snapshot output directory
└── tests/
    └── smoke.sh               # Smoke tests
```

## License

MIT License - see [LICENSE](LICENSE) for details.
