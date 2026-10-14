# TP NetOps — MPLS L3VPN

Toutes les commandes se lancent depuis la racine du dépôt. `make help` liste les cibles.

## Une seule fois

```bash
make deps        # collections DONT IP FILTER !! (netaddr déjà installé)
```

## J1 — Le lab

```bash
make deploy      # crée les 13 conteneurs (9 cEOS + 4 Linux)
make inspect     # vérifier : 13 nœuds "running"
make destroy     # thanos
```

## J2 — La configuration

```bash
make coeur       # 1. OSPF + MPLS/LDP
make mpbgp       # 2. MP-BGP VPNv4 (RR = p1)
make vrf         # 3. VRF + raccordements PE–CE + CE
make provision   # les 3 d'affilée (2e passage : changed=0 attendu)
```

## Vérifications

```bash
docker exec p1  Cli -p 15 -c "show ip ospf neighbor"      # après coeur : 2 voisins FULL
docker exec p1  Cli -p 15 -c "show bgp vpn-ipv4 summary"  # après mpbgp : 3 PE Established             
make cli N=pe1                                            # CLI interactive d'un nœud
```