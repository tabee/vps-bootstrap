# =============================================================================
# VPS Bootstrap - Outputs
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# ACCESS - Connection info after installation
# ═══════════════════════════════════════════════════════════════════════════

output "access" {
  description = "Access credentials after installation"
  sensitive   = true
  value = {
    ssh = {
      hint    = "After hardening only accessible via VPN!"
      command = "ssh ${var.admin_user}@${local.vpn_server_ip}"
      vpn_ip  = local.vpn_server_ip
      sudo    = "sudo -i (passwordless)"
    }
    vpn = {
      clients    = var.vpn_clients
      config_cmd = "ssh root@${var.ssh_host} 'cat /etc/wireguard/clients/admin/client.conf'"
      qr_cmd     = "ssh root@${var.ssh_host} 'cat /etc/wireguard/clients/admin/qr.txt'"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# CREDENTIALS - All generated passwords
# ═══════════════════════════════════════════════════════════════════════════

output "credentials" {
  description = "All generated credentials (store securely!)"
  sensitive   = true
  value = {
    gitea = var.enable_gitea ? {
      url            = "https://git.${var.domain}"
      admin_user     = var.gitea_admin_user
      admin_password = var.gitea_admin_password != "" ? var.gitea_admin_password : random_password.gitea_admin_password[0].result
      db_password    = random_password.gitea_db[0].result
      secret_key     = random_password.gitea_secret[0].result
      internal_token = random_password.gitea_internal_token[0].result
      tea_cli        = "ssh user@${local.vpn_server_ip} 'tea <command>'"
      psql_cli       = "ssh user@${local.vpn_server_ip} 'psql-gitea <query>'"
    } : null

    n8n = var.enable_n8n ? {
      url            = "https://n8n.${var.domain}"
      admin_email    = var.n8n_admin_email
      admin_password = var.n8n_admin_password != "" ? var.n8n_admin_password : random_password.n8n_admin_password[0].result
      db_password    = random_password.n8n_db[0].result
      encryption_key = random_password.n8n_encryption[0].result
      n8n_cli        = "ssh user@${local.vpn_server_ip} 'n8n <command>'"
      psql_cli       = "ssh user@${local.vpn_server_ip} 'psql-n8n <query>'"
    } : null

    gogcli = var.enable_gogcli ? {
      access = "ssh ${var.admin_user}@${local.vpn_server_ip} 'gog <command>'"
      config = "/opt/gogcli"
      note   = "Requires Google OAuth setup - see README"
    } : null

    mkdocs = var.enable_mkdocs ? {
      url            = "https://docs.${var.domain}"
      repo           = "https://git.${var.domain}/${var.gitea_admin_user}/docs"
      webhook_secret = var.mkdocs_webhook_secret != "" ? var.mkdocs_webhook_secret : random_password.mkdocs_webhook_secret[0].result
    } : null

    kuma = var.enable_kuma ? {
      url  = "https://status.${var.domain}"
      note = "Create admin account on first visit"
    } : null
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVICES - URLs of installed services
# ═══════════════════════════════════════════════════════════════════════════

output "services" {
  description = "Installed services (only accessible via VPN)"
  value = {
    # Web services (Traefik)
    gitea  = var.enable_gitea ? "https://git.${var.domain}" : null
    n8n    = var.enable_n8n ? "https://n8n.${var.domain}" : null
    whoami = var.enable_whoami ? "https://whoami.${var.domain}" : null
    mkdocs = var.enable_mkdocs ? "https://docs.${var.domain}" : null
    kuma   = var.enable_kuma ? "https://status.${var.domain}" : null

    # CLI tools (SSH + docker exec)
    tea_cli        = var.enable_gitea ? "ssh user@${local.vpn_server_ip} tea <command>" : null
    psql_gitea_cli = var.enable_gitea ? "ssh user@${local.vpn_server_ip} psql-gitea <query>" : null
    n8n_cli        = var.enable_n8n ? "ssh user@${local.vpn_server_ip} n8n <command>" : null
    psql_n8n_cli   = var.enable_n8n ? "ssh user@${local.vpn_server_ip} psql-n8n <query>" : null
    gogcli         = var.enable_gogcli ? "ssh user@${local.vpn_server_ip} gog <command>" : null
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# QUICK COMMANDS
# ═══════════════════════════════════════════════════════════════════════════

output "quick_commands" {
  description = "Useful commands"
  value = {
    vpn_config = "terraform output -json access | jq -r '.vpn.config_cmd' | bash"
    vpn_qr     = "terraform output -json access | jq -r '.vpn.qr_cmd' | bash"
    ssh_vpn    = "ssh ${var.admin_user}@${local.vpn_server_ip}"
    all_creds  = "terraform output -json credentials | jq"
  }
}
