variable "ssh_host" {
  description = "VPS public IP or DNS name (ignored if create_hcloud_server=true)"
  type        = string
  default     = ""
  validation {
    condition     = var.create_hcloud_server || length(var.ssh_host) > 0
    error_message = "ssh_host is required when create_hcloud_server=false."
  }
}

variable "create_hcloud_server" {
  description = "Create a Hetzner Cloud server automatically"
  type        = bool
  default     = false
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token (server provisioning)"
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = !var.create_hcloud_server || length(var.hcloud_token) > 0
    error_message = "hcloud_token is required when create_hcloud_server=true."
  }
}

variable "hcloud_server_name" {
  description = "Server name"
  type        = string
  default     = "vps"
}

variable "hcloud_server_type" {
  description = "Server type (e.g., cx22)"
  type        = string
  default     = "cx22"
}

variable "hcloud_location" {
  description = "Server location (e.g., nbg1, fsn1, hel1)"
  type        = string
  default     = "nbg1"
}

variable "hcloud_image" {
  description = "OS image (e.g., debian-12)"
  type        = string
  default     = "debian-12"
}

variable "hcloud_ssh_key_name" {
  description = "Name for the SSH key in Hetzner Cloud"
  type        = string
  default     = "bootstrap-key"
}

variable "hcloud_ssh_public_key_path" {
  description = "Path to SSH public key for server access"
  type        = string
  default     = ""
}

variable "hcloud_ssh_public_key" {
  description = "SSH public key content (overrides hcloud_ssh_public_key_path if set)"
  type        = string
  default     = ""
  validation {
    condition     = !var.create_hcloud_server || length(var.hcloud_ssh_public_key) > 0 || length(var.hcloud_ssh_public_key_path) > 0
    error_message = "Provide hcloud_ssh_public_key or hcloud_ssh_public_key_path when create_hcloud_server=true."
  }
}

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

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
  default     = ""
}

variable "ssh_private_key" {
  description = "SSH private key content (overrides ssh_private_key_path if set)"
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = length(var.ssh_private_key) > 0 || length(var.ssh_private_key_path) > 0
    error_message = "Provide ssh_private_key or ssh_private_key_path."
  }
}

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
  description = "Path on server where repo should live"
  type        = string
  default     = "/root/vps-bootstrap"
}

variable "hetzner_api_token" {
  description = "Hetzner Cloud API token (DNS permissions)"
  type        = string
  sensitive   = true
}

variable "vpn_domain" {
  description = "Primary domain (e.g., example.com)"
  type        = string
}

variable "vpn_hostname" {
  description = "Server hostname (defaults to vps)"
  type        = string
  default     = "vps"
}

variable "acme_email" {
  description = "Email for Let's Encrypt"
  type        = string
}

variable "openai_api_key" {
  description = "Optional: OpenAI key for n8n workflows"
  type        = string
  default     = ""
  sensitive   = true
}

variable "dry_run" {
  description = "Run bootstrap in dry-run mode"
  type        = bool
  default     = false
}

variable "module" {
  description = "Run a single bootstrap module (e.g., 04-firewall)"
  type        = string
  default     = ""
}

variable "from" {
  description = "Start bootstrap from module number (e.g., 05)"
  type        = string
  default     = ""
}

variable "skip_preflight" {
  description = "Skip preflight checks"
  type        = bool
  default     = false
}

variable "skip_validation" {
  description = "Skip post-deployment validation"
  type        = bool
  default     = false
}

variable "enable_ssh_lockdown" {
  description = "Run ssh-lockdown after successful apply"
  type        = bool
  default     = false
}

variable "enable_user_lockdown" {
  description = "Run user-lockdown after successful apply"
  type        = bool
  default     = false
}
