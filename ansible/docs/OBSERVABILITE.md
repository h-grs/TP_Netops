# Observabilité (O1 · O2 · O3)

```
cEOS (gNMI :6030) ──push──> gnmic (VM Lab, systemd, :9804) <──scrape── Prometheus (VM Tools) ──> Grafana (VM Tools)
```

Tout se lance **depuis la VM Lab** : O1 en local, O2 et O3 en **SSH** vers la VM Tools (`ansible/inventaire-vms.yml`).
Les cEOS sont configurés par l'eAPI, comme le reste du projet. Rien n'est installé sur les équipements (le serveur gNMI est celui d'EOS).

**Hôtes et groupes : ils viennent de Nautobot**, pas de l'inventaire généré par containerlab.
`ansible/nautobot_inventaire.yml` interroge l'API REST de Nautobot (VM Tools, port 8080) : pour le site « Lab G4 », un appel par rôle
(`P` → groupe `p`, `PE` → `pe`, `CE` → `ce`), et chaque équipement rejoint aussi le groupe `arista_ceos`.
Les `group_vars` / `host_vars` du dépôt s'appliquent ensuite normalement. Le play s'arrête avec un message clair si le jeton manque
ou si Nautobot ne contient pas les `nb_noeuds` (9) équipements attendus.

## Mise en route (VM Lab, lab up)

La VM Tools est celle de la variable `TOOLS` du `Makefile` (`utilisateur@IP`, déjà utilisée par `make tools-status`).
Le SSH par clé doit fonctionner sans mot de passe (`ssh -o BatchMode=yes $TOOLS true`). Sinon, une fois :
`ssh-keygen -t ed25519` puis `ssh-copy-id <utilisateur>@<IP VM Tools>`.

```bash
make deploy                      # lab up : les noms p1, pe1, cea-1... sont résolus par /etc/hosts (écrit par containerlab)
make nautobot-up                 # une fois : Nautobot sur la VM Tools
make nautobot-sync               # une fois (et après tout changement de topologie) : remplit Nautobot
make deps-obs
make ssh-tools                   # doit répondre "pong"
make o1 ; make o2 ; make o3      # ou : make obs
```

Le jeton Nautobot est lu dans `creds.env` de la VM Tools (comme `make nautobot-sync`) ; pour le fournir à la main :
`NAUTOBOT_TOKEN=... make o1`. Nautobot ne stocke pas d'adresse IP : les cEOS sont joints par leur nom (`ansible_host` = nom du nœud).
Si O1 signale des noms non résolus, le lab n'est pas déployé (`make deploy`).

`LAB_VM_IP` (IP de la VM Lab vue depuis la VM Tools, cible du scrape :9804) est déduite automatiquement.
Pour forcer une valeur : `make o2 LAB_VM_IP=<IP>` (aussi `TOOLS_VM_IP=`, `TOOLS_VM_USER=`).

Si `sudo` demande un mot de passe : `ANSIBLE_BECOME_ASK_PASS=true make o1` (le même mot de passe est utilisé sur les deux VM ;
sinon, `sudo` sans mot de passe sur la VM Tools).

## Contrôles

| Quoi | Où | Commande |
|---|---|---|
| gnmic | VM Lab | `systemctl status gnmic --no-pager` · `journalctl -u gnmic -n 30 --no-pager` |
| Endpoint | VM Lab | `curl -s localhost:9804/metrics \| grep -c in_octets` |
| Prometheus | VM Tools | `http://<IP VM Tools>:9090/targets` |
| Grafana | VM Tools | `http://<IP VM Tools>:3000` (admin / voir `group_vars/all/observabilite.yml`) |

O2 et O3 se rejouent sans risque (idempotents). **Ordre : O2 avant O3** (le réseau Docker `netops-obs` est créé par O2).
Les projets Compose (`netops-prometheus`, `netops-grafana`) vivent dans `/opt/netops-observabilite` sur la VM Tools,
séparés des autres projets de la machine.

Expériences : `docs/O3_experiences.md` (`make trafic`, `make panne`, `make reprise`).
