variable "ssh_host" { type = string }
variable "ssh_user" { type = string }
variable "ssh_port" { type = number }
variable "ssh_private_key_path" { type = string }
variable "ssh_private_key" { type = string }

variable "git_repo_url" { type = string }
variable "git_ref" { type = string }
variable "repo_path" { type = string }

variable "hetzner_api_token" { type = string }
variable "vpn_domain" { type = string }
variable "vpn_hostname" { type = string }
variable "acme_email" { type = string }
variable "openai_api_key" { type = string }

variable "dry_run" { type = bool }
variable "module" { type = string }
variable "from" { type = string }
variable "skip_preflight" { type = bool }
variable "skip_validation" { type = bool }
variable "enable_ssh_lockdown" { type = bool }
variable "enable_user_lockdown" { type = bool }
