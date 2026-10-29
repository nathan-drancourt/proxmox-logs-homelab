#!/usr/bin/env bash
# Installe l'agent Grafana Alloy sur une machine Debian/Ubuntu (LXC, VM ou hôte Proxmox).
# Il lit le journal systemd et l'envoie à Loki.
#
# Usage : install-alloy.sh IP_LOKI [--docker] [--label NOM]
#   --docker   collecte aussi les logs des conteneurs Docker (ajoute alloy au groupe docker)
#   --label    valeur du label "host" (défaut : nom d'hôte de la machine)
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

LOKI_IP="${1:-}"
[[ -n "$LOKI_IP" && "$LOKI_IP" != --* ]] || { echo "Usage : $0 IP_LOKI [--docker] [--label NOM]" >&2; exit 1; }
shift

DOCKER=0
HOST_LABEL="$(hostname)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) DOCKER=1 ;;
    --label)  HOST_LABEL="${2:?valeur manquante pour --label}"; shift ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "À lancer en root." >&2; exit 1; }
if ! command -v apt-get >/dev/null 2>&1; then
  echo "Système non Debian/Ubuntu : installation d'Alloy à faire à la main (voir docs)." >&2
  exit 2
fi

apt-get update -qq
apt-get install -y -qq ca-certificates gpg wget >/dev/null
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y -qq alloy >/dev/null

{
  cat <<EOF
// Géré par proxmox-logs-homelab : ne pas modifier à la main.
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "read" {
  forward_to    = [loki.write.default.receiver]
  relabel_rules = loki.relabel.journal.rules
  max_age       = "12h"
  labels        = { job = "journal", host = "${HOST_LABEL}" }
}

loki.write "default" {
  endpoint {
    url = "http://${LOKI_IP}:3100/loki/api/v1/push"
  }
}
EOF
  if [[ $DOCKER -eq 1 ]]; then
    cat <<EOF

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers.output
  forward_to = [loki.write.default.receiver]
  labels     = { job = "docker", host = "${HOST_LABEL}" }
}
EOF
  fi
} > /etc/alloy/config.alloy

usermod -aG systemd-journal alloy 2>/dev/null || true
[[ $DOCKER -eq 1 ]] && usermod -aG docker alloy
systemctl enable alloy >/dev/null 2>&1
systemctl restart alloy
sleep 2
systemctl is-active --quiet alloy && echo "Alloy actif sur ${HOST_LABEL} -> ${LOKI_IP}:3100" \
  || { echo "Alloy ne démarre pas : journalctl -u alloy" >&2; exit 3; }
