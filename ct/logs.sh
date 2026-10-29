#!/usr/bin/env bash
# Crée un LXC Debian « logs » (Loki + Grafana) sur un hôte Proxmox VE.
# À lancer en root sur l'hôte Proxmox :
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/ct/logs.sh)"
#
# Variables d'environnement utiles (toutes optionnelles) :
#   CTID CT_NAME CORES RAM DISK STORAGE TPL_STORAGE BRIDGE IP GW DNS
#   LOGS_RETENTION_DAYS  LOGS_REPO_RAW  LOGS_REPO_BRANCH
# Options : --yes (aucune question, valeurs par défaut ou variables)
set -Eeuo pipefail

REPO_BRANCH="${LOGS_REPO_BRANCH:-main}"
REPO_RAW="${LOGS_REPO_RAW:-https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/${REPO_BRANCH}}"

msg() { printf '\033[1;34m[logs]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root sur l'hôte Proxmox."
command -v pct >/dev/null 2>&1 && command -v pveam >/dev/null 2>&1 \
  || die "Ce script doit tourner sur un hôte Proxmox VE."

YES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,11p' "$0" 2>/dev/null || true; exit 0 ;;
  esac
done

# ask VAR "Question" "défaut" : pose la question sauf en mode --yes ou sans terminal
ask() {
  local var=$1 q=$2 def=$3 val
  if [[ $YES -eq 1 || ! -t 0 ]]; then
    printf -v "$var" '%s' "${!var:-$def}"
    return
  fi
  read -r -p "$q [${!var:-$def}] : " val || true
  printf -v "$var" '%s' "${val:-${!var:-$def}}"
}

# ---------- Valeurs par défaut ----------
first_storage() { pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' ; }

DEF_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 300)
DEF_STORAGE=$(first_storage rootdir | grep -x 'local-lvm' || first_storage rootdir | head -1)
DEF_TPL_STORAGE=$(first_storage vztmpl | grep -x 'local' || first_storage vztmpl | head -1)
[[ -n "$DEF_STORAGE" ]] || die "Aucun stockage compatible rootdir trouvé."
[[ -n "$DEF_TPL_STORAGE" ]] || die "Aucun stockage compatible vztmpl trouvé."

CTID="${CTID:-}" CT_NAME="${CT_NAME:-}"
CORES="${CORES:-}" RAM="${RAM:-}" DISK="${DISK:-}"
STORAGE="${STORAGE:-}" TPL_STORAGE="${TPL_STORAGE:-}" BRIDGE="${BRIDGE:-}"
IP="${IP:-}" GW="${GW:-}" DNS="${DNS:-}"
RETENTION="${LOGS_RETENTION_DAYS:-}"

cat <<'BANNER'

  _      ___   ____ ____
 | |    / _ \ / ___/ ___|
 | |   | | | | |  _\___ \
 | |___| |_| | |_| |___) |
 |_____|\___/ \____|____/   Loki + Grafana pour Proxmox VE

BANNER

# Menu Par défaut / Avancé (comme community-scripts)
if [[ $YES -eq 0 && -t 0 ]] && command -v whiptail >/dev/null 2>&1; then
  MODE=$(whiptail --backtitle "Homelab Logs" --title "Centre de logs" \
    --menu "Choisis le mode d'installation :" 14 70 3 \
    1 "Par défaut (DHCP, 2 vCPU, 2 Gio, 20 Go, rétention 14 jours)" \
    2 "Avancé (je choisis chaque paramètre)" \
    3 "Annuler" 3>&1 1>&2 2>&3) || exit 0
  [[ "$MODE" == "3" ]] && exit 0
  [[ "$MODE" == "1" ]] && YES=1
fi

msg "Configuration du conteneur (Entrée = valeur par défaut)"
ask CTID        "ID du conteneur"                         "$DEF_CTID"
ask CT_NAME     "Nom d'hôte"                              "logs"
ask CORES       "vCPU"                                    "2"
ask RAM         "RAM en Mio"                              "2048"
ask DISK        "Disque en Gio"                           "20"
ask STORAGE     "Stockage du conteneur"                   "$DEF_STORAGE"
ask TPL_STORAGE "Stockage des modèles"                    "$DEF_TPL_STORAGE"
ask BRIDGE      "Bridge réseau"                           "vmbr0"
ask IP          "IP (dhcp ou CIDR, ex. 192.168.1.30/24)"  "dhcp"
if [[ "$IP" != "dhcp" ]]; then
  ask GW        "Passerelle"                              "192.168.1.1"
  ask DNS       "Serveur DNS (vide = celui de l'hôte)"    ""
fi
ask RETENTION   "Rétention des logs en jours"             "14"

[[ "$CTID" =~ ^[0-9]+$ ]] || die "ID invalide : $CTID"
pct status "$CTID" >/dev/null 2>&1 && die "Le conteneur $CTID existe déjà."
[[ "$RETENTION" =~ ^[0-9]+$ && "$RETENTION" -ge 1 ]] || die "Rétention invalide : $RETENTION"

if [[ "$IP" == "dhcp" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}"
fi

gen_pw() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-16; }
ROOT_PW=$(gen_pw)
GRAFANA_PW=$(gen_pw)

# ---------- Modèle Debian ----------
msg "Recherche du dernier modèle Debian"
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system | awk '/debian-1[23]-standard/ {print $2}' | sort -V | tail -1)
[[ -n "$TEMPLATE" ]] || die "Aucun modèle Debian 12 ou 13 disponible."
if ! pveam list "$TPL_STORAGE" | grep -q "$TEMPLATE"; then
  msg "Téléchargement de $TEMPLATE"
  pveam download "$TPL_STORAGE" "$TEMPLATE" >/dev/null
fi

# ---------- Création ----------
msg "Création du conteneur $CTID ($CT_NAME)"
create_args=(
  "$CTID" "${TPL_STORAGE}:vztmpl/${TEMPLATE}"
  --hostname "$CT_NAME" --cores "$CORES" --memory "$RAM" --swap 512
  --rootfs "${STORAGE}:${DISK}" --net0 "$NET0"
  --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian
  --password "$ROOT_PW" --tags "logs;loki;grafana"
  --description "Centre de logs : Loki + Grafana (proxmox-logs-homelab)"
)
[[ -n "$DNS" ]] && create_args+=(--nameserver "$DNS")
pct create "${create_args[@]}" >/dev/null
pct start "$CTID"

msg "Attente du réseau dans le conteneur"
for _ in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then net_ok=1; break; fi
  sleep 2
done
[[ "${net_ok:-0}" -eq 1 ]] || die "Le conteneur n'a pas d'accès réseau (DHCP, passerelle ou DNS à vérifier)."

# ---------- Provisionnement ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() { # fetch chemin_relatif destination
  local rel=$1 dest=$2
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../$rel" ]]; then
    cp "$SCRIPT_DIR/../$rel" "$dest"
  else
    wget -qO "$dest" "$REPO_RAW/$rel" || die "Téléchargement impossible : $REPO_RAW/$rel"
  fi
}

fetch install/logs-install.sh "$WORK/logs-install.sh"
fetch tools/grafana/homelab-logs.json "$WORK/homelab-logs.json"
pct push "$CTID" "$WORK/logs-install.sh" /root/logs-install.sh --perms 0755
pct push "$CTID" "$WORK/homelab-logs.json" /root/homelab-logs.json --perms 0644

msg "Installation de Loki et Grafana (2 à 4 minutes)"
pct exec "$CTID" -- env \
  LOGS_RETENTION_DAYS="$RETENTION" \
  GRAFANA_ADMIN_PASSWORD="$GRAFANA_PW" \
  bash /root/logs-install.sh

CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
ok "Centre de logs prêt."
cat <<EOF

  Grafana       http://${CT_IP}:3000     utilisateur : admin
  Mot de passe  ${GRAFANA_PW}
  Loki (push)   http://${CT_IP}:3100/loki/api/v1/push
  Root du LXC   ${ROOT_PW}
  Rétention     ${RETENTION} jours

  Les mots de passe sont aussi dans /root/.credentials du conteneur.

  Étape suivante : installer les agents sur tes LXC, ton hôte et tes VM.
    git clone https://github.com/nathan-drancourt/proxmox-logs-homelab
    cd proxmox-logs-homelab
    bash tools/deploy-agents.sh ${CT_IP} --host

  Pense à fixer l'IP du conteneur (${CT_IP}) : les agents s'y connectent.
EOF
