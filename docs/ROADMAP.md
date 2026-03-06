# VPS Bootstrap — Erweiterungsroadmap: KI-Dienste & Menschliche Nutzer

> **Zieldefinition:**
> - **Menschen** greifen über ihren Browser per Traefik auf Web-Dienste zu.
> - **KI-Agenten** (openclaw, Skripte, Automatisierungen) greifen über SSH + `docker exec` auf CLI-Dienste zu — kein Browser, kein HTTP-Port.

---

## Zielgruppenanalyse

| Zielgruppe | Zugriffsmuster | Authentifizierung |
|------------|---------------|-------------------|
| **Menschen** | Browser → Traefik HTTPS → Web-UI | Benutzername/Passwort, OAuth |
| **KI-Agenten** | VPN → SSH → `docker exec <svc> <cmd>` | SSH-Key (VPN-Pflicht) |

---

## Bestehende Dienste — Erweiterungsvorschläge

### n8n (Workflow-Automatisierung)

n8n ist bereits vorhanden. Sinnvolle Erweiterungen für KI-Workflows:

- **OpenAI / Anthropic API-Schlüssel** in `terraform.tfvars` hinterlegen → automatisch per `.env` in n8n verfügbar
- **n8n Community Nodes** für LangChain, Anthropic, Ollama installieren
- KI-Agenten können n8n-Webhooks über SSH-Tunnel auslösen

Konfiguration in `terraform.tfvars`:

```hcl
enable_n8n    = true
openai_api_key = "sk-..."
```

### Gitea (Git-Server)

- **API-Zugriff für KI-Agenten:** Agenten können Code via Gitea-API commiten/pushen
- Kein direkter Port exponiert — API läuft über Traefik HTTPS

### Traefik

- Alle neuen Web-Dienste erhalten das gleiche Sicherheitsmuster: `vpn-only` Middleware
- HTTPS-Zertifikate werden automatisch per bestehender ACME-DNS-Challenge ausgestellt

---

## Neue Dienste

### Übersicht

| Service | Zielgruppe | Zugriff | IP | Enable-Variable |
|---------|-----------|---------|-----|-----------------|
| **Open WebUI** | Menschen | Traefik → `https://ai.DOMAIN` | 10.20.0.60 | `enable_open_webui = true` |
| **Ollama** | KI-Agenten | SSH → `docker exec ollama ollama run <model>` | 10.20.0.80 | `enable_ollama = true` |
| **openclaw** | KI-Agenten | SSH → `docker exec openclaw <cmd>` | 10.20.0.90 | `enable_openclaw = true` |

---

### Open WebUI — Web-Chat-Interface für Menschen

> 🌐 **Zugriff:** Browser → `https://ai.DOMAIN`

Open WebUI ist eine moderne Chat-Oberfläche (ähnlich ChatGPT), die sich mit lokalen Modellen via Ollama oder Cloud-Anbieter (OpenAI, Anthropic) verbindet.

```
┌─────────────┐    VPN    ┌────────────────┐    HTTP    ┌────────────────┐
│   Browser   │ ────────► │ Traefik :443   │ ─────────► │ Open WebUI     │
│  (Mensch)   │           │ ai.domain.com  │            │ 10.20.0.60:8080│
└─────────────┘           └────────────────┘            └────────────────┘
                                                                 │
                                                           (intern) HTTP
                                                                 │
                                                         ┌───────▼────────┐
                                                         │    Ollama      │
                                                         │ 10.20.0.80:11434│
                                                         └────────────────┘
```

**Eigenschaften:**
- Mehrbenutzer-fähig mit Benutzerverwaltung
- Unterstützt Ollama (lokal) und externe APIs (OpenAI, Anthropic)
- RAG (Retrieval Augmented Generation) integriert
- Keine Ports exponiert — ausschließlich über Traefik erreichbar

**Aktivierung:**

```hcl
enable_open_webui = true
enable_ollama     = true   # Empfohlen als Backend
```

---

### Ollama — Lokale KI-Modelle (CLI-Dienst)

> 🔒 **Zugriff:** VPN → SSH → `docker exec ollama ollama run <model>`

Ollama betreibt Large Language Models lokal auf dem Server. Kein Cloud-Anbieter nötig.

```
┌──────────────┐   VPN    ┌─────────────┐   SSH    ┌─────────────────┐
│  KI-Agent /  │ ───────► │ 10.100.0.1  │ ───────► │ docker exec     │
│  Entwickler  │          │   Server    │          │ ollama ollama   │
└──────────────┘          └─────────────┘          │ run llama3.2    │
                                                    └─────────────────┘
```

**Einsatzmöglichkeiten:**
- Lokale Inferenz ohne Kosten/Datenschutzbedenken
- Backend für Open WebUI
- KI-Agenten können Anfragen direkt via `docker exec` stellen

**Befehle nach Deployment:**

```bash
# VPN verbinden, dann SSH
ssh admin@10.100.0.1

# Modell herunterladen
docker exec ollama ollama pull llama3.2

# Modell ausführen (interaktiv)
docker exec -it ollama ollama run llama3.2

# Modell API-Anfrage (JSON)
docker exec ollama ollama run llama3.2 "Erkläre Docker in einem Satz"

# Alias: 'ollama' ist auf dem Server verfügbar
ollama run llama3.2
ollama list
```

**Hinweis zu Serverressourcen:**
- Kleine Modelle (1B–3B Parameter): CX22 (2 vCPU, 4 GB RAM) ausreichend
- Größere Modelle (7B+): CX42 oder dediziertes GPU-System empfohlen
- Modelle werden in `/opt/ollama/models/` persistent gespeichert

---

### openclaw — KI-Agenten-Runtime (CLI-Dienst)

> 🔒 **Zugriff:** VPN → SSH → `docker exec openclaw <cmd>`

openclaw läuft als persistenter Docker-Container ohne exponierten Port. KI-Agenten und Automatisierungen sprechen ihn via SSH + `docker exec` an — identisches Muster wie `gogcli`.

```
┌──────────────┐   VPN    ┌─────────────┐   SSH    ┌─────────────────┐
│  KI-Agent /  │ ───────► │ 10.100.0.1  │ ───────► │ docker exec     │
│  Skript      │          │   Server    │          │ openclaw <cmd>  │
└──────────────┘          └─────────────┘          └─────────────────┘
```

**Eigenschaften:**
- Kein Web-Interface, kein exponierter Port
- Persistenter Container für Zustandsspeicherung (Kontext, Token, etc.)
- Wrapper-Skript `claw` als Alias auf dem Server

**Befehle nach Deployment:**

```bash
# VPN verbinden, dann SSH
ssh admin@10.100.0.1

# Direkt via docker exec
docker exec openclaw claw <subcommand>

# Via Alias
claw <subcommand>
```

---

## Netzwerk-Übersicht (erweitert)

```
                    ┌──────────────────────────────────────┐
                    │              INTERNET                │
                    └──────────────────────────────────────┘
                                    │
           ┌────────────────────────┼───────────────────────┐
           │                        │                       │
           ▼                        ▼                       │
    HTTPS (443)              WireGuard (51820)              │
           │                        │                       │
           ▼                        ▼                       │
    ┌─────────────┐          ┌─────────────┐                │
    │   TRAEFIK   │          │  VPN ONLY   │                │
    │ 10.20.0.10  │          │ 10.100.0.x  │                │
    └─────────────┘          └─────────────┘                │
           │                        │                       │
  ┌────────┼────────┐               ▼                       │
  ▼        ▼        ▼           SSH → docker exec           │
Gitea    n8n    Open WebUI          │                       │
:3000   :5678    :8080         ┌────┴──────┐                │
                               │           │                │
                            Ollama     openclaw             │
                           10.20.0.80 10.20.0.90            │
                           gogcli                           │
                           10.20.0.50                       │
```

| Zugriffstyp | Dienste | Methode |
|-------------|---------|---------|
| 🌐 **Web (Traefik)** | Gitea, n8n, Open WebUI, whoami | Browser → `https://dienst.domain` |
| 🔒 **SSH (VPN only)** | gogcli, Ollama, openclaw | VPN → `ssh admin@10.100.0.1` → `docker exec <svc> <cmd>` |

---

## Implementierungsstatus

| Dienst | Typ | Status | Datei |
|--------|-----|--------|-------|
| Open WebUI | Web (Traefik) | ✅ Implementiert | `bootstrap/services/open-webui.sh` |
| Ollama | CLI (SSH/exec) | ✅ Implementiert | `bootstrap/services/ollama.sh` |
| openclaw | CLI (SSH/exec) | ✅ Implementiert | `bootstrap/services/openclaw.sh` |

---

## Empfohlene Deployment-Reihenfolge

```hcl
# terraform.tfvars

# Schritt 1: Ollama aktivieren (Backend zuerst)
enable_ollama = true

# Schritt 2: Open WebUI aktivieren (nutzt Ollama als Backend)
enable_open_webui = true

# Schritt 3: Nach Deployment erstes Modell laden
# ssh admin@10.100.0.1
# ollama pull llama3.2

# Schritt 4: openclaw aktivieren (optional)
enable_openclaw = true
```

---

## Sicherheitshinweise

- Alle Dienste laufen **ohne exponierte Ports** (`no ports:` Direktive)
- Open WebUI ist ausschließlich über VPN + Traefik erreichbar (vpn-only Middleware)
- Ollama und openclaw sind **ausschließlich** über SSH + docker exec erreichbar
- Die VPN-Pflicht gilt für alle Zugriffe (nftables blockt allen öffentlichen Traffic außer WireGuard UDP 51820)
