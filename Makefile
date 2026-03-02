# =============================================================================
# Makefile — VPS Bootstrap System
# =============================================================================
# Usage:
#   make apply          Run full bootstrap (requires root)
#   make dry-run        Preview changes without applying
#   make validate       Run post-deployment validation gates
#   make rollback       Interactive rollback to previous state
#   make preflight      Run preflight checks only
#   make module-XX      Run a single module (e.g., make module-04)
#   make lint           Lint all shell scripts
#   make test           Run smoke tests
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

BOOTSTRAP_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))/bootstrap

# ── Main targets ─────────────────────────────────────────────────────────────

.PHONY: add-vpn-client
add-vpn-client: ## Add a new WireGuard client (usage: make add-vpn-client CLIENT=iphone)
	@sudo bash $(BOOTSTRAP_DIR)/scripts/add-vpn-client.sh $(CLIENT)

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "VPS Bootstrap System"
	@echo "===================="
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

.PHONY: setup
setup: ## Interactive setup wizard (recommended for first-time setup)
	@bash $(BOOTSTRAP_DIR)/setup-wizard.sh

.PHONY: init-env
init-env: ## Create .env from .env.example and auto-generate secrets (first run)
	@sudo bash $(BOOTSTRAP_DIR)/init-env.sh

.PHONY: rotate-secrets
rotate-secrets: ## Rotate all auto-generated secrets (WireGuard keys, DB password, Gitea tokens)
	@sudo bash $(BOOTSTRAP_DIR)/init-env.sh --rotate

.PHONY: show-client
show-client: ## Print wg0-client.conf for VPN client setup
	@bash $(BOOTSTRAP_DIR)/init-env.sh --client

.PHONY: ssh-lockdown
ssh-lockdown: ## Restrict SSH to VPN only (run AFTER verifying VPN works!)
	@sudo bash $(BOOTSTRAP_DIR)/ssh-lockdown.sh

.PHONY: user-lockdown
user-lockdown: ## Create admin user and disable root SSH login
	@sudo bash $(BOOTSTRAP_DIR)/user-lockdown.sh

.PHONY: apply
apply: ## Run full bootstrap (requires root)
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh

.PHONY: dry-run
dry-run: ## Preview changes without applying
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --dry-run

.PHONY: validate
validate: ## Run post-deployment validation gates
	@sudo bash -c 'source $(BOOTSTRAP_DIR)/lib/logging.sh && source $(BOOTSTRAP_DIR)/lib/validate.sh && BOOTSTRAP_MODULE=validate && run_all_validations'

.PHONY: status
status: ## Show formatted system status dashboard
	@bash $(BOOTSTRAP_DIR)/status-dashboard.sh

.PHONY: rollback
rollback: ## Interactive rollback to previous state
	@sudo bash $(BOOTSTRAP_DIR)/rollback.sh

.PHONY: preflight
preflight: ## Run preflight checks only
	@sudo bash $(BOOTSTRAP_DIR)/preflight.sh

# ── Module targets ───────────────────────────────────────────────────────────

.PHONY: module-01
module-01: ## Run module 01-system only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 01-system --skip-preflight --skip-validation

.PHONY: module-02
module-02: ## Run module 02-network only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 02-network --skip-preflight --skip-validation

.PHONY: module-03
module-03: ## Run module 03-dns only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 03-dns --skip-preflight --skip-validation

.PHONY: module-04
module-04: ## Run module 04-firewall only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 04-firewall --skip-preflight --skip-validation

.PHONY: module-05
module-05: ## Run module 05-docker only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 05-docker --skip-preflight --skip-validation

.PHONY: module-06
module-06: ## Run module 06-traefik only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 06-traefik --skip-preflight --skip-validation

.PHONY: module-07
module-07: ## Run module 07-gitea only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 07-gitea --skip-preflight --skip-validation

.PHONY: module-08
module-08: ## Run module 08-whoami only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 08-whoami --skip-preflight --skip-validation

.PHONY: module-09
module-09: ## Run module 09-security only
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 09-security --skip-preflight --skip-validation

.PHONY: 8n8
8n8: ## (Optional) Deploy n8n behind Traefik (VPN-only) at https://8n8.$(VPN_DOMAIN)/
	@sudo bash $(BOOTSTRAP_DIR)/apply.sh --module 10-n8n

# ── Backup targets ───────────────────────────────────────────────────────────

.PHONY: backup-data
backup-data: ## Backup application data (Gitea, PostgreSQL, Traefik certs)
	@sudo bash $(BOOTSTRAP_DIR)/backup-data.sh

.PHONY: restore-data
restore-data: ## Restore application data from backup
	@sudo bash $(BOOTSTRAP_DIR)/backup-data.sh --restore

.PHONY: list-backups
list-backups: ## List available data backups
	@sudo bash $(BOOTSTRAP_DIR)/backup-data.sh --list

# ── Snapshot targets ─────────────────────────────────────────────────────────

.PHONY: snapshot
snapshot: ## Create system snapshot for debugging/documentation
	@sudo REPO_ROOT=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))) bash $(BOOTSTRAP_DIR)/snapshot.sh

.PHONY: list-snapshots
list-snapshots: ## List available snapshots
	@echo "Available snapshots:"
	@ls -la snapshot/ 2>/dev/null || echo "  No snapshots found"

# ── Quality targets ──────────────────────────────────────────────────────────

.PHONY: lint
lint: ## Lint all shell scripts with shellcheck
	@echo "Running shellcheck..."
	@find $(BOOTSTRAP_DIR) -name '*.sh' -exec shellcheck -x {} +
	@find tests -name '*.sh' -exec shellcheck -x {} +
	@echo "All scripts pass shellcheck"

.PHONY: test
test: ## Run smoke tests
	@bash tests/smoke.sh
