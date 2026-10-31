#!/usr/bin/env bash
# Provisionnement DANS le conteneur : Loki + Grafana depuis le dépôt APT officiel de Grafana.
# Lancé automatiquement par ct/logs.sh. Fonctionne aussi sur toute Debian 12/13 ou Ubuntu 22.04+.
#   LOGS_RETENTION_DAYS    rétention des logs (défaut 14)
#   GRAFANA_ADMIN_PASSWORD mot de passe admin Grafana (généré si absent)
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

RETENTION_DAYS="${LOGS_RETENTION_DAYS:-14}"
RETENTION_H=$((RETENTION_DAYS * 24))
REPO_RAW="${LOGS_REPO_RAW:-https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/${LOGS_REPO_BRANCH:-main}}"
GRAFANA_PW="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-16)}"

msg() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "À lancer en root."

msg "Dépôt APT Grafana"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gpg wget openssl >/dev/null
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -qq

msg "Installation de Loki et Grafana"
apt-get install -y -qq loki grafana >/dev/null

# ---------- Loki ----------
msg "Configuration de Loki (rétention ${RETENTION_DAYS} jours)"
install -d -o loki /var/lib/loki
cat > /etc/loki/config.yml <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: ${RETENTION_H}h
  volume_enabled: true
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32

pattern_ingester:
  enabled: true

compactor:
  working_directory: /var/lib/loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

analytics:
  reporting_enabled: false
EOF
chown loki /etc/loki/config.yml
systemctl enable --now loki >/dev/null 2>&1
systemctl restart loki

# ---------- Grafana ----------
msg "Configuration de Grafana"
grafana cli plugins install grafana-lokiexplore-app >/dev/null 2>&1 || true
# La commande ci-dessus tourne en root : sans ce chown, Grafana ne peut pas écrire dans son dossier de modules.
chown -R grafana:grafana /var/lib/grafana/plugins 2>/dev/null || true

cat >> /etc/default/grafana-server <<'EOF'
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_USERS_DEFAULT_THEME=dark
EOF

install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/loki.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://127.0.0.1:3100
    isDefault: true
    editable: false
EOF

cat > /etc/grafana/provisioning/dashboards/homelab.yaml <<'EOF'
apiVersion: 1
providers:
  - name: homelab
    folder: Homelab
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF

if [[ -f /root/homelab-logs.json ]]; then
  cp /root/homelab-logs.json /var/lib/grafana/dashboards/homelab-logs.json
else
  wget -qO /var/lib/grafana/dashboards/homelab-logs.json "${REPO_RAW}/tools/grafana/homelab-logs.json" || true
fi
chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning

systemctl enable --now grafana-server >/dev/null 2>&1
systemctl restart grafana-server

msg "Attente de Loki et Grafana"
for _ in $(seq 1 60); do curl -fs http://127.0.0.1:3100/ready >/dev/null 2>&1 && loki_ok=1 && break; sleep 2; done
for _ in $(seq 1 60); do curl -fs http://127.0.0.1:3000/api/health >/dev/null 2>&1 && graf_ok=1 && break; sleep 2; done
[[ "${loki_ok:-0}" -eq 1 ]] || echo "Avertissement : Loki ne répond pas encore (journalctl -u loki)."
[[ "${graf_ok:-0}" -eq 1 ]] || die "Grafana ne répond pas (journalctl -u grafana-server)."

msg "Mot de passe admin Grafana"
curl -fsS -u admin:admin -X PUT -H 'Content-Type: application/json' \
  -d "{\"oldPassword\":\"admin\",\"newPassword\":\"${GRAFANA_PW}\",\"confirmNew\":\"${GRAFANA_PW}\"}" \
  http://127.0.0.1:3000/api/user/password >/dev/null \
  || echo "Avertissement : mot de passe non modifié (admin/admin reste actif)."

umask 077
cat > /root/.credentials <<EOF
grafana_user=admin
grafana_password=${GRAFANA_PW}
retention_days=${RETENTION_DAYS}
EOF

msg "Terminé."
