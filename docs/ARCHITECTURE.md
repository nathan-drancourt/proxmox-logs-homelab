# Architecture

```
  LXC / VM / hôte Proxmox                      LXC « logs »
 ┌──────────────────────────┐   HTTP 3100    ┌───────────────────────────┐
 │ systemd-journal          │ ─────────────► │ Loki   (stockage, 3100)   │
 │ Docker (option)          │   push         │ Grafana (interface, 3000) │
 │   └─ Grafana Alloy      │                │   dashboards + Drilldown  │
 └──────────────────────────┘                └───────────────────────────┘
```

## Choix techniques

- **Paquets APT officiels de Grafana** (Loki, Grafana, Alloy) plutôt que Docker : pas d'imbrication dans le LXC, moins de RAM, mises à jour par `apt`.
- **Alloy** remplace Promtail (en fin de vie). Un seul binaire par machine.
- **Journal systemd** comme source principale : tous les services d'un LXC Debian y écrivent. Les conteneurs Docker sont collectés à part avec `--docker`.
- **Schéma TSDB v13** et `volume_enabled` : requis pour Logs Drilldown.
- **Rétention** gérée par le compactor de Loki (`retention_enabled`).

## Labels

| Label | Origine |
|---|---|
| `host` | nom d'hôte de la machine (ou `--label`) |
| `job` | `journal` ou `docker` |
| `unit` | unité systemd |
| `level` | priorité du journal (`err`, `warning`, `info`...) |
| `container` | nom du conteneur Docker |

## Ports

| Port | Service | Exposition |
|---|---|---|
| 3000 | Grafana | LAN |
| 3100 | Loki (push et API) | LAN uniquement |
| 12345 | Alloy (UI locale) | 127.0.0.1 |

## Ajouter une source

Pour lire un fichier de log précis (Nginx Proxy Manager, par exemple), ajoute un bloc dans `/etc/alloy/config.alloy` de la machine concernée :

```
local.file_match "npm" {
  path_targets = [{ __path__ = "/data/logs/*.log", job = "npm", host = "nginxproxymanager" }]
}
loki.source.file "npm" {
  targets    = local.file_match.npm.targets
  forward_to = [loki.write.default.receiver]
}
```

Puis `systemctl restart alloy`. Attention : `install-alloy.sh` réécrit ce fichier. Garde tes ajouts dans un fichier à part ou relance le script avant de les remettre.

## Désinstallation

- Agent : `apt purge alloy` dans la machine.
- Centre de logs : `pct stop <ctid> && pct destroy <ctid>`.
