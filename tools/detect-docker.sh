#!/usr/bin/env bash
# À lancer sur l'hôte Proxmox : indique quels LXC démarrés ont Docker installé.
# Sert à choisir les ID à passer à : deploy-agents.sh IP_LOKI --docker ID[,ID...]
set -Eeuo pipefail

command -v pct >/dev/null 2>&1 || { echo "pct introuvable : lance ce script sur l'hôte Proxmox." >&2; exit 1; }

docker_ids=()
for id in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
  name=$(pct exec "$id" -- hostname 2>/dev/null || echo "?")
  if pct exec "$id" -- bash -c 'command -v docker >/dev/null 2>&1' 2>/dev/null; then
    echo "LXC $id ($name) : DOCKER"
    docker_ids+=("$id")
  else
    echo "LXC $id ($name) : non"
  fi
done

if [[ ${#docker_ids[@]} -gt 0 ]]; then
  echo
  echo "Option à utiliser : --docker $(IFS=,; echo "${docker_ids[*]}")"
fi
