# =============================================================================
# VPS Bootstrap - Variables
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# PFLICHT - Ohne diese geht nichts
# ═══════════════════════════════════════════════════════════════════════════

variable "ssh_host" {
  description = "IP-Adresse des Servers (aus Hetzner Console)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Pfad zum SSH Private Key (z.B. ~/.ssh/id_ed25519)"
  type        = string
  default     = ""
}

variable "ssh_private_key" {
  description = "SSH private key content (alternative to path)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "domain" {
  description = "Deine Domain (z.B. example.com)"
  type        = string
}

variable "hetzner_dns_token" {
  description = "Hetzner DNS API Token für Let's Encrypt DNS-01 Challenge"
  type        = string
  sensitive   = true
}

variable "acme_email" {
  description = "E-Mail für Let's Encrypt Benachrichtigungen"
  type        = string
}

# ═══════════════════════════════════════════════════════════════════════════
# SSH OPTIONEN
# ═══════════════════════════════════════════════════════════════════════════

variable "ssh_user" {
  description = "SSH user (e.g., root)"
  type        = string
  default     = "root"
}

variable "ssh_port" {
  description = "SSH port"
  type        = number
  default     = 22
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVICES - Ein/Ausschalten
# ═══════════════════════════════════════════════════════════════════════════

variable "enable_gitea" {
  description = "Git-Server installieren? (git.domain.com)"
  type        = bool
  default     = false
}

variable "enable_n8n" {
  description = "Workflow-Automation installieren? (n8n.domain.com)"
  type        = bool
  default     = false
}

variable "enable_whoami" {
  description = "Test-Service installieren? (whoami.domain.com)"
  type        = bool
  default     = true
}

variable "enable_gogcli" {
  description = "Google Workspace CLI API? (gog.domain.com)"
  type        = bool
  default     = false
}

# ═══════════════════════════════════════════════════════════════════════════
# VPN CLIENTS
# ═══════════════════════════════════════════════════════════════════════════

variable "vpn_clients" {
  description = "Liste der VPN-Clients - entfernte Clients werden gelöscht"
  type        = list(string)
  default     = ["admin"]
}

# ═══════════════════════════════════════════════════════════════════════════
# ADMIN USER
# ═══════════════════════════════════════════════════════════════════════════

variable "admin_user" {
  description = "Username für SSH-Zugang nach Härtung"
  type        = string
  default     = "admin"
}

# ═══════════════════════════════════════════════════════════════════════════
# REPOSITORY
# ═══════════════════════════════════════════════════════════════════════════

variable "git_repo_url" {
  description = "Git repo URL for vps-bootstrap"
  type        = string
  default     = "https://github.com/tabee/vps-bootstrap.git"
}

variable "git_ref" {
  description = "Git ref to deploy (branch, tag, or commit)"
  type        = string
  default     = "main"
}

variable "repo_path" {
  description = "Path on server where repo is cloned"
  type        = string
  default     = "/opt/vps"
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVER OPTIONEN
# ═══════════════════════════════════════════════════════════════════════════

variable "hostname" {
  description = "Server hostname"
  type        = string
  default     = "vps"
}

# ═══════════════════════════════════════════════════════════════════════════
# BOOTSTRAP OPTIONEN
# ═══════════════════════════════════════════════════════════════════════════

variable "skip_harden" {
  description = "Skip final hardening (SSH remains accessible via WAN)"
  type        = bool
  default     = false
}

variable "force_rerun" {
  description = "Force re-run of bootstrap (re-applies all steps)"
  type        = bool
  default     = false
}
