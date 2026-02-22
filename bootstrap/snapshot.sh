#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die(){ echo "FATAL: $*" >&2; exit 1; }
run(){ echo "+ $*"; "$@"; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
[[ -n "${REPO_ROOT:-}" ]] || die "REPO_ROOT not set. Export REPO_ROOT=/path/to/repo"

TS="$(date +%F_%H%M%S)"
SNAP_DIR="$REPO_ROOT/snapshot/$TS"

run mkdir -p "$SNAP_DIR"/{00-meta,01-system,02-network,03-dns,04-firewall,05-docker,06-stacks,07-systemd,08-logs,09-security}

# ---------- helper: safe copy preserving attrs ----------
copy_any(){
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$src" "$dst"
  fi
}

# ---------- 00 meta ----------
run bash -lc "printf '%s\n' \"snapshot_ts=$TS\" \"hostname=$(hostname -f 2>/dev/null || hostname)\" \"repo_root=$REPO_ROOT\" > '$SNAP_DIR/00-meta/meta.txt'"
run bash -lc "git -C '$REPO_ROOT' status --porcelain=v1 > '$SNAP_DIR/00-meta/git-status.txt' 2>&1 || true"
run bash -lc "git -C '$REPO_ROOT' rev-parse HEAD > '$SNAP_DIR/00-meta/git-head.txt' 2>&1 || true"

# ---------- 01 system ----------
run bash -lc "uname -a > '$SNAP_DIR/01-system/uname.txt'"
run bash -lc "cat /etc/os-release > '$SNAP_DIR/01-system/os-release.txt' 2>/dev/null || true"
run bash -lc "date -Is > '$SNAP_DIR/01-system/date.txt'"
run bash -lc "uptime > '$SNAP_DIR/01-system/uptime.txt' || true"
run bash -lc "dpkg -l > '$SNAP_DIR/01-system/dpkg-l.txt' 2>/dev/null || true"
run bash -lc "apt-cache policy nftables wireguard-tools dnsmasq docker-ce docker.io traefik  > '$SNAP_DIR/01-system/apt-policy.txt' 2>/dev/null || true"

# ---------- 02 network ----------
run bash -lc "ip -br a > '$SNAP_DIR/02-network/ip-br-a.txt'"
run bash -lc "ip route > '$SNAP_DIR/02-network/ip-route.txt'"
run bash -lc "ip -6 route > '$SNAP_DIR/02-network/ip6-route.txt' 2>/dev/null || true"
run bash -lc "networkctl list > '$SNAP_DIR/02-network/networkctl-list.txt' 2>&1 || true"
run bash -lc "networkctl status > '$SNAP_DIR/02-network/networkctl-status.txt' 2>&1 || true"
run bash -lc "networkctl status wg0 > '$SNAP_DIR/02-network/networkctl-wg0.txt' 2>&1 || true"
run bash -lc "wg show all > '$SNAP_DIR/02-network/wg-show.txt' 2>&1 || true"
run bash -lc "sysctl -a > '$SNAP_DIR/02-network/sysctl-a.txt' 2>/dev/null || true"

# systemd-networkd config
copy_any /etc/systemd/network "$SNAP_DIR/02-network/etc-systemd-network"

# ---------- 03 DNS ----------
run bash -lc "systemctl status systemd-resolved --no-pager > '$SNAP_DIR/03-dns/resolved-status.txt' 2>&1 || true"
run bash -lc "systemctl status dnsmasq --no-pager > '$SNAP_DIR/03-dns/dnsmasq-status.txt' 2>&1 || true"
run bash -lc "resolvectl status > '$SNAP_DIR/03-dns/resolvectl-status.txt' 2>&1 || true"
run bash -lc "readlink -f /etc/resolv.conf > '$SNAP_DIR/03-dns/resolv-conf-link.txt' 2>&1 || true"
run bash -lc "ss -lunp > '$SNAP_DIR/03-dns/ss-udp.txt'"
run bash -lc "ss -lntp > '$SNAP_DIR/03-dns/ss-tcp.txt'"

copy_any /etc/dnsmasq.conf "$SNAP_DIR/03-dns/etc-dnsmasq.conf"
copy_any /etc/dnsmasq.d "$SNAP_DIR/03-dns/etc-dnsmasq.d"
copy_any /etc/systemd/resolved.conf "$SNAP_DIR/03-dns/etc-systemd-resolved.conf"

# ---------- 04 firewall ----------
run bash -lc "systemctl status nftables --no-pager > '$SNAP_DIR/04-firewall/nftables-status.txt' 2>&1 || true"
run bash -lc "nft --version > '$SNAP_DIR/04-firewall/nft-version.txt' 2>&1 || true"
run bash -lc "nft list ruleset > '$SNAP_DIR/04-firewall/nft-ruleset.txt' 2>&1 || true"
run bash -lc "nft -c -f /etc/nftables.conf > '$SNAP_DIR/04-firewall/nft-compile-check.txt' 2>&1 || true"

copy_any /etc/nftables.conf "$SNAP_DIR/04-firewall/etc-nftables.conf"

# ---------- 05 docker ----------
run bash -lc "docker version > '$SNAP_DIR/05-docker/docker-version.txt' 2>&1 || true"
run bash -lc "docker info > '$SNAP_DIR/05-docker/docker-info.txt' 2>&1 || true"
run bash -lc "docker ps --no-trunc --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' > '$SNAP_DIR/05-docker/docker-ps.txt' 2>&1 || true"
run bash -lc "docker ps -a --no-trunc --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' > '$SNAP_DIR/05-docker/docker-ps-a.txt' 2>&1 || true"
run bash -lc "docker network ls > '$SNAP_DIR/05-docker/docker-network-ls.txt' 2>&1 || true"
run bash -lc "docker network inspect vpn_net > '$SNAP_DIR/05-docker/docker-network-vpn_net.json' 2>&1 || true"
run bash -lc "docker inspect traefik > '$SNAP_DIR/05-docker/docker-inspect-traefik.json' 2>&1 || true"
run bash -lc "docker inspect gitea > '$SNAP_DIR/05-docker/docker-inspect-gitea.json' 2>&1 || true"
run bash -lc "docker inspect whoami > '$SNAP_DIR/05-docker/docker-inspect-whoami.json' 2>&1 || true"

copy_any /etc/docker/daemon.json "$SNAP_DIR/05-docker/etc-docker-daemon.json"

# Docker compose configs as rendered (helps later)
run bash -lc "docker compose version > '$SNAP_DIR/05-docker/compose-version.txt' 2>&1 || true"

# ---------- 06 stacks (/opt) ----------
# include secrets for now (local repo only), as requested
if [[ -d /opt/traefik ]]; then
  run rsync -a --delete /opt/traefik/ "$SNAP_DIR/06-stacks/opt-traefik/"
fi
if [[ -d /opt/gitea ]]; then
  run rsync -a --delete /opt/gitea/ "$SNAP_DIR/06-stacks/opt-gitea/"
fi
if [[ -d /opt/whoami ]]; then
  run rsync -a --delete /opt/whoami/ "$SNAP_DIR/06-stacks/opt-whoami/" || true
fi

# ---------- 07 systemd ----------
run bash -lc "systemctl list-unit-files > '$SNAP_DIR/07-systemd/unit-files.txt' 2>&1 || true"
run bash -lc "systemctl list-units --all --no-pager > '$SNAP_DIR/07-systemd/units-all.txt' 2>&1 || true"
run bash -lc "systemctl cat nftables > '$SNAP_DIR/07-systemd/unit-nftables.txt' 2>&1 || true"
run bash -lc "systemctl cat dnsmasq > '$SNAP_DIR/07-systemd/unit-dnsmasq.txt' 2>&1 || true"
run bash -lc "systemctl cat systemd-resolved > '$SNAP_DIR/07-systemd/unit-resolved.txt' 2>&1 || true"

# ---------- 08 logs (bounded) ----------
# keep it bounded so you don't commit a planet
run bash -lc "journalctl -u nftables -n 400 --no-pager > '$SNAP_DIR/08-logs/journal-nftables.txt' 2>&1 || true"
run bash -lc "journalctl -u dnsmasq -n 400 --no-pager > '$SNAP_DIR/08-logs/journal-dnsmasq.txt' 2>&1 || true"
run bash -lc "journalctl -u systemd-resolved -n 400 --no-pager > '$SNAP_DIR/08-logs/journal-resolved.txt' 2>&1 || true"
run bash -lc "journalctl -u docker -n 400 --no-pager > '$SNAP_DIR/08-logs/journal-docker.txt' 2>&1 || true"

# Docker logs snapshots (bounded)
run bash -lc "docker logs --since 24h traefik > '$SNAP_DIR/08-logs/dockerlog-traefik.txt' 2>&1 || true"
run bash -lc "docker logs --since 24h gitea > '$SNAP_DIR/08-logs/dockerlog-gitea.txt' 2>&1 || true"
run bash -lc "docker logs --since 24h whoami > '$SNAP_DIR/08-logs/dockerlog-whoami.txt' 2>&1 || true"

# ---------- 09 security quick checks (so we can eyeball later) ----------
run bash -lc "ss -lntup > '$SNAP_DIR/09-security/ss-listeners.txt'"
run bash -lc "nft list ruleset | sed -n '1,260p' > '$SNAP_DIR/09-security/nft-head.txt' 2>&1 || true"
run bash -lc "docker ps --format 'table {{.Names}}\t{{.Ports}}' > '$SNAP_DIR/09-security/docker-ports.txt' 2>&1 || true"

# ---------- index ----------
run bash -lc "find '$SNAP_DIR' -maxdepth 3 -type f | sort > '$SNAP_DIR/00-meta/index-files.txt'"

echo
echo "SNAPSHOT READY:"
echo "  $SNAP_DIR"
echo "NOTE: contains secrets and runtime state by design (local repo only)."
