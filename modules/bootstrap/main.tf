locals {
  env_render = templatefile("${path.module}/../../templates/bootstrap.env.tftpl", {
    hetzner_api_token = var.hetzner_api_token
    vpn_domain        = var.vpn_domain
    vpn_hostname      = var.vpn_hostname
    acme_email        = var.acme_email
    openai_api_key    = var.openai_api_key
  })

  bootstrap_args = compact([
    var.dry_run ? "--dry-run" : "",
    var.module != "" ? "--module ${var.module}" : "",
    var.from != "" ? "--from ${var.from}" : "",
    var.skip_preflight ? "--skip-preflight" : "",
    var.skip_validation ? "--skip-validation" : "",
  ])

  bootstrap_command = "sudo bash ${var.repo_path}/bootstrap/apply.sh ${join(" ", local.bootstrap_args)}"

  post_commands = compact([
    var.enable_ssh_lockdown ? "sudo bash ${var.repo_path}/bootstrap/ssh-lockdown.sh" : "",
    var.enable_user_lockdown ? "sudo bash ${var.repo_path}/bootstrap/user-lockdown.sh" : "",
  ])
}

resource "null_resource" "repo" {
  triggers = {
    repo_url = var.git_repo_url
    git_ref  = var.git_ref
    path     = var.repo_path
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "if ! command -v git >/dev/null 2>&1; then apt-get update -y && apt-get install -y git; fi",
      "if ! command -v make >/dev/null 2>&1; then apt-get update -y && apt-get install -y make; fi",
      "if [ ! -d ${var.repo_path}/.git ]; then git clone ${var.git_repo_url} ${var.repo_path}; fi",
      "cd ${var.repo_path}",
      "git fetch --all --prune --tags",
      "(git checkout ${var.git_ref} || git checkout -b ${var.git_ref} origin/${var.git_ref})",
      "git reset --hard origin/${var.git_ref}"
    ]
  }
}

resource "null_resource" "env" {
  depends_on = [null_resource.repo]

  triggers = {
    env_sha = sha256(local.env_render)
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(var.ssh_private_key_path)
  }

  provisioner "file" {
    content     = local.env_render
    destination = "${var.repo_path}/bootstrap/.env"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 ${var.repo_path}/bootstrap/.env"
    ]
  }
}

resource "null_resource" "bootstrap" {
  depends_on = [null_resource.env]

  triggers = {
    bootstrap_cmd = local.bootstrap_command
    env_sha       = null_resource.env.triggers.env_sha
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "sudo bash ${var.repo_path}/bootstrap/init-env.sh",
      local.bootstrap_command
    ]
  }
}

resource "null_resource" "post" {
  depends_on = [null_resource.bootstrap]

  triggers = {
    post_cmds = sha256(join(";", local.post_commands))
    bootstrap = null_resource.bootstrap.id
  }

  connection {
    type        = "ssh"
    host        = var.ssh_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key != "" ? var.ssh_private_key : file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = concat([
      "set -euo pipefail"
    ], local.post_commands)
  }
}

output "bootstrap_command" {
  value = local.bootstrap_command
}
