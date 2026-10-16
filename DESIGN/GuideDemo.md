# Guide de démo — s'y retrouver en direct

Déroulé détaillé des 4 démos : `DESIGN/DEMO.md`. Ce guide sert à **répondre** et à **rattraper**.
Tout se lance depuis la VM Lab (`10.200.4.120`), dans `~/TP_Netops`. Nautobot : `http://10.200.4.68:8080` · Grafana : `http://10.200.4.68:3000`.

## 1. Repères (à garder sous les yeux)

| Nœud | Loopback | Rôle | Liens |
|---|---|---|---|
| pe1 | 10.0.0.0 | PE Paris, VRFA + VRFB | Et1 → p1 · Et2 → cea-1 (VRFA) · Et3 → ceb-1 (VRFB) |
| p1 | 10.0.0.1 | P + Route Reflector VPNv4 | Et1 → pe1 · Et2 → p2 |
| p2 | 10.0.0.2 | P pur (OSPF + LDP, pas de BGP) | Et1 → p1 · **Et2 → pe2** · Et3 → pe3 |
| pe2 | 10.0.0.3 | PE Bordeaux, VRFB | Et1 → p2 · Et2 → ceb-2 |
| pe3 | 10.0.0.4 | PE Avignon, VRFA | Et1 → p2 · Et2 → cea-2 |

| Filiale | VRF · RT | Paris (pe1) | 2e site |
|---|---|---|---|
| A = Client 1 | `VRFA` · `65000:1` | cea-1 → lc1 `192.168.0.2` | cea-2 (pe3, Avignon) → lc4 `192.168.1.2` |
| B = Client 2 | `VRFB` · `65000:2` | ceb-1 → lc2 `192.168.0.2` | ceb-2 (pe2, Bordeaux) → lc3 `192.168.1.2` |

RD = `<loopback du PE>:<id client>` (ex. `10.0.0.3:2` = pe2, VRFB). Liens cœur `10.10.0.x/31`, PE–CE `172.21.0.x/31`, canaris `10.255.<client>.<site>/32`.
`make trafic` (défaut `lc2 → 192.168.1.2`) arrive sur **lc3** : c'est la VRF de la source qui décide, pas l'adresse.

## 2. « Où est… ? » — question du jury → réponse

| Question | Où montrer | Commande |
|---|---|---|
| La topologie ? | `netops.clab.yaml` | `make inspect` |
| La config d'un routeur ? | n'est stockée nulle part : **rendue** depuis gabarits + données | `make render N=pe1` → `rendu/pe1.cfg` |
| Les données d'un équipement ? | Nautobot (fait foi) → copie lue par Ansible | `ansible/sot/host_vars/pe1.yml` après `make sot-pull` |
| Les règles réseau (AS cœur, RT, RR) ? | Git | `ansible/group_vars/all/network.yml` |
| Qui sont les équipements ? | inventaire **généré** par containerlab | `clab-netops/ansible-inventory.yml` |
| Changer l'AS d'un CE ? | Nautobot → CE → *Local config context* `asn` | `make plan N=cea-1` puis `make run` |
| Ajouter un site ? | Nautobot : CE + poste + interfaces + IP + câbles | `make run && make checkup` |
| Le test de bout en bout ? | `ansible/100-checkup_escalier.yml` (figé) | `make checkup` |
| Preuve qu'il n'a pas bougé ? | historique Git | `git diff avant-j4 HEAD -- ansible/100-checkup_escalier.yml` (vide) |
| Quel commit = quel jalon ? | tags | `git tag` → `avant-j4`, `j4`, `sot-phase1..3` |
| La supervision ? | `ansible/observabilite/templates/gnmic.yaml.j2` (O1) · `tools/observabilite/` (O2/O3) | `make obs-status` |
| Les secrets ? | jamais dans Git : jeton Nautobot lu sur la VM Tools (`creds.env`), mot de passe Grafana dans `.env` | — |

## 3. Phrases clés (cours)

- **VRF / RD / RT** : la VRF sépare localement, le RD rend la route unique dans VPNv4, le RT décide qui importe quoi. MPLS sert la scalabilité, pas la sécurité.
- **RR** : 3 sessions vers p1 au lieu d'un maillage complet n(n-1)/2 entre PE ; p1 ne porte aucune VRF.
- **P agnostique** : p1/p2 commutent des labels (LDP), aucune route client (`show ip route | include 192.168` → vide).
- **Qui / quoi** : containerlab dit *qui* existe (inventaire), Nautobot dit *quoi* configurer (données), Git dit *comment* (playbooks, gabarits, règles).
- **Idempotence ≠ conformité** (diapos 18-19) : `lines:` pousse des commandes, pas un état ; ce qui n'est pas cité n'est pas retiré. Suite logique : pousser le rendu J4 complet (`replace: config`).
- **Vérifier ≠ observer** (diapos 35-36) : le checkup répond oui/non à un instant ; gNMI → Prometheus → Grafana montre l'évolution dans le temps.
- **Push / pull** : les cEOS poussent en gNMI vers gnmic (abonnement), Prometheus tire l'endpoint `:9804` toutes les 15 s.

## 4. Si ça casse

| Symptôme | Cause probable | Rattrapage |
|---|---|---|
| `sot-pull` échoue / `curl` 000 | Nautobot arrêté ou en démarrage (1-2 min) | `make nautobot-up`, attendre ; sinon ajouter `OFFLINE=1` à la commande |
| Checkup rouge juste après `deploy` | cEOS pas encore prêts, OSPF/BGP en convergence | relancer `make checkup` (il réessaie 60 s) |
| `closedness` : « MANQUANT » | le canari n'a pas encore été propagé par BGP | relancer `make closedness` |
| Grafana vide après la démo 1 | gNMI non reconfiguré sur les cEOS recréés | `make obs-status` ; si < 9 nœuds : `make o1 K=1` |
| `obs-status` : gnmic `inactive` | service arrêté | `sudo systemctl restart gnmic` puis `make obs-status` |
| Plus de trafic après la démo 4 | interface laissée coupée | `make reprise` |
| `make run` modifie quelque chose en démo 3 | Loopback99 de la répétition restée | `make cli N=pe2` → `configure` → `no interface Loopback99` |
| Tout est perdu | — | `make destroy && make deploy && make run && make checkup` (c'est la démo 1) |

## 5. Ordre de la journée

1. Avant le jury : `make tools-status` · `make nautobot-backup` · `make sot-pull` · `make obs-status`.
2. Démo 1 → **puis** `make obs-status` (9 nœuds ?) avant d'enchaîner.
3. Démo 2 → démo 3 (penser au retrait de Loopback99) → démo 4 (penser à `make reprise`).