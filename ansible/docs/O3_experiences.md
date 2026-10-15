# O3 — Deux expériences à documenter

Tableau de bord : Grafana (`http://<IP VM Tools>:3000`) → dossier **NetOps** → « NetOps — Débit des interfaces »
(variables *Équipement* et *Interface*). Les courbes sont nommées `équipement · interface`.

Le panneau affiche `rate(octets) × 8` en **bit/s**. Les compteurs arrivent toutes les 10 s (gNMI, `sample`),
Prometheus les lit toutes les 15 s, et `rate()` lisse sur 4 × 15 s = 60 s : une coupure franche apparaît donc
comme une **pente** d'environ une minute, pas comme une marche.

Chaque expérience se rejoue avec `make`. Trafic de test : `make trafic S=<hôte> D=<IP destination>` (≈ 5 paquets/s de 1 400 octets,
soit environ 58 à 60 kbit/s par sens sur chaque interface du chemin).

> **Règle du jeu.** Les prédictions ci-dessous sont des **propositions** à relire et à corriger avant de lancer quoi que ce soit.
> Une prédiction écrite après la mesure ne compte pas. Les mesures, captures et explications des écarts sont à remplir.

---

## Expérience 1 — Test de panne

**Flux de test :** `lc2 → lc3` (Client 2, VRFB, Paris → Bordeaux), `make trafic S=lc2 D=192.168.1.2`.
Chemin : lc2 → ceb-1 → pe1 (Ethernet3) → pe1 (Ethernet1) → p1 → p2 → p2 (Ethernet2) → pe2 (Ethernet1) → pe2 (Ethernet2) → ceb-2 → lc3.

### 1. Prédiction (avant de toucher quoi que ce soit)

- **Lien coupé :** `p2 Ethernet2 ↔ pe2 Ethernet1` (`make panne`, défaut), la seule liaison qui mène à Bordeaux.
- **Courbes attendues :**
  - débit ≈ 58 kbit/s avant la coupure sur toutes les interfaces du chemin ci-dessus (entrée et sortie) ;
  - après la coupure : `p2 Ethernet2` et `pe2 Ethernet1` tombent à quelques centaines de bit/s (OSPF, LDP, BGP), puis `pe2 Ethernet2` et `ceb-2 Ethernet1/Ethernet2` tombent à ≈ 0, car plus aucun paquet n'arrive ;
  - côté amont, la route `192.168.1.0/24` disparaît de VRFB sur `pe1` (next-hop VPNv4 `pe2` injoignable), et `pe1` la **retire aussi de son eBGP vers `ceb-1`**. `ceb-1` n'a donc plus de route et jette les paquets de `lc2` : seule `ceb-1 Ethernet2` (côté LAN) continue de **recevoir** ≈ 58 kbit/s ; `ceb-1 Ethernet1`, `pe1 Ethernet3`, `pe1 Ethernet1`, `p1` et `p2 Ethernet1` tombent à ≈ 0.
- **Ping `lc2 → lc3` :** 100 % de pertes après la coupure. S'il y a un « Destination unreachable », il vient de `192.168.0.1` (`ceb-1`), pas de `pe1`.
- **Pourquoi :** le cœur est un **arbre** (pas de boucle) : `pe2` n'a qu'un seul lien vers le reste du cœur. Sa loopback disparaît de l'OSPF, le next-hop VPNv4 devient injoignable, la route est retirée de la VRF de `pe1`, et aucun chemin de secours n'existe.
- **Supervision pendant la panne :** `pe2` reste supervisé, car gNMI passe par le réseau de management hors bande (`Management0`, VRF `MGMT`), pas par le cœur.
- **Reprise (dépend de la durée de la panne) :** la session iBGP `pe2 ↔ p1` (RR) ne tombe qu'à l'expiration du *hold-time* BGP (180 s par défaut sur EOS, à vérifier sur le lab : `make cli N=pe2` puis `show ip bgp neighbors` et lire la ligne « Hold time »). Coupure plus courte : retour rapide (OSPF + LDP suffisent). Coupure plus longue : il faut en plus attendre le rétablissement de la session BGP.
- **À vérifier dans votre prédiction :** le délai entre la coupure et le début de la chute dépend de l'échantillonnage (10 s) et du scrape (15 s), pas seulement du réseau.

### 2. Déroulé

1. `make trafic S=lc2 D=192.168.1.2` dans un terminal, attendre un débit stable (≥ 1 min).
2. `make panne` (équivaut à `make panne N=p2 I=Ethernet2`). **Noter l'heure UTC affichée** : c'est l'heure de coupure.
3. Observer Grafana (période 15 min, rafraîchissement 10 s). Capture d'écran.
4. `make reprise` pour rétablir. Noter l'heure et le temps de retour du débit.

### 3. Mesure (à remplir)

| | Valeur |
|---|---|
| Heure de coupure (UTC) | … |
| Heure où le débit commence à chuter | … |
| Délai coupure → chute | … s |
| Heure de rétablissement / retour du débit | … |
| Capture d'écran | `docs/img/panne.png` |

### 4. Écart prédiction / mesure et explication

…

---

## Expérience 2 — Test de chemin

**Flux de test :** `lc1 → lc4` (Client 1, VRFA, Paris → Avignon), `make trafic S=lc1 D=192.168.1.2`.

### 1. Prédiction

Interfaces qui doivent voir du débit (≈ 58 kbit/s, en entrée **et** en sortie puisque le ping est un aller-retour), dans l'ordre :

| # | Équipement | Interface | Face à |
|---|---|---|---|
| 1 | cea-1 | Ethernet2 | lc1 (LAN) |
| 2 | cea-1 | Ethernet1 | pe1 |
| 3 | pe1 | Ethernet2 | cea-1 (VRFA) |
| 4 | pe1 | Ethernet1 | p1 |
| 5 | p1 | Ethernet1 | pe1 |
| 6 | p1 | Ethernet2 | p2 |
| 7 | p2 | Ethernet1 | p1 |
| 8 | p2 | Ethernet3 | pe3 |
| 9 | pe3 | Ethernet1 | p2 |
| 10 | pe3 | Ethernet2 | cea-2 (VRFA) |
| 11 | cea-2 | Ethernet1 | pe3 |
| 12 | cea-2 | Ethernet2 | lc4 (LAN) |

Interfaces qui ne doivent **pas** bouger (seulement le bruit du plan de contrôle : OSPF, LDP, BGP) :
`p2 Ethernet2`, `pe2` (toutes), `pe1 Ethernet3`, `ceb-1`, `ceb-2` (toutes). Ce sont la branche de Bordeaux et le Client 2.

Dans le cœur (lignes 4 à 9), les paquets portent en plus des labels MPLS (4 octets chacun, et un seul sur le dernier saut à cause du PHP) : surcoût de l'ordre de 300 bit/s sur 58 kbit/s, **non mesurable à cette échelle**.

### 2. Mesure

1. Lancer le trafic, relever dans Grafana les interfaces dont le débit monte (variable *Équipement* = Tous).
2. Comparer au plan de contrôle (sur `pe1`, via `make cli N=pe1`) :
   `show ip route vrf VRFA 192.168.1.0/24` (next-hop = loopback de `pe3`) et `show mpls lfib route` (labels du cœur).
3. Contre-épreuve d'étanchéité : refaire le flux `lc2 → lc3` (VRFB) et constater que ce sont d'autres interfaces qui montent (`pe1 Ethernet3`, `ceb-1`, `pe2`, `ceb-2`).

### 3. Constat (à remplir)

- Interfaces qui ont monté : …
- Interfaces qui n'ont pas bougé : …
- Écart avec la prédiction et explication : …
