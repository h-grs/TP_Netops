# Déroulé de la démonstration (PoC)

Tout se lance depuis la **VM Lab**, dans `~/TP_Netops`. Grafana : `http://10.200.4.68:3000` → dossier **NetOps**.

**Avant de commencer** (5 min avant) :
```bash
make tools-status            # Nautobot + Prometheus + Grafana : Up
make nautobot-backup         # filet de sécurité
make sot-pull                # Nautobot répond → sinon ajouter OFFLINE=1 aux commandes
```
Deux terminaux ouverts sur la VM Lab, Grafana ouvert sur « État du réseau ».

| Repère | Filiale A = Client 1 = `VRFA` | Filiale B = Client 2 = `VRFB` |
|---|---|---|
| Paris (pe1) | cea-1 → lc1, `192.168.0.0/24` | ceb-1 → lc2, `192.168.0.0/24` |
| 2e site | cea-2 (Avignon, pe3) → lc4, `192.168.1.0/24` | ceb-2 (Bordeaux, pe2) → lc3, `192.168.1.0/24` |

---

## Démo 1 — Déploiement complet (< 20 min)

```bash
make destroy                                          # point de départ : plus rien
time (make deploy && make run && make checkup)        # chronomètre : de la création au checkup vert
```

| Montrer | Ce qu'on dit |
|---|---|
| `netops.clab.yaml` | la topologie est un fichier versionné (J1) |
| défilement de `make run` | 3 playbooks par couche : cœur (OSPF+LDP) → VPNv4 → VRF/CE. Aucune saisie sur un équipement (J2) |
| 4 barreaux verts du checkup | sous-jacent → plan de contrôle → plan de données → trafic, arrêt au premier barreau cassé |
| ligne `real` de `time` | la durée mesurée |

Les données viennent de **Nautobot** (`sot-pull` en premier) ; l'inventaire, de containerlab.

---

## Démo 2 — Étanchéité entre filiales

Même adresse, deux réseaux séparés : `192.168.1.0/24` existe **chez les deux filiales**.

```bash
make cli N=pe1
show ip route vrf VRFA 192.168.1.0/24      # next-hop 10.0.0.4 = pe3 (Avignon, filiale A)
show ip route vrf VRFB 192.168.1.0/24      # next-hop 10.0.0.3 = pe2 (Bordeaux, filiale B)
exit
make cli N=p1
show bgp vpn-ipv4 | include 192.168.1.0    # 2 routes, RD différents (10.0.0.4:1 et 10.0.0.3:2) : VPNv4 les rend uniques
show ip route | include 192.168            # rien : le cœur ne porte aucune route client (P agnostique)
exit
```

Test de joignabilité entre filiales, avec le **canari** (une loopback `10.255.<client>.x` propre à chaque CE) :
```bash
make closedness          # pose le canari, vérifie qu'il n'apparaît QUE dans la VRF de sa filiale, le retire
```

| Ce qu'on vérifie (diapo) | Preuve |
|---|---|
| Le même préfixe existe chez les deux filiales | les deux `show ip route vrf` sur pe1 |
| Chaque filiale ne reçoit que ses propres routes | `make closedness` vert (RT import/export par filiale) |
| La joignabilité entre filiales n'aboutit pas | pas de route = pas de chemin : le canari B est absent de VRFA |

Phrase clé (cours) : *la VRF sépare localement, le RD rend unique, le RT cloisonne ; MPLS sert la scalabilité, pas la sécurité.*

---

## Démo 3 — Reproductibilité et idempotence

La reproductibilité vient d'être prouvée par la démo 1 (destroy → deploy → rejeu → checkup vert).

**Idempotence** — second passage sur lab configuré :
```bash
make run 2>&1 | tail -12          # PLAY RECAP : changed=0 sur les 9 nœuds
```

**Idempotence ≠ conformité** — une ligne posée à la main :
```bash
make cli N=pe2                    # configure → interface Loopback99 → description ajout-manuel → end → exit
make run 2>&1 | tail -12          # toujours changed=0…
make cli N=pe2                    # show running-config interfaces Loopback99 → la ligne est toujours là
```
Explication (cours, diapos 18-19) : la chaîne pousse des **commandes** (`lines:`), pas un **état** complet.
Ce qui n'est pas mentionné reste tel quel : on obtient l'idempotence, pas la conformité.
`make conforme` vérifie que le voulu est présent, pas que le reste est absent.

Remise en état :
```bash
make cli N=pe2                    # configure → no interface Loopback99 → end
```

---

## Démo 4 — Supervision

```bash
make obs-status                   # gnmic actif, 9 nœuds exposés, conteneurs Prometheus + Grafana
```

| Montrer dans Grafana | Ce qu'on dit |
|---|---|
| « État du réseau » : 9 nœuds, 0 DOWN, 14 sessions BGP | **vérifier** : collecte gNMI sur les 9 routeurs (push), stockés par Prometheus (pull) |
| « Débit des interfaces » | débit = `rate(octets) × 8`, par équipement et par interface |

**Test de panne** :
```bash
make trafic S=lc2 D=192.168.1.2   # terminal 1 : filiale B, Paris → Bordeaux, laisser 1 min
make panne                        # terminal 2 : coupe p2 Ethernet2 (lien vers pe2) — noter l'heure UTC
#   → frise « Interfaces » : p2·Ethernet2 et pe2·Ethernet1 passent en rouge
#   → débit vers Bordeaux tombe à 0 (pente d'environ 1 min : échantillon 10 s, scrape 15 s, rate)
#   → frise « Sessions BGP » : pe2 → RR quitte ESTABLISHED à l'expiration du hold-time
#   → pe2 reste supervisé : gNMI passe par le management hors bande, pas par le cœur
make reprise                      # rétablit ; tout repasse au vert
```

Le sujet demande de **prédire par écrit, puis mesurer** : la prédiction est dans
`ansible/docs/O3_experiences.md` (commitée avant la mesure), on la compare à l'écran.