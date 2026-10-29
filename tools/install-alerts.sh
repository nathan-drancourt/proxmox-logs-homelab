#!/usr/bin/env bash
# Installe trois alertes Grafana qui préviennent sur Discord, dans le LXC des logs.
# À lancer DANS le conteneur, en root, avec l'URL du webhook Discord en variable :
#   read -rsp "Webhook Discord : " W; echo
#   pct exec <ctid> -- env DISCORD_WEBHOOK_URL="$W" bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/tools/install-alerts.sh)"
#
# Alertes créées :
#   - Machine silencieuse : une machine connue n'a plus envoyé de log depuis 2 h
#   - Rafale d'erreurs    : plus de 40 erreurs en 10 min sur une machine
#   - Plus aucun log      : plus rien reçu du tout depuis 10 min
#
# L'URL du webhook est un secret : elle reste dans /etc/default/grafana-server (droits 640)
# et n'est jamais écrite dans le dépôt. Si Grafana ne redémarre pas, tout est annulé.
set -Eeuo pipefail

ENV_FILE=/etc/default/grafana-server
PROV=/etc/grafana/provisioning/alerting/homelab.yaml
BACKUP_ENV=$(mktemp)

msg() { printf '\033[1;34m[alertes]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "À lancer en root."

URL="${DISCORD_WEBHOOK_URL:-}"
[[ -n "$URL" ]] || die "Variable DISCORD_WEBHOOK_URL manquante (voir l'en-tête du script)."
[[ "$URL" =~ ^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] \
  || die "URL de webhook invalide : elle doit ressembler à https://discord.com/api/webhooks/ID/JETON"
command -v grafana-server >/dev/null 2>&1 || die "Grafana n'est pas installé ici."
curl -fs http://127.0.0.1:3100/ready >/dev/null 2>&1 || echo "Avertissement : Loki ne répond pas sur 127.0.0.1:3100." >&2

cp -p "$ENV_FILE" "$BACKUP_ENV" 2>/dev/null || : >"$BACKUP_ENV"
HAD_PROV=0
if [[ -f "$PROV" ]]; then cp -p "$PROV" "$PROV.bak"; HAD_PROV=1; fi

rollback() {
  msg "Retour en arrière"
  if [[ $HAD_PROV -eq 1 ]]; then mv -f "$PROV.bak" "$PROV"; else rm -f "$PROV"; fi
  cp -p "$BACKUP_ENV" "$ENV_FILE" 2>/dev/null || true
  systemctl restart grafana-server || true
}

msg "Enregistrement du webhook"
touch "$ENV_FILE"
sed -i '/^DISCORD_WEBHOOK_URL=/d' "$ENV_FILE"
printf 'DISCORD_WEBHOOK_URL=%s\n' "$URL" >> "$ENV_FILE"
chown root:grafana "$ENV_FILE"
chmod 640 "$ENV_FILE"

msg "Écriture des alertes"
install -d -o root -g grafana -m 0750 /etc/grafana/provisioning/alerting
cat > "$PROV" <<'EOF'
apiVersion: 1

contactPoints:
  - orgId: 1
    name: discord-homelab
    receivers:
      - uid: discord-homelab
        type: discord
        settings:
          url: $__env{DISCORD_WEBHOOK_URL}
          use_discord_username: false
        disableResolveMessage: false

policies:
  - orgId: 1
    receiver: discord-homelab
    group_by: ['alertname', 'host']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 6h

groups:
  - orgId: 1
    name: homelab-logs
    folder: Homelab
    interval: 1m
    rules:
      - uid: homelab-silencieuse
        title: Machine silencieuse
        condition: C
        for: 10m
        noDataState: OK
        execErrState: OK
        annotations:
          summary: Une machine n'envoie plus de logs depuis 2 h.
          description: Vérifie qu'elle est allumée et que l'agent tourne avec systemctl status alloy.
        labels:
          severity: warning
        data:
          - refId: A
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: loki
            model:
              datasource: { type: loki, uid: loki }
              expr: 'sum by (host) (count_over_time({host=~".+"}[3d])) unless sum by (host) (count_over_time({host=~".+"}[2h]))'
              queryType: instant
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              expression: A
              reducer: last
              settings: { mode: dropNN }
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: gt, params: [0] }
              refId: C

      - uid: homelab-rafale-erreurs
        title: Rafale d'erreurs
        condition: C
        for: 5m
        noDataState: OK
        execErrState: OK
        annotations:
          summary: Plus de 40 erreurs en 10 minutes sur une machine.
          description: Ouvre le tableau de bord Homelab / Logs, panneau Dernières erreurs.
        labels:
          severity: warning
        data:
          - refId: A
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: loki
            model:
              datasource: { type: loki, uid: loki }
              expr: 'sum by (host) (count_over_time({host=~".+"} |~ "(?i)(error|erreur|fatal|critical|panic|failed|denied)" !~ "caller=spanlogger|caller=scheduler_processor|logger=plugin.loki|Request Completed|without error|count_over_time" [10m]))'
              queryType: instant
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              expression: A
              reducer: last
              settings: { mode: dropNN }
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: gt, params: [40] }
              refId: C

      - uid: homelab-aucun-log
        title: Plus aucun log reçu
        condition: C
        for: 5m
        noDataState: Alerting
        execErrState: Alerting
        annotations:
          summary: Loki ne reçoit plus aucun log depuis 10 minutes.
          description: Vérifie le LXC des logs, Loki et les agents Alloy.
        labels:
          severity: critical
        data:
          - refId: A
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: loki
            model:
              datasource: { type: loki, uid: loki }
              expr: 'sum(count_over_time({host=~".+"}[10m]))'
              queryType: instant
              refId: A
          - refId: B
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: reduce
              expression: A
              reducer: last
              settings: { mode: dropNN }
              refId: B
          - refId: C
            datasourceUid: __expr__
            model:
              datasource: { type: __expr__, uid: __expr__ }
              type: threshold
              expression: B
              conditions:
                - evaluator: { type: lt, params: [1] }
              refId: C
EOF
chown root:grafana "$PROV"
chmod 640 "$PROV"

msg "Redémarrage de Grafana"
systemctl restart grafana-server
ok=0
for _ in $(seq 1 45); do
  if curl -fs http://127.0.0.1:3000/api/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [[ $ok -ne 1 ]]; then
  journalctl -u grafana-server -n 15 --no-pager >&2 || true
  rollback
  die "Grafana n'a pas redémarré avec les alertes. Tout a été annulé."
fi

# Vérification par l'API, avec le mot de passe admin enregistré à l'installation.
PW=$(sed -n 's/^grafana_password=//p' /root/.credentials 2>/dev/null || true)
if [[ -n "$PW" ]]; then
  N=$(curl -fs -u "admin:$PW" http://127.0.0.1:3000/api/v1/provisioning/alert-rules 2>/dev/null \
      | grep -o '"uid":"homelab-[a-z-]*"' | sort -u | wc -l || true)
  C=$(curl -fs -u "admin:$PW" http://127.0.0.1:3000/api/v1/provisioning/contact-points 2>/dev/null \
      | grep -c '"name":"discord-homelab"' || true)
  if [[ "${N:-0}" -eq 3 && "${C:-0}" -ge 1 ]]; then
    msg "Vérifié : 3 alertes et le contact Discord sont chargés."
  else
    echo "Avertissement : ${N:-0} alerte(s) et ${C:-0} contact(s) trouvés (attendu : 3 et 1). Regarde Alerting dans Grafana." >&2
    journalctl -u grafana-server --since "-2 min" --no-pager 2>/dev/null | grep -iE "alerting|provision" | tail -8 >&2 || true
  fi
else
  msg "Mot de passe admin introuvable : chargement non vérifié par l'API."
fi

msg "Envoi d'un message de test sur Discord"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"content":"Alertes Homelab Logs installées. Tu recevras ici les machines silencieuses, les rafales d'"'"'erreurs et les pannes de logs."}' "$URL" || true)
if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
  msg "Message de test envoyé : regarde ton salon Discord."
else
  echo "Avertissement : Discord a répondu ${CODE:-sans réponse}. Vérifie l'URL du webhook." >&2
fi

rm -f "$BACKUP_ENV" "$PROV.bak"
msg "Terminé."
