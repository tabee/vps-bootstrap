# Copilot Custom Instructions for vps-bootstrap

> **Read `docs/ARCHITECTURE.md` before implementing any service changes.**
> It contains the complete architecture reference, patterns, templates and checklists.

## Quick Rules

1. **Everything runs in Docker** on the `vpn_net` network (10.20.0.0/24) with a static IP
2. **NO `ports:` directive** in any docker-compose.yml — ever
3. **Traefik uses file provider** (dynamic.yml patching via Python3), NOT Docker labels
4. **Credentials flow:** `terraform.tfvars` → `variables.tf` → `main.tf env_content` → `bootstrap/.env` → `service .env` → `docker-compose.yml env_file`
5. **Security hardening:** `no-new-privileges: true`, `cap_drop: ["ALL"]` on every container
6. **Idempotency:** Always use `file_matches` before `install_content`
7. **DRY_RUN support:** Every function must check `$DRY_RUN`
8. **Two service types:** Web (Traefik-routed) or CLI (SSH + docker exec)

## Files to Touch When Adding a Service

1. `variables.tf` — add `enable_<name>` + secret variables
2. `main.tf` — add `random_password` + add to `env_content`
3. `bootstrap/apply.sh` — add `ENABLE_<NAME>` flag + `run_service_module` call
4. `bootstrap/services/<name>.sh` — service script (see template in ARCHITECTURE.md)
5. `terraform.tfvars.example` — add example config
6. `outputs.tf` — add to `credentials` and `services` outputs
7. `tests/smoke.sh` — add file existence + syntax tests
8. `docs/SERVICES.md` — add documentation section
9. `docs/README.md` 

## IP Allocation

Used: .10 (Traefik), .20 (whoami), .30-.32 (Gitea+PG+tea), .40-.41 (n8n+PG), .50 (gogcli), .60+.62 (MkDocs nginx+webhook)
Next available: 10.20.0.70+ for new services

## Architecture Reference

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for:
- Complete service script template (~200 lines)
- Traefik dynamic.yml patching pattern
- All library API functions (logging.sh, backup.sh)
- Decision tree for service type selection
- Detailed checklist with every required step
