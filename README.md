# TP NetOps — MPLS L3VPN (containerlab + Ansible)

Cœur MPLS à 2 P et 3 PE (Arista cEOS), deux clients aux **mêmes LAN**, isolés par VRF.
Tout se pilote avec `make` depuis la VM lab. Tape `make help` pour la liste des cibles.

## Les deux VMs

| VM | IP | Rôle | Fichiers |
|---|---|---|---|
| lab | `10.200.4.120` | containerlab + Ansible | ce dépôt **sans** `tools/` (sparse-checkout) |
| tools | `10.200.4.68` | Nautobot (13 équipements : 9 cEOS + 4 postes) | **uniquement** `tools/` de ce dépôt (sparse-checkout), + `~/nautobot-docker-compose` ; piloté en SSH par ce Makefile |

### Un dépôt, deux VMs (sparse-checkout)

Chaque VM ne récupère que sa partie du même dépôt :

```bash
# VM lab   : tout sauf tools/
git sparse-checkout set --no-cone '/*' '!/tools/'
# VM tools : seulement tools/
git sparse-checkout set --no-cone '/tools/'
```

Chaque VM commite sa partie ; toujours `git pull` avant de travailler.

## Topologie

```
cea-1 ┐                         ┌ pe2 ── ceb-2
      ├ pe1 ── p1 (RR) ── p2 ───┤
ceb-1 ┘                         └ pe3 ── cea-2

cœur (P + PE) : OSPF + LDP    iBGP VPNv4 : chaque PE ↔ p1    eBGP : chaque CE ↔ son PE
```

| Client | VRF | Sites (CE → poste) | LAN |
|---|---|---|---|
| 1 | `VRFA` | cea-1 → lc1 · cea-2 → lc4 | 192.168.0.0/24 et 192.168.1.0/24 |
| 2 | `VRFB` | ceb-1 → lc2 · ceb-2 → lc3 | 192.168.0.0/24 et 192.168.1.0/24 |

Les deux clients utilisent les **mêmes LAN** : seule la VRF les sépare.

| Plan d'adressage | Plage |
|---|---|
| Loopbacks du cœur | `10.0.0.x/32` (stockées **sans masque** dans `host_vars`) |
| Liens du cœur | `10.10.0.x/31` |
| Liens PE–CE | `172.21.0.x/31` |
| AS cœur / AS des CE | `65000` / un AS par CE (`asn` dans `host_vars`) |

## Démarrage

```bash
make deps          # une seule fois : netaddr + collections Ansible
make deploy        # crée les 13 conteneurs
make run           # applique tout : cœur, MP-BGP, VRF
make checkup       # vérifie
make nautobot-up   # démarre Nautobot sur la VM tools
```

`make destroy` détruit le lab. La config non sauvegardée est perdue : rejouer `make run`.

## Les cibles

| Cible | Effet |
|---|---|
| `deploy` / `destroy` / `inspect` | Cycle de vie du lab, état des nœuds |
| `coeur` | Playbook 1 : OSPF + MPLS/LDP |
| `mpbgp` | Playbook 2 : MP-BGP VPNv4, p1 est Route Reflector |
| `vrf` | Playbook 3 : VRF, eBGP PE–CE, CE |
| `run` | Les 3 playbooks d'affilée |
| `plan N=pe1` | Diff avec la config réelle, **sans appliquer** |
| `checkup` | Checkup en 4 barreaux, lecture seule (dont ping des postes) |
| `closedness` | Test d'étanchéité entre clients |
| `cli N=p1` | Ouvre la CLI d'un nœud (le lab doit être up) |
| `tools-status` | Conteneurs qui tournent sur la VM tools |
| `nautobot-up` / `nautobot-down` | Démarre / arrête Nautobot sur la VM tools |
| `nautobot-tasks` | Liste les commandes `invoke` disponibles |
| `nautobot-sync` | Alimente Nautobot : 9 nœuds Arista + 4 postes clients |
| `nautobot-devices` | Liste les équipements présents dans Nautobot |

## Vérifier

**`make checkup`** : un barreau par couche, le premier échec arrête tout.

1. Sous-jacent : OSPF FULL, loopbacks en table, sessions LDP
2. Plan de contrôle : VPNv4 PE ↔ RR, eBGP PE ↔ CE
3. Plan de données : routes dans chaque VRF, aucune route client sur les P
4. Trafic : chaque poste (lc1 à lc4) pingue le poste de l'autre site de son client (`docker exec`)

**`make closedness`** : prouve l'isolation. Comme les LAN sont identiques, on ne peut pas
chercher « le LAN de l'autre client ». On pose à la place un **canari**, une loopback
`10.255.<client>.x` propre à chaque client (variable `canary` dans `host_vars` des CE),
puis on vérifie qu'il n'apparaît que dans la VRF de son client. Il est retiré après le test,
même en cas d'échec.

## Nautobot (VM tools)

- Dossier : `~/nautobot-docker-compose` sur la VM tools (projet officiel `nautobot-docker-compose`).
- Lancé avec `invoke` (via poetry), qui assemble les fichiers compose de `environments/`.
  Toujours passer par `make nautobot-up` / `nautobot-down` : on garde le même projet Compose,
  donc la même base.
- Interface : `http://10.200.4.68:8080`, utilisateur `admin`, mot de passe dans
  `environments/creds.env` (secrets, **jamais commité**).
- Le démarrage prend une à deux minutes : avant, `curl` renvoie `000`.
- Vérifier : `curl -s -o /dev/null -w "%{http_code}\n" http://10.200.4.68:8080/health/` → `200`.
- **Ne jamais lancer `invoke destroy`** : il supprime les volumes, donc la base.

## Où modifier quoi

```
ansible/
  group_vars/all/   données du réseau : AS du cœur, tenants (id, RT), RR
  host_vars/        données par équipement : loopback, raccordements, uplink, lan, asn, tenant
  01-coeur.yml  02-mpbgp.yml  03-vrf.yml  run.yml
  100-checkup_escalier.yml      NE PAS MODIFIER (figé par le tag avant-j4)
  200-canary.yml  200-closed_network.yml   test d'étanchéité
  300-nautobot-sync.yml  nautobot_ensure.yml  inventaire → Nautobot
```

Ajouter un site : créer son `host_vars/`, vérifier que `tenant` porte **le nom de la VRF**,
rejouer `make run`, puis `make checkup`.

Preuve que le checkup n'a pas bougé pendant J4 :
`git diff avant-j4 HEAD -- ansible/100-checkup_escalier.yml` doit être vide.

## Pièges connus

- Un `tenant` qui ne porte pas le nom de la VRF fait **ignorer le CE en silence** par le
  checkup : les tests du client concerné semblent passer sans rien prouver.
- Les commandes `ansible-*` se lancent depuis `ansible/` (le Makefile le fait déjà).
- Le Makefile exige des **tabulations**, pas des espaces.