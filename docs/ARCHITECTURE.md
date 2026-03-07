# VPS Bootstrap — Architecture Reference

> **This document is for AI assistants** (Claude, GPT, Copilot, etc.) working on this codebase.
> It defines the architectural principles that must be followed when adding or modifying services.

---

## Core Principles

### 1. EVERYTHING RUNS IN DOCKER

**No exceptions.** Every service must be a Docker container.

| ✅ Correct | ❌ Wrong |
|------------|----------|
| `docker-compose.yml` with service definition | Binary installed to `/usr/local/bin/` |
| Container image from registry | `curl ... \| sh` install scripts |
| Config mounted into container | Config in `/etc/` or `~/.config/` |

**Why:** Consistency, reproducibility, easy cleanup, isolation.

---

### 2. NO EXPOSED PORTS

Containers must **never** publish ports to the host.

| ✅ Correct | ❌ Wrong |
|------------|----------|
| Traefik labels for routing | `ports: ["8080:80"]` |
| Internal Docker network only | `0.0.0.0:PORT` binding |
| Access via Traefik or SSH | Direct port access |

**Why:** Security. Only WireGuard (51820) and HTTPS (443) are exposed to the internet.

---

### 3. TWO ACCESS PATTERNS

| Type | Services | How | Example |
|------|----------|-----|---------|
| **Web (Traefik)** | Gitea, n8n, whoami | HTTPS via reverse proxy | `https://gitea.domain.com` |
| **CLI (SSH)** | gogcli, tea, admin tools | `docker exec` via SSH | `ssh admin@10.100.0.1 'tea repos ls'` |

**Web services:** Use Traefik labels, accessed from anywhere via HTTPS.
**CLI services:** No web interface, accessed only via VPN+SSH.

---

### 4. CREDENTIALS VIA TERRAFORM

Secrets and credentials should be passed through Terraform → `.env` → container.

```
terraform.tfvars          →  main.tf (env_content)  →  .env file  →  docker-compose.yml
google_client_id = "..."     GOOGLE_CLIENT_ID=...      env_file: .env
```

**Why:** Single source of truth, no manual file copying, secrets in state (encrypted).

---

## Service Template

When adding a new service, follow this pattern:

### 1. variables.tf

```hcl
variable "enable_myservice" {
  description = "Install MyService? (Docker, Traefik/SSH access)"
  type        = bool
  default     = false
}

variable "myservice_api_key" {
  description = "API key for MyService"
  type        = string
  default     = ""
  sensitive   = true
}
```

### 2. main.tf (env_content)

```hcl
%{if var.enable_myservice~}
MYSERVICE_API_KEY="${var.myservice_api_key}"
%{endif~}
```

### 3. bootstrap/services/myservice.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

# ... standard header ...

# Create docker-compose.yml
cat > /opt/myservice/docker-compose.yml <<'YAML'
services:
  myservice:
    image: vendor/myservice:latest
    container_name: myservice
    restart: unless-stopped
    env_file: /opt/vps/bootstrap/.env
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    # NO ports: directive!
    networks:
      vpn_net:
        ipv4_address: 10.20.0.XX
    labels:  # Only for web services
      - "traefik.enable=true"
      - "traefik.http.routers.myservice.rule=Host(`myservice.${DOMAIN}`)"
      - "traefik.http.routers.myservice.tls.certresolver=letsencrypt"

networks:
  vpn_net:
    external: true
YAML
```

---

## Network Layout

```
Internet
    │
    ├─ UDP 51820 → WireGuard VPN
    │               └─ 10.100.0.0/24 (VPN clients)
    │
    └─ TCP 443 → Traefik reverse proxy
                  └─ 10.20.0.0/24 (Docker services)

VPN client → 10.100.0.1 (server VPN IP)
           → SSH → docker exec → container
           → Browser → Traefik → container
```

---

## Checklist for New Services

- [ ] Service runs as Docker container
- [ ] No `ports:` directive in docker-compose.yml
- [ ] Web services: Traefik labels configured
- [ ] CLI services: Wrapper script for `docker exec`
- [ ] Credentials via Terraform variables (sensitive = true)
- [ ] Network: `vpn_net` with static IP (10.20.0.XX)
- [ ] Security: `no-new-privileges`, `cap_drop: ALL`
- [ ] Documentation: Section in docs/SERVICES.md

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Installing binary on host | Create Docker image or use existing |
| Using `ports:` | Use Traefik labels or SSH access |
| Config in `~/.config/` | Mount config dir into container |
| Manual credential setup | Add to terraform.tfvars |
| Exposing API endpoint | Use Traefik or SSH tunnel |

---

## File Locations

| Purpose | Path |
|---------|------|
| Terraform config | `terraform.tfvars` |
| Service scripts | `bootstrap/services/*.sh` |
| Environment file | `/opt/vps/bootstrap/.env` |
| Service data | `/opt/<service>/` |
| Docker compose | `/opt/<service>/docker-compose.yml` |
| Traefik config | `/opt/traefik/` |

---

## Questions AI Should Ask

When implementing a new service or modifying existing:

1. **Does it run in Docker?** → If not, containerize it.
2. **Are ports exposed?** → Remove `ports:`, use Traefik/SSH.
3. **How are credentials handled?** → Add to Terraform variables.
4. **Web or CLI access?** → Traefik labels vs docker exec wrapper.
5. **Is documentation updated?** → Update docs/SERVICES.md.
