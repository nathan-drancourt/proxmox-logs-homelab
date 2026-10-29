```
  _      ___   ____ ____
 | |    / _ \ / ___/ ___|
 | |   | | | | |  _\___ \
 | |___| |_| | |_| |___) |
 |_____|\___/ \____|____/
```

# Homelab Logs : un centre de logs pour Proxmox VE

**Une commande sur l'hôte Proxmox crée un LXC avec Loki et Grafana. Une seconde commande installe l'agent sur tous tes LXC, sur l'hôte et sur tes VM.**

Gratuit. Léger (2 Go de RAM suffisent). Visuel : tableau de bord prêt à l'emploi et Logs Drilldown de Grafana pour naviguer à la souris.

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

Le script pose quelques questions (ID, IP, stockage, rétention) puis crée le conteneur et installe tout. À la fin il affiche l'adresse de Grafana et les mots de passe.

**Conteneur par défaut :** Debian (dernier modèle 12 ou 13) · non privilégié · 2 vCPU · 2 Gio de RAM · 20 Go · démarrage automatique.

Sans question : `bash ct/logs.sh --yes` (les valeurs viennent des variables d'environnement, voir l'en-tête du script).

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
bash tools/deploy-agents.sh 192.168.1.30 --host --docker 201 --vm nathan@192.168.1.40
```

Le script affiche un résumé : `ok`, `ignoré` (système non Debian ou Ubuntu) ou `échec`.

Pour une seule machine : `bash tools/install-alloy.sh IP_LOGS [--docker] [--label NOM]`.

* * *

## Utilisation

Ouvre `http://IP_LOGS:3000` (utilisateur `admin`).

- **Dashboards → Homelab → Homelab / Logs** : la vue d'ensemble. Le champ *Recherche* filtre les lignes en direct.
- **Drilldown → Logs** : navigation visuelle par machine (label `host`), service (`unit`) et niveau (`level`).
- **Explore** : requêtes LogQL, par exemple `{host="glance"} |= "error"`.

Labels disponibles : `host` · `job` (`journal` ou `docker`) · `unit` · `level` · `container`.

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
tools/grafana/homelab-logs.json tableau de bord provisionné
docs/ARCHITECTURE.md            schéma et choix techniques
```

## Licence

[MIT](LICENSE) © 2026 Nathan Drancourt. Aucune garantie.
