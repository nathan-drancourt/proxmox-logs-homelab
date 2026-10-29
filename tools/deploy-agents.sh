#!/usr/bin/env bash
# À lancer sur l'hôte Proxmox : installe l'agent Alloy dans tous les LXC démarrés,
# sur l'hôte lui-même (option) et sur des VM Linux via SSH (option).
#
# Usage : deploy-agents.sh IP_LOKI [options]
#   --host                 installe aussi l'agent sur l'hôte Proxmox
#   --docker ID[,ID...]    LXC qui font tourner Docker (collecte des conteneurs)
#   --skip ID[,ID...]      LXC à ignorer
#   --vm user@ip           VM Linux à équiper via SSH (option répétable)
set -Eeuo pipefail

REPO_RAW="${LOGS_REPO_RAW:-https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/${LOGS_REPO_BRANCH:-main}}"

LOKI_IP="${1:-}"
[[ -n "$LOKI_IP" && "$LOKI_IP" != --* ]] || { sed -n '2,10p' "$0"; exit 1; }
shift

DO_HOST=0; DOCKER_IDS=","; SKIP_IDS=","; VMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)   DO_HOST=1 ;;
    --docker) DOCKER_IDS=",${2:?}," ; shift ;;
    --skip)   SKIP_IDS=",${2:?},"  ; shift ;;
    --vm)     VMS+=("${2:?}"); shift ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "À lancer en root sur l'hôte Proxmox." >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "pct introuvable : lance ce script sur l'hôte Proxmox." >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
AGENT="$SCRIPT_DIR/install-alloy.sh"
if [[ ! -f "$AGENT" ]]; then
  AGENT=$(mktemp)
  wget -qO "$AGENT" "$REPO_RAW/tools/install-alloy.sh" || { echo "Téléchargement de install-alloy.sh impossible." >&2; exit 1; }
fi

okl=(); skipl=(); faill=()

for id in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
  if [[ "$SKIP_IDS" == *",$id,"* ]]; then skipl+=("LXC $id (ignoré)"); continue; fi
  flags=""; [[ "$DOCKER_IDS" == *",$id,"* ]] && flags="--docker"
  echo "== LXC $id"
  pct push "$id" "$AGENT" /root/install-alloy.sh --perms 0755
  set +e
  pct exec "$id" -- bash /root/install-alloy.sh "$LOKI_IP" $flags
  rc=$?
  set -e
  case $rc in
    0) okl+=("LXC $id") ;;
    2) skipl+=("LXC $id (pas Debian/Ubuntu)") ;;
    *) faill+=("LXC $id (code $rc)") ;;
  esac
done

if [[ $DO_HOST -eq 1 ]]; then
  echo "== Hôte Proxmox"
  if bash "$AGENT" "$LOKI_IP" --label "$(hostname)"; then okl+=("hôte $(hostname)"); else faill+=("hôte"); fi
fi

for vm in "${VMS[@]:-}"; do
  [[ -n "$vm" ]] || continue
  echo "== VM $vm"
  if scp -q "$AGENT" "$vm:/tmp/install-alloy.sh" && ssh -t "$vm" "sudo bash /tmp/install-alloy.sh $LOKI_IP"; then
    okl+=("VM $vm")
  else
    faill+=("VM $vm")
  fi
done

echo
echo "Résumé"
for x in "${okl[@]:-}";   do [[ -n "$x" ]] && echo "  [ok]       $x"; done
for x in "${skipl[@]:-}"; do [[ -n "$x" ]] && echo "  [ignoré]   $x"; done
for x in "${faill[@]:-}"; do [[ -n "$x" ]] && echo "  [échec]    $x"; done
[[ ${#faill[@]} -eq 0 ]]
