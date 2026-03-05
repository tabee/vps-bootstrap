# =============================================================================
# VPS Bootstrap - Outputs
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# ZUGANG - Das brauchst du nach der Installation
# ═══════════════════════════════════════════════════════════════════════════

output "access" {
  description = "Zugangsdaten nach Installation"
  sensitive   = true
  value = {
    ssh = {
      hint       = "Nach Härtung nur über VPN erreichbar!"
      command    = "ssh ${var.admin_user}@10.100.0.1"
      vpn_ip     = "10.100.0.1"
      sudo       = "sudo -i (passwortlos)"
    }
    vpn = {
      clients = var.vpn_clients
      config_cmd = "ssh root@${var.ssh_host} 'cat /etc/wireguard/clients/admin/client.conf'"
      qr_cmd     = "ssh root@${var.ssh_host} 'cat /etc/wireguard/clients/admin/qr.txt'"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# CREDENTIALS - Alle generierten Passwörter
# ═══════════════════════════════════════════════════════════════════════════

output "credentials" {
  description = "Alle generierten Zugangsdaten (sicher aufbewahren!)"
  sensitive   = true
  value = {
    gitea = var.enable_gitea ? {
      url         = "https://git.${var.domain}"
      db_password = random_password.gitea_db[0].result
      secret_key  = random_password.gitea_secret[0].result
    } : null

    n8n = var.enable_n8n ? {
      url            = "https://n8n.${var.domain}"
      db_password    = random_password.n8n_db[0].result
      encryption_key = random_password.n8n_encryption[0].result
    } : null

    gogcli = var.enable_gogcli ? {
      access   = "ssh ${var.admin_user}@10.100.0.1 'gog <command>'"
      config   = "/opt/gogcli"
      note     = "Requires Google OAuth setup - see README"
    } : null
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVICES - URLs aller installierten Dienste
# ═══════════════════════════════════════════════════════════════════════════

output "services" {
  description = "Installierte Services (nur über VPN erreichbar)"
  value = {
    gitea  = var.enable_gitea ? "https://git.${var.domain}" : null
    n8n    = var.enable_n8n ? "https://n8n.${var.domain}" : null
    whoami = var.enable_whoami ? "https://whoami.${var.domain}" : null
    gogcli = var.enable_gogcli ? "ssh ${var.admin_user}@10.100.0.1 'gog <command>'" : null
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# QUICK COMMANDS
# ═══════════════════════════════════════════════════════════════════════════

output "quick_commands" {
  description = "Nützliche Befehle"
  value = {
    vpn_config = "terraform output -json access | jq -r '.vpn.config_cmd' | bash"
    vpn_qr     = "terraform output -json access | jq -r '.vpn.qr_cmd' | bash"
    ssh_vpn    = "ssh ${var.admin_user}@10.100.0.1"
    all_creds  = "terraform output -json credentials | jq"
  }
}
