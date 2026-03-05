# VPS Bootstrap

**Sichere VPS-Infrastruktur mit einem Befehl.**

Erstellt einen gehärteten Debian 12 Server mit:
- 🔐 WireGuard VPN (einziger Zugang nach Installation)
- 🌐 Automatische HTTPS-Zertifikate (Let's Encrypt via Hetzner DNS)
- 🐳 Docker-basierte Services (optional: Gitea, n8n)
- 🛡️ Firewall, Fail2ban, automatische Sicherheitsupdates

---

## Voraussetzungen

### 1. Server erstellen (5 Min)

1. Gehe zu [Hetzner Cloud Console](https://console.hetzner.cloud)
2. Neues Projekt erstellen (falls noch nicht vorhanden)
3. Server hinzufügen:
   - **Standort:** Beliebig (z.B. Falkenstein)
   - **Image:** Debian 12
   - **Typ:** CX22 oder größer (mind. 2 vCPU, 4 GB RAM)
   - **SSH-Key:** Deinen öffentlichen Key hinzufügen
4. Server erstellen und **IP-Adresse notieren**

### 2. Domain einrichten (5 Min)

Bei [Hetzner Cloud Console](https://console.hetzner.cloud) → DNS:

```
example.com      A     123.45.67.89    (deine Server-IP)
*.example.com    A     123.45.67.89    (Wildcard für Services)
```

**DNS API Token erstellen:** Console → Project → Security → API Tokens

> ⚠️ Die alten dns.hetzner.com Tokens funktionieren seit 2025 nicht mehr!

### 3. Terraform installieren (einmalig)

```bash
# macOS
brew install terraform

# Linux (Debian/Ubuntu)
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform

# Oder: https://terraform.io/downloads
```

---

## Installation

### Schritt 1: Repository klonen

```bash
git clone https://github.com/tabee/vps-bootstrap.git
cd vps-bootstrap
```

### Schritt 2: Konfiguration erstellen

```bash
cp terraform.tfvars.example terraform.tfvars
```

Öffne `terraform.tfvars` und trage deine Werte ein:

```hcl
# PFLICHT - Ohne diese geht nichts
ssh_host             = "123.45.67.89"        # IP aus Hetzner Console
ssh_private_key_path = "~/.ssh/id_ed25519"   # Pfad zu deinem SSH-Key
domain               = "example.com"          # Deine Domain
hetzner_dns_token    = "xxx"                  # DNS API Token
acme_email           = "du@example.com"       # E-Mail für Let's Encrypt

# OPTIONAL - Services aktivieren (default: aus)
enable_gitea  = false  # Git-Server unter git.example.com
enable_n8n    = false  # Workflow-Automation unter n8n.example.com
enable_whoami = true   # Test-Service unter whoami.example.com

# OPTIONAL - VPN-Clients (default: ["admin"])
vpn_clients = ["admin", "iphone", "laptop"]
```

### Schritt 3: Server einrichten

```bash
terraform init      # Einmalig: Plugins herunterladen
terraform apply     # Server konfigurieren (dauert ~5 Minuten)
```

Terraform zeigt dir am Ende:
- Alle generierten Passwörter
- VPN-Konfigurationen
- Service-URLs

### Schritt 4: VPN einrichten (WICHTIG!)

⚠️ **Nach Abschluss ist der Server NUR noch über VPN erreichbar!**

```bash
# VPN-Config anzeigen
terraform output -json access | jq -r '.vpn.config_cmd' | bash

# Oder QR-Code für WireGuard-App (iOS/Android)
terraform output -json access | jq -r '.vpn.qr_cmd' | bash
```

1. WireGuard-App installieren ([iOS](https://apps.apple.com/app/wireguard/id1441195209) / [Android](https://play.google.com/store/apps/details?id=com.wireguard.android))
2. QR-Code scannen oder Config importieren
3. VPN aktivieren

### Schritt 5: Verbindung testen

```bash
# Mit VPN verbunden:
ssh admin@10.100.0.1    # SSH über VPN

# Root werden (passwortlos)
sudo -i

# Service testen
curl -k https://whoami.example.com
```

---

## Konfiguration (terraform.tfvars)

| Variable | Pflicht | Default | Beschreibung |
|----------|:-------:|---------|--------------|
| `ssh_host` | ✓ | - | IP-Adresse des Servers |
| `ssh_private_key_path` | ✓ | - | Pfad zu deinem SSH-Key |
| `domain` | ✓ | - | Deine Domain |
| `hetzner_dns_token` | ✓ | - | Hetzner DNS API Token |
| `acme_email` | ✓ | - | E-Mail für Let's Encrypt |
| `enable_gitea` | | `false` | Git-Server (git.domain.com) |
| `enable_n8n` | | `false` | Workflow-Tool (n8n.domain.com) |
| `enable_whoami` | | `true` | Test-Service (whoami.domain.com) |
| `vpn_clients` | | `["admin"]` | Liste der VPN-Clients |
| `admin_user` | | `"admin"` | SSH-Benutzername nach Härtung |

---

## VPN-Clients verwalten

### Neuen Client hinzufügen

```hcl
# In terraform.tfvars:
vpn_clients = ["admin", "iphone", "laptop", "neues-geraet"]
```

```bash
terraform apply
```

### Client entfernen

```hcl
# Client aus Liste entfernen:
vpn_clients = ["admin", "laptop"]  # "iphone" entfernt
```

```bash
terraform apply  # Client wird automatisch gelöscht
```

### Alle Clients anzeigen

```bash
ssh admin@10.100.0.1 'sudo /opt/vps/bootstrap/scripts/vpn-client.sh list'
```

---

## Passwörter & Zugangsdaten

Alle Passwörter werden sicher generiert:

```bash
# Alle Credentials anzeigen
terraform output -json credentials | jq

# VPN-Config für admin
terraform output -json access | jq -r '.vpn.config_cmd' | bash
```

⚠️ **Speichere diese Zugangsdaten sicher (z.B. Password-Manager)!**

---

## SSH-Zugang nach Installation

Nach der Installation ist SSH **nur noch über VPN** erreichbar:

```bash
# ❌ Von außen nicht mehr möglich:
ssh root@123.45.67.89

# ✅ Über VPN:
ssh admin@10.100.0.1

# Root werden:
sudo -i
```

---

## Fehlerbehebung

### VPN verbindet nicht

1. **DNS prüfen:** Zeigt deine Domain auf die Server-IP?
   ```bash
   dig +short example.com
   ```
2. **Port offen?** UDP 51820 muss erreichbar sein
   ```bash
   nc -zu SERVER_IP 51820 && echo "OK" || echo "BLOCKED"
   ```
3. **Config korrekt?** Endpoint-IP in der WireGuard-Config prüfen

### Ausgesperrt?

Falls VPN nicht funktioniert und SSH nicht mehr geht:
1. Hetzner Console → Server → Rescue-System aktivieren
2. Server neu starten (bootet in Rescue)
3. Festplatte mounten und SSH-Config reparieren

---

## Sicherheit

Dieser Server ist nach Installation maximal gehärtet:

- **Netzwerk:** Nur UDP 51820 (WireGuard) öffentlich erreichbar
- **SSH:** Nur über VPN, nur Key-Auth, kein Root
- **Firewall:** nftables mit Default-DENY Policy
- **Docker:** Kann Firewall nicht manipulieren (`iptables: false`)
- **Updates:** Sicherheitsupdates automatisch (unattended-upgrades)
- **Intrusion Detection:** Fail2ban blockiert Brute-Force

---

## Was wird installiert?

| Komponente | Zweck | Port |
|------------|-------|------|
| WireGuard | VPN-Tunnel | UDP 51820 (einziger öffentlicher Port!) |
| nftables | Firewall | - |
| Docker | Container-Runtime | - |
| Traefik | Reverse Proxy + HTTPS | 443 (nur über VPN) |
| Fail2ban | Brute-Force-Schutz | - |
| Unattended Upgrades | Auto-Updates | - |
| (optional) Gitea | Git-Server | 2222 (SSH, nur VPN) |
| (optional) n8n | Workflow-Automation | - |
| (optional) whoami | Test-Service | - |

---

## Architektur

```
┌─────────────────────────────────────────────────────────────┐
│  Internet                                                   │
│       │                                                     │
│       ▼ UDP 51820 (einziger offener Port)                  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  WireGuard VPN                                         │ │
│  │  10.100.0.1 (Server) ←→ 10.100.0.2+ (Clients)         │ │
│  └────────────────────────────────────────────────────────┘ │
│       │                                                     │
│       ▼ Nur über VPN erreichbar                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Docker (10.20.0.0/24)                                 │ │
│  │    ├── Traefik (443) ─→ git.*, n8n.*, whoami.*        │ │
│  │    ├── Gitea (optional)                                │ │
│  │    ├── n8n (optional)                                  │ │
│  │    └── whoami (optional)                               │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Lizenz

MIT License - siehe [LICENSE](LICENSE)
