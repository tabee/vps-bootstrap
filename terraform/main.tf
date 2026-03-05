provider "hcloud" {
  token = var.hcloud_token != "" ? var.hcloud_token : null
}

locals {
  ssh_host_effective = var.create_hcloud_server ? hcloud_server.bootstrap[0].ipv4_address : var.ssh_host
}

resource "hcloud_ssh_key" "bootstrap" {
  count      = var.create_hcloud_server ? 1 : 0
  name       = var.hcloud_ssh_key_name
  public_key = var.hcloud_ssh_public_key != "" ? var.hcloud_ssh_public_key : file(var.hcloud_ssh_public_key_path)
}

resource "hcloud_firewall" "bootstrap" {
  count = var.create_hcloud_server ? 1 : 0
  name  = "${var.hcloud_server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "bootstrap" {
  count       = var.create_hcloud_server ? 1 : 0
  name        = var.hcloud_server_name
  server_type = var.hcloud_server_type
  location    = var.hcloud_location
  image       = var.hcloud_image

  ssh_keys    = [hcloud_ssh_key.bootstrap[0].id]
  firewall_ids = [hcloud_firewall.bootstrap[0].id]
}

module "bootstrap" {
  source = "./modules/bootstrap"

  ssh_host              = local.ssh_host_effective
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
