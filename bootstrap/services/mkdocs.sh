#!/usr/bin/env bash
# =============================================================================
# services/mkdocs.sh — MkDocs Documentation (Sidecar: Webhook/Builder + Nginx)
# =============================================================================
# Deploys:
#   - Nginx (Alpine) at 10.20.0.60 — serves built site
#   - Webhook/Builder at 10.20.0.62 — listens for Gitea push, runs mkdocs build
#
# Also:
#   - Creates "docs" repo in Gitea via API (idempotent)
#   - Pushes initial mkdocs-material structure (idempotent)
#   - Registers Gitea webhook (idempotent)
#   - Triggers first build automatically
#
# Architecture:
#   VPN → Traefik:443 → docs.<domain> → Nginx:8080 (static HTML)
#   Gitea push → Webhook:9000 → git pull + mkdocs build → shared volume
#
# Prerequisites:
#   - Gitea must be running (this module runs AFTER gitea in apply.sh)
#
# Security design:
#   - NO published ports (no `ports:` directive)
#   - Traffic must go through Traefik + vpn-only middleware (ipAllowList)
#   - Webhook validates HMAC-SHA256 signatures
#   - Containers with no-new-privileges + capability drop
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

BOOTSTRAP_MODULE="mkdocs"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

VPN_DOMAIN="${VPN_DOMAIN:-example.com}"
MKDOCS_WEBHOOK_SECRET="${MKDOCS_WEBHOOK_SECRET:-}"
MKDOCS_REPO_BRANCH="${MKDOCS_REPO_BRANCH:-main}"

# Gitea connection (internal Docker network — no Traefik needed)
GITEA_INTERNAL_URL="http://10.20.0.30:3000"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"

# Derived
MKDOCS_REPO_NAME="docs"
MKDOCS_REPO_URL="${GITEA_INTERNAL_URL}/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}.git"
MKDOCS_WEBHOOK_INTERNAL_URL="http://10.20.0.62:9000/webhook"

MKDOCS_DIR="/opt/mkdocs"
TRAEFIK_DYNAMIC="/opt/traefik/dynamic.yml"
TRAEFIK_ACME_STATE_FILE="/opt/traefik/.acme-active"

traefik_https_tls_block() {
  if [[ -f "$TRAEFIK_ACME_STATE_FILE" ]] && grep -qx 'true' "$TRAEFIK_ACME_STATE_FILE"; then
    cat <<'YAML'
      tls:
        certResolver: le
YAML
  else
    echo '      tls: {}'
  fi
}

# ── Create directory structure ───────────────────────────────────────────────
setup_directories() {
  log_step "Creating mkdocs directory structure"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create $MKDOCS_DIR"
    return 0
  fi

  mkdir -p "${MKDOCS_DIR}"
  log_info "Created $MKDOCS_DIR"
}

# ── Generate Nginx config ───────────────────────────────────────────────────
install_nginx_config() {
  log_step "Installing mkdocs nginx.conf"

  local nginx_file="${MKDOCS_DIR}/nginx.conf"

  local content
  content='server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /healthz {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}'

  if file_matches "$nginx_file" "$content"; then
    log_info "nginx.conf already up to date"
    return 0
  fi

  install_content "$content" "$nginx_file" "0644"
}

# ── Generate webhook.py (builder) ────────────────────────────────────────────
install_webhook_script() {
  log_step "Installing webhook.py"

  local webhook_file="${MKDOCS_DIR}/webhook.py"

  local content
  content='#!/usr/bin/env python3
"""
Gitea webhook receiver + mkdocs builder.
- Listens on :9000
- Validates HMAC-SHA256 signature
- git clone/pull + mkdocs build into shared volume
- Initial build on startup
"""
import hashlib
import hmac
import http.server
import json
import os
import shutil
import subprocess
import sys
import threading

SECRET = os.environ.get("MKDOCS_WEBHOOK_SECRET", "")
REPO_URL = os.environ.get("MKDOCS_REPO_URL", "")
BRANCH = os.environ.get("MKDOCS_REPO_BRANCH", "main")
GITEA_USER = os.environ.get("GITEA_ADMIN_USER", "")
GITEA_PASS = os.environ.get("GITEA_ADMIN_PASSWORD", "")
REPO_DIR = "/workspace/repo"
SITE_DIR = "/workspace/site"
BUILD_LOCK = threading.Lock()


def git_url_with_auth(url):
    """Inject credentials into git URL for private repos."""
    if GITEA_USER and GITEA_PASS and "://" in url:
        proto, rest = url.split("://", 1)
        return f"{proto}://{GITEA_USER}:{GITEA_PASS}@{rest}"
    return url


def verify_signature(payload: bytes, signature: str) -> bool:
    if not SECRET:
        return True
    expected = hmac.new(SECRET.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def rebuild():
    """Clone/pull and build. Thread-safe."""
    if not BUILD_LOCK.acquire(blocking=False):
        print("[builder] Build already in progress, skipping", flush=True)
        return
    try:
        auth_url = git_url_with_auth(REPO_URL)
        if os.path.exists(os.path.join(REPO_DIR, ".git")):
            print(f"[builder] Pulling {BRANCH}...", flush=True)
            subprocess.run(
                ["git", "-C", REPO_DIR, "fetch", "origin"],
                check=True, capture_output=True, text=True,
            )
            subprocess.run(
                ["git", "-C", REPO_DIR, "reset", "--hard", f"origin/{BRANCH}"],
                check=True, capture_output=True, text=True,
            )
        else:
            print(f"[builder] Cloning {BRANCH}...", flush=True)
            os.makedirs(REPO_DIR, exist_ok=True)
            subprocess.run(
                ["git", "clone", "-b", BRANCH, "--single-branch", auth_url, REPO_DIR],
                check=True, capture_output=True, text=True,
            )

        # Build into temp dir, then swap atomically
        tmp_site = SITE_DIR + ".tmp"
        if os.path.exists(tmp_site):
            shutil.rmtree(tmp_site)

        subprocess.run(
            ["python3", "-m", "mkdocs", "build", "--strict", "--site-dir", tmp_site],
            cwd=REPO_DIR, check=True,
        )

        # Atomic swap: rename old, rename new, remove old
        old_site = SITE_DIR + ".old"
        if os.path.exists(old_site):
            shutil.rmtree(old_site)
        if os.path.exists(SITE_DIR):
            os.rename(SITE_DIR, old_site)
        os.rename(tmp_site, SITE_DIR)
        if os.path.exists(old_site):
            shutil.rmtree(old_site)

        print(f"[builder] Build complete -> {SITE_DIR}", flush=True)
    except subprocess.CalledProcessError as e:
        print(f"[builder] Build FAILED: {e}", file=sys.stderr, flush=True)
        if hasattr(e, "stderr") and e.stderr:
            print(f"[builder] stderr: {e.stderr}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[builder] Build FAILED: {e}", file=sys.stderr, flush=True)
    finally:
        BUILD_LOCK.release()


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length)
        signature = self.headers.get("X-Gitea-Signature", "")

        if not verify_signature(payload, signature):
            print("[webhook] Invalid signature", flush=True)
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b"Invalid signature")
            return

        # Branch filter
        try:
            data = json.loads(payload)
            ref = data.get("ref", "")
            if ref and ref != f"refs/heads/{BRANCH}":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Skipped: wrong branch")
                return
        except (json.JSONDecodeError, KeyError):
            pass

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Build triggered")

        # Build in background thread so response returns immediately
        threading.Thread(target=rebuild, daemon=True).start()

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        print(f"[webhook] {args[0]}", flush=True)


if __name__ == "__main__":
    # Initial build on startup
    print("[builder] Initial build on startup...", flush=True)
    rebuild()

    server = http.server.HTTPServer(("0.0.0.0", 9000), WebhookHandler)
    print("[webhook] Listening on :9000", flush=True)
    server.serve_forever()'

  if file_matches "$webhook_file" "$content"; then
    log_info "webhook.py already up to date"
    return 0
  fi

  install_content "$content" "$webhook_file" "0755"
}

# ── Generate Dockerfile for builder ─────────────────────────────────────────
install_dockerfile() {
  log_step "Installing mkdocs Dockerfile.builder"

  local dockerfile="${MKDOCS_DIR}/Dockerfile.builder"

  local content
  content='FROM python:3.12-alpine

RUN apk add --no-cache git openssh-client && \
    pip install --no-cache-dir mkdocs-material

RUN adduser -D -u 1000 mkdocs && \
    mkdir -p /workspace/site /workspace/repo && \
    chown -R mkdocs:mkdocs /workspace

COPY --chown=mkdocs:mkdocs webhook.py /app/webhook.py

USER mkdocs
WORKDIR /workspace

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('"'"'http://127.0.0.1:9000/healthz'"'"')"

CMD ["python3", "/app/webhook.py"]'

  if file_matches "$dockerfile" "$content"; then
    log_info "Dockerfile.builder already up to date"
    return 0
  fi

  install_content "$content" "$dockerfile" "0644"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────────
install_compose_file() {
  log_step "Installing mkdocs docker-compose.yml"

  local compose_file="${MKDOCS_DIR}/docker-compose.yml"

  local content
  content="$(cat <<'YAML'
# =============================================================================
# docker-compose.yml — MkDocs (Nginx + Webhook/Builder)
# =============================================================================
# NO ports: directive — accessible only via Traefik (10.20.0.10).
# Webhook container builds docs into shared volume, Nginx serves them.

services:
  mkdocs-webhook:
    build:
      context: .
      dockerfile: Dockerfile.builder
    image: mkdocs-builder:local
    container_name: mkdocs-webhook
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    env_file: .env
    volumes:
      - site_data:/workspace/site
      - repo_data:/workspace/repo
    networks:
      vpn_net:
        ipv4_address: 10.20.0.62

  mkdocs-nginx:
    image: nginx:alpine
    container_name: mkdocs-nginx
    restart: unless-stopped
    depends_on:
      mkdocs-webhook:
        condition: service_started
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
    volumes:
      - site_data:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    networks:
      vpn_net:
        ipv4_address: 10.20.0.60

volumes:
  site_data:
  repo_data:

networks:
  vpn_net:
    external: true
YAML
)"

  if file_matches "$compose_file" "$content"; then
    log_info "docker-compose.yml already up to date"
    return 0
  fi

  install_content "$content" "$compose_file" "0644"
}

# ── Generate .env file ──────────────────────────────────────────────────────
install_env_file() {
  log_step "Installing mkdocs .env file"

  local env_file="${MKDOCS_DIR}/.env"

  if [[ -z "$MKDOCS_WEBHOOK_SECRET" ]]; then
    log_warn "MKDOCS_WEBHOOK_SECRET not set — generating random secret"
    MKDOCS_WEBHOOK_SECRET=$(openssl rand -hex 16)
  fi

  local content
  content="$(cat <<EOF
# MkDocs Builder Environment
VPN_DOMAIN=${VPN_DOMAIN}
MKDOCS_REPO_URL=${MKDOCS_REPO_URL}
MKDOCS_REPO_BRANCH=${MKDOCS_REPO_BRANCH}
MKDOCS_WEBHOOK_SECRET=${MKDOCS_WEBHOOK_SECRET}
GITEA_ADMIN_USER=${GITEA_ADMIN_USER}
GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD}
EOF
)"

  if file_matches "$env_file" "$content"; then
    log_info ".env already up to date"
    return 0
  fi

  install_content "$content" "$env_file" "0600"
}

# ── Patch Traefik dynamic.yml ───────────────────────────────────────────────
patch_traefik_routes() {
  log_step "Ensuring Traefik route exists for docs.${VPN_DOMAIN}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would patch ${TRAEFIK_DYNAMIC}"
    return 0
  fi

  if [[ ! -f "$TRAEFIK_DYNAMIC" ]]; then
    log_fatal "Traefik dynamic config not found at ${TRAEFIK_DYNAMIC}. Run core/05-traefik first."
  fi

  # Idempotency: do nothing if router already exists
  if grep -qE '^\s*mkdocs:\s*$' "$TRAEFIK_DYNAMIC"; then
    log_info "Traefik router 'mkdocs' already present"
    return 0
  fi

  local tls_block
  tls_block="$(traefik_https_tls_block)"

  VPN_DOMAIN="$VPN_DOMAIN" TRAEFIK_DYNAMIC="$TRAEFIK_DYNAMIC" TLS_BLOCK="$tls_block" python3 - <<'PY'
from pathlib import Path
import os

vpn_domain = os.environ["VPN_DOMAIN"]
path = os.environ["TRAEFIK_DYNAMIC"]
tls_block = os.environ["TLS_BLOCK"]
p = Path(path)
text = p.read_text(encoding="utf-8")

router_snip = f"""

    # MkDocs documentation site
    mkdocs:
      entryPoints: ["websecure"]
      rule: "Host(`docs.{vpn_domain}`)"
      middlewares: ["vpn-only"]
      service: mkdocs-svc
{tls_block}
"""

service_snip = """

    mkdocs-svc:
      loadBalancer:
        servers:
          - url: "http://10.20.0.60:8080"
"""

if "\n    mkdocs:\n" in text or "\n    mkdocs-svc:\n" in text:
    # Already patched. Keep idempotent.
    p.write_text(text, encoding="utf-8")
    raise SystemExit(0)

needle_services = "\n  services:\n"
if needle_services not in text:
    raise SystemExit("Could not find 'http.services' section in Traefik dynamic.yml")

text = text.replace(needle_services, router_snip + needle_services, 1)

needle_tcp = "\n# ── TCP routers"
if needle_tcp not in text:
    needle_tcp = "\ntcp:\n"
    if needle_tcp not in text:
        raise SystemExit("Could not find tcp section in Traefik dynamic.yml")
    text = text.replace(needle_tcp, service_snip + needle_tcp, 1)
else:
    text = text.replace(needle_tcp, service_snip + needle_tcp, 1)

p.write_text(text, encoding="utf-8")
PY

  chmod 0644 "$TRAEFIK_DYNAMIC"

  log_info "✅ Added Traefik router+service for docs.${VPN_DOMAIN}"
}

# ── Deploy mkdocs stack ─────────────────────────────────────────────────────
deploy_mkdocs() {
  log_step "Deploying mkdocs stack"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would deploy mkdocs via docker compose"
    return 0
  fi

  cd "${MKDOCS_DIR}"

  # Build the webhook/builder image
  log_info "Building mkdocs-builder image..."
  docker build --network=host -t mkdocs-builder:local --quiet -f Dockerfile.builder .

  docker compose up -d --remove-orphans

  # Wait for webhook to be ready
  log_info "Waiting for mkdocs-webhook container..."
  local i=0
  while [[ $i -lt 60 ]]; do
    if docker ps --filter "name=mkdocs-webhook" --filter "status=running" --format '{{.Names}}' | grep -q '^mkdocs-webhook$'; then
      log_info "mkdocs-webhook container is running"
      break
    fi
    sleep 2
    i=$((i + 2))
  done

  # Wait for nginx
  i=0
  while [[ $i -lt 30 ]]; do
    if docker ps --filter "name=mkdocs-nginx" --filter "status=running" --format '{{.Names}}' | grep -q '^mkdocs-nginx$'; then
      log_info "mkdocs-nginx container is running"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  log_warn "mkdocs containers may not be fully started yet"
}

# ── Create docs repo in Gitea ───────────────────────────────────────────────
create_gitea_repo() {
  log_step "Ensuring Gitea 'docs' repository exists"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would create Gitea repo '${MKDOCS_REPO_NAME}'"
    return 0
  fi

  if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_warn "GITEA_ADMIN_PASSWORD not set — skipping repo creation"
    return 0
  fi

  # Wait for Gitea API to be ready
  log_info "Waiting for Gitea API..."
  local i=0
  while [[ $i -lt 120 ]]; do
    if docker exec gitea curl -sf http://localhost:3000/api/v1/settings/api >/dev/null 2>&1; then
      break
    fi
    sleep 3
    i=$((i + 3))
  done

  # Check if repo already exists
  if docker exec gitea curl -sf \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}" >/dev/null 2>&1; then
    log_info "Repository '${MKDOCS_REPO_NAME}' already exists"
    return 0
  fi

  # Create repo via Gitea API
  log_info "Creating repository '${MKDOCS_REPO_NAME}'..."
  docker exec gitea curl -sf \
    -X POST \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${MKDOCS_REPO_NAME}\",
      \"description\": \"Project documentation (MkDocs Material)\",
      \"private\": true,
      \"auto_init\": true,
      \"default_branch\": \"${MKDOCS_REPO_BRANCH}\"
    }" \
    "http://localhost:3000/api/v1/user/repos" >/dev/null 2>&1 || {
      log_warn "Repository creation failed (may already exist)"
      return 0
    }

  sleep 2
  log_info "Repository '${MKDOCS_REPO_NAME}' created"
}

# ── Push initial mkdocs structure ────────────────────────────────────────────
push_initial_docs() {
  log_step "Ensuring initial mkdocs structure in repo"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would push initial mkdocs structure"
    return 0
  fi

  if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_warn "GITEA_ADMIN_PASSWORD not set — skipping initial docs push"
    return 0
  fi

  # Check if mkdocs.yml already exists in repo
  if docker exec gitea curl -sf \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}/contents/mkdocs.yml" >/dev/null 2>&1; then
    log_info "mkdocs.yml already exists in repo — skipping initial push"
    return 0
  fi

  log_info "Pushing initial mkdocs-material structure..."

  local tmpdir
  tmpdir="$(mktemp -d)"

  (
    cd "$tmpdir"
    git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}@10.20.0.30:3000/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}.git" repo
    cd repo

    git config user.email "${GITEA_ADMIN_USER}@${VPN_DOMAIN}"
    git config user.name "Bootstrap"

    # --- mkdocs.yml ---
    cat > mkdocs.yml << 'MKYML'
site_name: VPS Documentation
site_description: Internal project documentation
site_url: ""

theme:
  name: material
  palette:
    - scheme: slate
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-4
        name: Switch to light mode
    - scheme: default
      primary: indigo
      accent: indigo
      toggle:
        icon: material/brightness-7
        name: Switch to dark mode
  features:
    - navigation.instant
    - navigation.tabs
    - navigation.sections
    - navigation.expand
    - navigation.top
    - search.suggest
    - search.highlight
    - content.code.copy
    - content.code.annotate

markdown_extensions:
  - admonition
  - pymdownx.details
  - pymdownx.superfences
  - pymdownx.highlight:
      anchor_linenums: true
  - pymdownx.inlinehilite
  - pymdownx.tabbed:
      alternate_style: true
  - pymdownx.tasklist:
      custom_checkbox: true
  - attr_list
  - md_in_html
  - toc:
      permalink: true

nav:
  - Home: index.md
  - Architecture: architecture.md
  - Services:
      - Overview: services/index.md
      - Traefik: services/traefik.md
      - Gitea: services/gitea.md
      - n8n: services/n8n.md
  - Operations:
      - Deployment: ops/deployment.md
      - Backup: ops/backup.md
MKYML

    # --- docs/ directory ---
    mkdir -p docs/services docs/ops

    cat > docs/index.md << 'MDEOF'
# VPS Documentation

Welcome to the internal documentation for the VPS infrastructure.

## Quick Links

- [Architecture Overview](architecture.md) — System design and network layout
- [Services](services/index.md) — All deployed services
- [Deployment](ops/deployment.md) — How to deploy and update

## Network Layout

| IP | Service |
|---|---|
| 10.20.0.10 | Traefik (reverse proxy) |
| 10.20.0.20 | whoami (health check) |
| 10.20.0.30-32 | Gitea + PostgreSQL + tea CLI |
| 10.20.0.40-41 | n8n + PostgreSQL |
| 10.20.0.50 | gogcli |
| 10.20.0.60 | Docs (this site) |
| 10.20.0.62 | Docs builder (webhook) |
MDEOF

    cat > docs/architecture.md << 'MDEOF'
# Architecture

## Overview

The VPS runs on Debian 12 with WireGuard VPN as the only public-facing service.
All application services are Docker containers on the `vpn_net` network (10.20.0.0/24)
with static IPs. Traefik handles TLS termination and routing via file provider.

## Security Model

- **Only UDP/51820 (WireGuard)** is exposed to the internet
- All other access requires VPN connection
- Docker's iptables is disabled — nftables has full control
- Traefik uses file provider (no Docker socket access)
- All containers: `no-new-privileges`, `cap_drop: ALL`
MDEOF

    cat > docs/services/index.md << 'MDEOF'
# Services Overview

All services run as Docker containers with:

- Static IP on `vpn_net` (10.20.0.0/24)
- `no-new-privileges` security option
- `cap_drop: ALL`
- No exposed ports (Traefik-routed or CLI-only)

## Web Services (via Traefik)

| Service | URL | IP |
|---|---|---|
| whoami | `https://whoami.<domain>` | 10.20.0.20 |
| Gitea | `https://git.<domain>` | 10.20.0.30 |
| n8n | `https://8n8.<domain>` | 10.20.0.40 |
| Docs | `https://docs.<domain>` | 10.20.0.60 |

## CLI Services (via SSH + docker exec)

| Service | Command | IP |
|---|---|---|
| gogcli | `gog <cmd>` | 10.20.0.50 |
| tea CLI | `tea <cmd>` | 10.20.0.32 |
MDEOF

    cat > docs/services/traefik.md << 'MDEOF'
# Traefik

Reverse proxy and TLS termination. Uses **file provider** (`dynamic.yml`), not Docker labels.

- **IP:** 10.20.0.10
- **Ports:** 443 (HTTPS), 2222 (Git SSH passthrough)
- **Config:** `/opt/traefik/`
- **Dashboard:** Disabled (security)
MDEOF

    cat > docs/services/gitea.md << 'MDEOF'
# Gitea

Git hosting with PostgreSQL backend and tea CLI sidecar.

- **IP:** 10.20.0.30 (Gitea), .31 (PostgreSQL), .32 (tea CLI)
- **URL:** `https://git.<domain>`
- **SSH:** `ssh://git@<domain>:2222/<user>/<repo>.git`
- **Config:** `/opt/gitea/`
MDEOF

    cat > docs/services/n8n.md << 'MDEOF'
# n8n

Workflow automation with PostgreSQL backend.

- **IP:** 10.20.0.40 (n8n), .41 (PostgreSQL)
- **URL:** `https://8n8.<domain>`
- **Config:** `/opt/n8n/`
MDEOF

    cat > docs/ops/deployment.md << 'MDEOF'
# Deployment

## Initial Deployment

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

## Re-Deployment

```bash
terraform apply
```

The bootstrap script is idempotent and can be re-run safely.

## Updating Documentation

Edit files in the `docs` Gitea repository. Changes are automatically
built and deployed via webhook on push.
MDEOF

    cat > docs/ops/backup.md << 'MDEOF'
# Backup

## Service Data Locations

| Service | Data | Path |
|---|---|---|
| Gitea | Repos + DB | `/opt/gitea/` |
| n8n | Workflows + DB | `/opt/n8n/` |
| Traefik | Certs | `/opt/traefik/letsencrypt/` |
| WireGuard | Keys | `/etc/wireguard/` |

## Bootstrap Backups

The bootstrap system creates timestamped backups before modifying files:

```bash
ls /var/backups/bootstrap/
```
MDEOF

    git add -A
    git commit -m "Initial mkdocs-material documentation structure"
    git push origin "${MKDOCS_REPO_BRANCH}"
  )

  rm -rf "$tmpdir"
  log_info "✅ Initial docs structure pushed to Gitea"
}

# ── Register Gitea webhook ──────────────────────────────────────────────────
register_webhook() {
  log_step "Ensuring Gitea webhook is configured for docs repo"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would register Gitea webhook"
    return 0
  fi

  if [[ -z "$GITEA_ADMIN_PASSWORD" ]]; then
    log_warn "GITEA_ADMIN_PASSWORD not set — skipping webhook registration"
    return 0
  fi

  # Check if webhook already exists (look for our URL in existing hooks)
  local existing_hooks
  existing_hooks=$(docker exec gitea curl -sf \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}/hooks" 2>/dev/null || echo "[]")

  if echo "$existing_hooks" | grep -q "10.20.0.62:9000"; then
    log_info "Webhook already registered"
    return 0
  fi

  # Register webhook
  log_info "Registering webhook for docs repo..."
  docker exec gitea curl -sf \
    -X POST \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"gitea\",
      \"active\": true,
      \"events\": [\"push\"],
      \"config\": {
        \"url\": \"${MKDOCS_WEBHOOK_INTERNAL_URL}\",
        \"content_type\": \"json\",
        \"secret\": \"${MKDOCS_WEBHOOK_SECRET}\"
      }
    }" \
    "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}/hooks" >/dev/null 2>&1 || {
      log_warn "Webhook registration failed"
      return 0
    }

  log_info "✅ Webhook registered"
}

# ── Trigger first build ─────────────────────────────────────────────────────
trigger_first_build() {
  log_step "Triggering initial documentation build"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would trigger initial build"
    return 0
  fi

  # Wait for webhook to be listening
  local i=0
  while [[ $i -lt 30 ]]; do
    if docker exec mkdocs-webhook python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9000/healthz')" 2>/dev/null; then
      break
    fi
    sleep 2
    i=$((i + 2))
  done

  # Send a webhook-style POST to trigger the build
  local payload='{"ref":"refs/heads/'"${MKDOCS_REPO_BRANCH}"'"}'

  local hmac_sig
  hmac_sig=$(printf '%s' "$payload" | python3 -c "
import hmac, hashlib, sys
print(hmac.new('${MKDOCS_WEBHOOK_SECRET}'.encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())
")

  docker exec mkdocs-webhook python3 -c "
import urllib.request, sys
req = urllib.request.Request(
    'http://127.0.0.1:9000/webhook',
    data=b'${payload}',
    headers={
        'Content-Type': 'application/json',
        'X-Gitea-Signature': '${hmac_sig}'
    },
    method='POST'
)
try:
    resp = urllib.request.urlopen(req, timeout=5)
    print(resp.read().decode())
except Exception as e:
    print(f'Trigger failed: {e}', file=sys.stderr)
" 2>&1 && log_info "Build triggered successfully" \
       || log_warn "Could not trigger build — it will build on next git push"

  # Wait for build to complete (max 120s for first build which needs pip install)
  log_info "Waiting for initial build to complete..."
  i=0
  while [[ $i -lt 60 ]]; do
    if docker exec mkdocs-nginx wget -q -O /dev/null "http://127.0.0.1:8080/" 2>/dev/null; then
      local page_content
      page_content=$(docker exec mkdocs-nginx cat /usr/share/nginx/html/index.html 2>/dev/null || echo "")
      if echo "$page_content" | grep -qi "mkdocs\|documentation\|VPS" 2>/dev/null; then
        log_info "✅ Documentation site is live!"
        return 0
      fi
    fi
    sleep 2
    i=$((i + 2))
  done

  log_warn "Initial build may still be in progress — check: docker logs mkdocs-webhook"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  module_start "$BOOTSTRAP_MODULE"
  require_root

  setup_directories
  install_nginx_config
  install_webhook_script
  install_dockerfile
  install_compose_file
  install_env_file
  patch_traefik_routes
  deploy_mkdocs
  create_gitea_repo
  push_initial_docs
  register_webhook
  trigger_first_build

  log_info "  Site:    https://docs.${VPN_DOMAIN}"
  log_info "  Repo:    https://git.${VPN_DOMAIN}/${GITEA_ADMIN_USER}/${MKDOCS_REPO_NAME}"
  log_info "  Webhook: internal → http://10.20.0.62:9000/webhook"

  module_done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
