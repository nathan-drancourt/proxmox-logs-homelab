#!/usr/bin/env bash
# Installe la page web « Homelab Logs » (nginx) dans le LXC qui fait tourner Loki.
# À lancer DANS le conteneur, en root :
#   pct exec <ctid> -- bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/tools/install-dashboard.sh)"
#   DASHBOARD_PORT   port d'écoute (défaut 8080)
#   LOGS_REPO_RAW    origine des fichiers (défaut : branche main du dépôt)
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

PORT="${DASHBOARD_PORT:-8080}"
REPO_RAW="${LOGS_REPO_RAW:-https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/${LOGS_REPO_BRANCH:-main}}"

msg() { printf '\033[1;34m[dashboard]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "À lancer en root."
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "Port invalide : $PORT"
curl -fs http://127.0.0.1:3100/ready >/dev/null 2>&1 || echo "Avertissement : Loki ne répond pas sur 127.0.0.1:3100 (la page restera vide)." >&2

msg "Installation de nginx"
apt-get update -qq
apt-get install -y -qq --no-upgrade nginx wget >/dev/null

msg "Téléchargement de la page"
install -d -m 0755 /var/www/homelab-logs
wget -qO /var/www/homelab-logs/index.html.new "${REPO_RAW}/tools/web/index.html" || die "Téléchargement impossible : ${REPO_RAW}/tools/web/index.html"
mv /var/www/homelab-logs/index.html.new /var/www/homelab-logs/index.html

msg "Configuration de nginx (port ${PORT}, Loki en lecture seule)"
cat > /etc/nginx/conf.d/homelab-logs.conf <<EOF
server {
  listen ${PORT};
  server_name _;
  root /var/www/homelab-logs;
  index index.html;

  location = / { add_header Cache-Control "no-cache"; }

  # La page interroge Loki par ce relais : même origine, lecture seule.
  location /loki/ {
    limit_except GET { deny all; }
    proxy_pass http://127.0.0.1:3100;
    proxy_read_timeout 60s;
  }
}
EOF
nginx -t >/dev/null 2>&1 || { nginx -t; die "Configuration nginx invalide."; }
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx

IP=$(hostname -I | awk '{print $1}')
msg "Terminé : http://${IP}:${PORT}/"
