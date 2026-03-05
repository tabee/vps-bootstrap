# VPS Bootstrap (Terraform)

This repository is **Terraform-first**. Running Terraform provisions a fresh Hetzner VPS and bootstraps the full stack (WireGuard, nftables, Docker, Traefik, Gitea, etc.).

## ✅ What Terraform does

- **Creates a Hetzner Cloud server** (optional, but default for fresh installs)
- Injects **cloud-init** to:
  - Clone this repo
  - Write `bootstrap/.env`
  - Run `bootstrap/init-env.sh`
  - Run `bootstrap/apply.sh`
- Optionally supports **existing servers via SSH**

## 🔧 Usage — Full fresh server (Hetzner Cloud)

```bash
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
- If `dry_run=true`, bootstrap scripts do not make changes.
- After VPN works, you can enable `enable_ssh_lockdown=true`.

## ✅ Module Flags

You can run just a single module or start from a module:

```bash
# run only firewall module
terraform apply -var="module=04-firewall" ...

# start from module 05
terraform apply -var="from=05" ...
```
