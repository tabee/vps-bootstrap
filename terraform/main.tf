module "bootstrap" {
  source = "./modules/bootstrap"

  ssh_host              = var.ssh_host
  ssh_user              = var.ssh_user
  ssh_port              = var.ssh_port
  ssh_private_key_path  = var.ssh_private_key_path
  ssh_private_key       = var.ssh_private_key

  git_repo_url          = var.git_repo_url
  git_ref               = var.git_ref
  repo_path             = var.repo_path

  hetzner_api_token     = var.hetzner_api_token
  vpn_domain            = var.vpn_domain
  vpn_hostname          = var.vpn_hostname
  acme_email            = var.acme_email
  openai_api_key        = var.openai_api_key

  dry_run               = var.dry_run
  module                = var.module
  from                  = var.from
  skip_preflight        = var.skip_preflight
  skip_validation       = var.skip_validation
  enable_ssh_lockdown   = var.enable_ssh_lockdown
  enable_user_lockdown  = var.enable_user_lockdown
}
