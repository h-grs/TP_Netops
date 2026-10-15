# TP NetOps — MPLS L3VPN (containerlab + Ansible)

Cœur MPLS à 2 P et 3 PE (Arista cEOS), deux clients aux **mêmes LAN**, isolés par VRF.
Tout se pilote avec `make`. Tape `make help` pour la liste des cibles.

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
make deps      # une seule fois : netaddr + collections Ansible
make deploy    # crée les 13 conteneurs
make run       # applique tout : cœur, MP-BGP, VRF
make checkup   # vérifie
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
| `plan [N=pe1]` | Diff avec la config réelle, **sans appliquer** |
| `checkup` | Checkup en 4 barreaux, lecture seule |
| `closedness` | Test d'étanchéité entre clients |
| `render N=pe1` | (J4 — pas encore disponible) Affiche le rendu d'un gabarit, sans l'appliquer |
| `cli N=p1` | Ouvre la CLI d'un nœud (le lab doit être up) |

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

## Où modifier quoi

```
ansible/
  group_vars/all/   données du réseau : AS du cœur, tenants (id, RT), RR
  host_vars/        données par équipement : loopback, raccordements, uplink, lan, asn, tenant
  01-coeur.yml  02-mpbgp.yml  03-vrf.yml  run.yml
  100-checkup_escalier.yml      NE PAS MODIFIER
  200-canary.yml  200-closed_network.yml   test d'étanchéité
```

Ajouter un site : créer son `host_vars/`, vérifier que `tenant` porte **le nom de la VRF**,
rejouer `make run`, puis `make checkup`.