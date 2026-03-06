# =============================================================================
# VPS Bootstrap - Variables
# =============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# REQUIRED - Must be set
# ═══════════════════════════════════════════════════════════════════════════

variable "ssh_host" {
  description = "Server IP address (from Hetzner Console)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.ssh_host)) || can(regex("^[a-z0-9][a-z0-9.-]+$", var.ssh_host))
    error_message = "ssh_host must be a valid IPv4 address or hostname."
  }
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key (e.g. ~/.ssh/id_ed25519)"
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
  description = "Your domain (e.g. example.com)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*\\.[a-z]{2,}$", var.domain))
    error_message = "domain must be a valid domain name (e.g. example.com)."
  }
}

variable "hetzner_dns_token" {
  description = "Hetzner DNS API token for Let's Encrypt DNS-01 challenge"
  type        = string
  sensitive   = true
}

variable "acme_email" {
  description = "Email for Let's Encrypt notifications"
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.acme_email))
    error_message = "acme_email must be a valid email address."
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# SSH OPTIONS
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

  validation {
    condition     = var.ssh_port > 0 && var.ssh_port < 65536
    error_message = "ssh_port must be between 1 and 65535."
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# SERVICES - Enable/Disable
# ═══════════════════════════════════════════════════════════════════════════

variable "enable_gitea" {
  description = "Install Git server? (git.domain.com)"
  type        = bool
  default     = false
}

variable "enable_n8n" {
  description = "Install workflow automation? (n8n.domain.com)"
  type        = bool
  default     = false
}

variable "enable_whoami" {
  description = "Install test service? (whoami.domain.com)"
  type        = bool
  default     = true
}

variable "enable_gogcli" {
  description = "Install Google Workspace CLI? (Docker, SSH access only)"
  type        = bool
  default     = false
}

variable "enable_uptime_kuma" {
  description = "Install Uptime Kuma monitoring service? (Docker, Traefik access at status.domain.com)"
  type        = bool
  default     = false
}

# ═══════════════════════════════════════════════════════════════════════════
# GOGCLI - Google OAuth Credentials (optional, can be set later manually)
# ═══════════════════════════════════════════════════════════════════════════

variable "google_client_id" {
  description = "Google OAuth Client ID (from console.cloud.google.com/apis/credentials)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "google_client_secret" {
  description = "Google OAuth Client Secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "google_project_id" {
  description = "Google Cloud Project ID"
  type        = string
  default     = ""
}

# ═══════════════════════════════════════════════════════════════════════════
# VPN CLIENTS
# ═══════════════════════════════════════════════════════════════════════════

variable "vpn_clients" {
  description = "List of VPN clients - removed clients will be deleted"
  type        = list(string)
  default     = ["admin"]
}

# ═══════════════════════════════════════════════════════════════════════════
# ADMIN USER
# ═══════════════════════════════════════════════════════════════════════════

variable "admin_user" {
  description = "Username for SSH access after hardening"
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
# SERVER OPTIONS
# ═══════════════════════════════════════════════════════════════════════════

variable "hostname" {
  description = "Server hostname"
  type        = string
  default     = "vps"
}

# ═══════════════════════════════════════════════════════════════════════════
# BOOTSTRAP OPTIONS
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

variable "use_vpn" {
  description = "Connect via VPN (set to true after initial deployment with hardening)"
  type        = bool
  default     = false
}
