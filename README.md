```
  _      ___   ____ ____
 | |    / _ \ / ___/ ___|
 | |   | | | | |  _\___ \
 | |___| |_| | |_| |___) |
 |_____|\___/ \____|____/
```

# Homelab Logs : un script qui crée un centre de logs (Grafana + Loki) sur Proxmox VE

**Homelab Logs est un script d'installation pour Proxmox VE. Lancé sur l'hôte, il crée un conteneur LXC et y installe un centre de logs complet : Loki stocke les logs et Grafana les affiche. Un second script déploie l'agent Grafana Alloy sur tes LXC, tes VM et l'hôte pour envoyer leurs logs au centre.**

Gratuit. Léger (2 Go de RAM suffisent). Tableau de bord prêt à l'emploi et Logs Drilldown de Grafana pour naviguer à la souris.

## Comment ça marche

1. `ct/logs.sh` s'exécute sur l'hôte Proxmox : il crée le LXC et y installe Loki et Grafana.
2. `tools/deploy-agents.sh` installe Grafana Alloy sur les machines à surveiller.
3. Tu consultes tous les logs dans Grafana, à l'adresse affichée à la fin de l'installation.

Inspiré de [community-scripts.org](https://community-scripts.org) · licence MIT

* * *

## Ce que tu obtiens

- Un LXC Debian non privilégié : **Loki** (stockage des logs) et **Grafana** (interface).
- Un tableau de bord **Homelab / Logs** : volume par machine, erreurs, services les plus bavards, logs avec champ de recherche.
- **Logs Drilldown** : tu cliques sur une machine ou un service sans écrire de requête.
- Un script d'agent **Grafana Alloy** qui envoie le journal systemd de chaque machine, et les logs Docker si tu le demandes.
- Une rétention réglable (14 jours par défaut) pour ne jamais saturer le disque.

* * *

## Installation

Sur l'hôte **Proxmox VE** (root) :

```
bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/ct/logs.sh)"
```

Comme les scripts community-scripts, il propose un menu **Par défaut** ou **Avancé** (ID, IP, stockage, rétention). Dans les deux cas, il te **propose de renommer le conteneur** : Entrée garde le nom par défaut `Grafana`, ou tape un autre nom (lettres, chiffres et tirets). Il crée ensuite le conteneur complet et installe tout. À la fin il affiche l'adresse de Grafana et les mots de passe.

**Conteneur par défaut :** nom `Grafana` · Debian (dernier modèle 12 ou 13) · non privilégié · 2 vCPU · 2 Gio de RAM · 20 Go · démarrage automatique.

Le nom du conteneur devient aussi le nom de cette machine dans Grafana (label `host`).

Sans aucune question : `bash ct/logs.sh --yes` (les valeurs viennent des variables d'environnement, par exemple `CT_NAME=Monitoring`, voir l'en-tête du script).

> Donne une **IP fixe** au conteneur (ou une réservation DHCP dans ta box). Les agents s'y connectent.

* * *

## Installer les agents

Depuis l'hôte Proxmox :

```
git clone https://github.com/nathan-drancourt/proxmox-logs-homelab
cd proxmox-logs-homelab
bash tools/deploy-agents.sh IP_LOGS --host
```

Options utiles :

| Option | Effet |
|---|---|
| `--host` | installe aussi l'agent sur l'hôte Proxmox |
| `--docker 201` | collecte aussi les conteneurs Docker du LXC 201 |
| `--skip 100,105` | ignore ces LXC |
| `--vm user@ip` | équipe une VM Linux via SSH (répétable) |

Exemple complet :

```
bash tools/deploy-agents.sh 192.168.1.30 --host --docker 201 --vm utilisateur@192.168.1.40
```

Le script affiche un résumé : `ok`, `ignoré` (système non Debian ou Ubuntu) ou `échec`.

Pour savoir quels LXC ont Docker (donc quels ID passer à `--docker`) :

```
bash tools/detect-docker.sh
```

Pour une seule machine : `bash tools/install-alloy.sh IP_LOGS [--docker] [--label NOM]`.

* * *

## Utilisation

Ouvre `http://IP_LOGS:3000` (utilisateur `admin`).

- **Dashboards → Homelab → Homelab / Logs** : la vue d'ensemble. De haut en bas : quatre indicateurs (machines actives, logs et erreurs sur 1 h, erreurs sur 5 min), deux graphiques par machine, les sources les plus bavardes, les dernières erreurs, puis tous les logs. Chaque ligne commence par `[machine] service`. Le champ *Recherche* filtre les lignes en direct. Survole le titre d'un panneau pour lire son explication.
- **Drilldown → Logs** : navigation visuelle par machine (label `host`), service (`unit`) et niveau (`level`).
- **Explore** : requêtes LogQL, par exemple `{host="glance"} |= "error"`.

Le compte d'erreurs (indicateurs, vignettes, alerte) ignore le bruit connu : requêtes annulées de Loki et Grafana, messages d'information qui contiennent le mot « error », et le refus AppArmor de `rsyslogd` dans un LXC (conflit de profil inoffensif). Les autres refus AppArmor restent comptés. Pour changer la liste, modifie le filtre `!~ "..."` des requêtes du tableau de bord.

Labels disponibles : `host` · `job` (`journal` ou `docker`) · `unit` · `level` · `container`.

### Page web simple (facultatif)

Une page plus légère que Grafana : une carte par machine (état, courbe, logs, erreurs), un filtre par période, une recherche et le fil des dernières lignes. Elle s'installe dans le LXC des logs avec nginx, sur le port 8080 :

```
pct exec <ctid> -- bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/tools/install-dashboard.sh)"
```

Ouvre ensuite `http://IP_LOGS:8080/`. Le relais vers Loki est en lecture seule. Pour changer le port : `DASHBOARD_PORT=9000`. Pour mettre la page à jour, relance la même commande.

### Alertes sur Discord (facultatif)

Quatre alertes Grafana préviennent dans un salon Discord :

| Alerte | Se déclenche quand |
|---|---|
| Machine silencieuse | une machine connue n'a plus envoyé de log depuis 3 h |
| Erreur grave | mémoire saturée (OOM), disque plein ou en erreur, plantage du noyau ou d'un programme, arrêt d'un service important (alloy, vaultwarden, loki, grafana-server, jellyfin, docker, pve, tailscaled, AdGuardHome, nginx), ou niveau « crit » du journal |
| Plus aucun log reçu | Loki ne reçoit plus rien depuis 10 min |
| VPN Gluetun ne revient pas | le conteneur `gluetun` relance son VPN en boucle (plus de 2 fois en 10 min) sans se rétablir. Un redémarrage isolé, qui se règle seul en quelques secondes, ne prévient pas. Cette alerte ne concerne que les conteneurs nommés `gluetun` |

Le simple mot « error » dans un log ne déclenche rien : il reste visible dans le tableau de bord mais ne dérange pas Discord. Sur un homelab réel, cette définition donne quelques messages par mois au plus. Pour ajouter un service à surveiller, modifie la liste dans la règle « Erreur grave » de `/etc/grafana/provisioning/alerting/homelab.yaml`, puis `systemctl restart grafana-server`.

Chaque message indique la gravité (⚠️ ou 🚨), la machine, la valeur mesurée, depuis quand (l'heure relative s'affiche dans ton fuseau horaire) et un lien vers le tableau de bord filtré sur cette machine. Un second message 🟢 arrive quand tout rentre dans l'ordre.

1. Dans Discord : **Paramètres du serveur, Intégrations, Webhooks, Nouveau webhook**, choisis le salon, puis **Copier l'URL du webhook**. Cette URL est un secret : ne la colle ni dans un message ni dans le dépôt.
2. Sur l'hôte Proxmox, l'URL est demandée sans s'afficher puis transmise au LXC :

```
read -rsp "Webhook Discord : " W; echo
pct exec <ctid> -- env DISCORD_WEBHOOK_URL="$W" bash -c "$(wget -qLO - https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/tools/install-alerts.sh)"
```

Le script enregistre l'URL dans `/etc/default/grafana-server` (droits 640), crée les alertes, redémarre Grafana et envoie un message de test. Si Grafana ne redémarre pas, tout est annulé. Pour changer un seuil, modifie `/etc/grafana/provisioning/alerting/homelab.yaml` puis `systemctl restart grafana-server`. Pour désactiver : supprime ce fichier et redémarre Grafana.

* * *

## Disque et rétention

La rétention se règle à l'installation (`LOGS_RETENTION_DAYS`) ou dans `/etc/loki/config.yml` (`retention_period`, en heures) puis `systemctl restart loki`. Compter quelques centaines de Mo par mois pour un homelab de dix machines. Surveille `/var/lib/loki`.

* * *

## Sécurité

- Loki (port 3100) n'a **pas d'authentification** : garde-le sur ton réseau local et ne l'expose jamais sur Internet.
- Grafana demande un mot de passe généré à l'installation. Pour l'ouvrir à l'extérieur, passe par un reverse proxy avec HTTPS.
- Les mots de passe sont dans `/root/.credentials` du conteneur (droits 600).

* * *

## Mise à jour

```
pct enter <ctid>
apt update && apt install --only-upgrade loki grafana
```

Même principe pour l'agent : `apt install --only-upgrade alloy` dans chaque machine.

Pour récupérer la dernière version du tableau de bord, depuis l'hôte Proxmox (Grafana le recharge seul en quelques secondes) :

```
pct exec <ctid> -- wget -qO /var/lib/grafana/dashboards/homelab-logs.json https://raw.githubusercontent.com/nathan-drancourt/proxmox-logs-homelab/main/tools/grafana/homelab-logs.json
```

* * *

## Dépannage

| Symptôme | Piste |
|---|---|
| Grafana n'affiche aucune machine | `systemctl status alloy` sur la machine, puis `curl http://IP_LOGS:3100/ready` |
| `échec` sur un LXC | `pct exec ID -- journalctl -u alloy -n 30` |
| `ignoré (pas Debian/Ubuntu)` | installer Alloy à la main : [doc officielle](https://grafana.com/docs/alloy/latest/set-up/install/) |
| Pas de logs Docker | relancer l'agent avec `--docker` puis vérifier que `alloy` est dans le groupe `docker` |
| Panneau vide dans le tableau de bord | élargir la période en haut à droite (les logs arrivent après un court délai) |

* * *

## Structure du dépôt

```
ct/logs.sh                      à lancer sur l'hôte Proxmox (crée le LXC)
install/logs-install.sh         provisionnement dans le conteneur (Loki + Grafana)
tools/install-alloy.sh          agent pour une machine Debian ou Ubuntu
tools/deploy-agents.sh          déploiement en masse (LXC, hôte, VM)
tools/detect-docker.sh          liste les LXC qui ont Docker
tools/install-dashboard.sh      installe la page web simple (nginx) dans le LXC des logs
tools/web/index.html            la page web
tools/install-alerts.sh         installe les alertes Discord (Grafana)
tools/grafana/homelab-logs.json tableau de bord provisionné
docs/ARCHITECTURE.md            schéma et choix techniques
```

## Licence

[MIT](LICENSE) © 2026 Nathan Drancourt. Aucune garantie.
