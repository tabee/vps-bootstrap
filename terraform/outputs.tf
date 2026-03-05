output "repo_path" {
  value = var.repo_path
}

output "bootstrap_command" {
  value = module.bootstrap.bootstrap_command
}

output "server_ipv4" {
  value       = var.create_hcloud_server ? hcloud_server.bootstrap[0].ipv4_address : var.ssh_host
  description = "Public IPv4 of the server"
}
