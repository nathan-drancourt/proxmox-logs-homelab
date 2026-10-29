# Changelog

## Non publié

- Tableau de bord simplifié : indicateurs en haut, panneau des dernières erreurs, machine et service au début de chaque ligne, explication de chaque panneau au survol.
- Le compte d'erreurs ignore les lignes que Loki et Grafana écrivent sur leurs propres requêtes.
- Le panneau des sources les plus bavardes inclut les conteneurs Docker.
- Ajout de `tools/detect-docker.sh` (liste les LXC qui ont Docker).
- Ajout facultatif d'une page web simple (`tools/web/index.html`) et de son installation nginx (`tools/install-dashboard.sh`).
- Corrections : choix du modèle Debian selon l'architecture, propriétaire de Loki, prérequis de l'agent non mis à jour.

## 0.1.0 (2026-10-29)

- Création du LXC « logs » avec Loki et Grafana (`ct/logs.sh`).
- Tableau de bord Homelab / Logs provisionné.
- Agent Grafana Alloy (`tools/install-alloy.sh`) avec option Docker.
- Déploiement en masse sur LXC, hôte et VM (`tools/deploy-agents.sh`).
