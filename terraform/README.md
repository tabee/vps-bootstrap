# Terraform Bootstrap Orchestrator

This Terraform layer wraps the existing **vps-bootstrap** shell system and makes it reproducible + reviewable using Terraform.

It **does not** replace the bootstrap scripts. It orchestrates them over SSH and manages `.env` creation safely.

## ✅ What this does

- (Optional) **Creates a Hetzner Cloud server** from scratch
- Connects to the VPS via SSH
- Ensures the repo exists at `/root/vps-bootstrap`
- Writes `bootstrap/.env` from variables (no secrets committed)
- Runs `bootstrap/init-env.sh` to generate missing secrets
- Runs `bootstrap/apply.sh` (or dry-run / module / from)
- Optionally runs `ssh-lockdown` and `user-lockdown`

## 🔧 Usage — Full fresh server (Hetzner Cloud)

```bash
cd terraform
terraform init

terraform apply \
  -var="create_hcloud_server=true" \
  -var="hcloud_token=HCLOUD_TOKEN" \
  -var="hcloud_ssh_public_key_path=~/.ssh/id_ed25519.pub" \
  -var="ssh_private_key_path=~/.ssh/id_ed25519" \
  -var="hetzner_api_token=HETZNER_DNS_TOKEN" \
  -var="vpn_domain=example.com" \
  -var="acme_email=admin@example.com"
```

## 🔧 Usage — Existing server (SSH only)

```bash
cd terraform
terraform init

# dry-run first
terraform plan \
  -var="ssh_host=YOUR_VPS_IP" \
  -var="ssh_private_key_path=~/.ssh/your_key" \
  -var="hetzner_api_token=..." \
  -var="vpn_domain=example.com" \
  -var="acme_email=admin@example.com" \
  -var="dry_run=true"

# apply
terraform apply \
  -var="ssh_host=YOUR_VPS_IP" \
  -var="ssh_private_key_path=~/.ssh/your_key" \
  -var="hetzner_api_token=..." \
  -var="vpn_domain=example.com" \
  -var="acme_email=admin@example.com"
```

## 🧠 Notes

- **Do not commit** `.tfvars` files or state.
- If you already have the repo on the server, it will update it.
- If `dry_run=true`, the bootstrap scripts will not make changes.
- After a successful VPN setup, you can enable `enable_ssh_lockdown=true`.

## ✅ Module Flags

You can run just a single module or start from a module:

```bash
# run only firewall module
terraform apply -var="module=04-firewall" ...

# start from module 05
terraform apply -var="from=05" ...
```
