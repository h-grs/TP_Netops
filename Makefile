TOPO := netops.clab.yaml
CLAB ?= sudo containerlab
PB   := cd ansible && ansible-playbook
TOOLS    := NetOps@10.200.4.68
SSH      := ssh -o BatchMode=yes $(TOOLS)
NAUTOBOT := ~/nautobot-docker-compose
# OFFLINE=1 : Nautobot injoignable → on rejoue avec la dernière copie lue (ansible/sot/host_vars/)
SOT := $(if $(OFFLINE),sot-cache,sot-pull)
# Observabilité. O1 : Ansible local (inventaire containerlab + VM Lab) ; K=1 si sudo demande un mot de passe.
#                O2/O3 : Docker Compose sur la VM Tools, fichiers versionnés dans tools/observabilite/ (sparse-checkout)
OBS      := cd ansible && ansible-playbook -i ../clab-netops/ansible-inventory.yml -i inventaire-vms.yml $(if $(K),--ask-become-pass)
LAB_IP   := 10.200.4.120
REPO_T   := ~/TP_Netops
OBS_DIR  := $(REPO_T)/tools/observabilite
SSHA     := ssh -A -o BatchMode=yes $(TOOLS)   # -A : ta clé GitHub suit, pour le git pull sur la VM Tools
PULL_T   := git -C $(REPO_T) pull --ff-only -q || echo "!!  git pull impossible sur la VM Tools : fichiers déjà présents utilisés"

.PHONY: help deploy destroy inspect deps coeur mpbgp vrf run checkup plan closedness cli \
        tools-status nautobot-up nautobot-down nautobot-tasks nautobot-sync nautobot-devices nautobot-ipam sot-pull sot-cache nautobot-backup render conforme \
        o1 o2 o3 obs obs-status trafic panne reprise

help:  ## Liste des cibles
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

# ---- J1 : le lab
deploy:  ## Crée les 13 conteneurs
	$(CLAB) deploy -t $(TOPO) --max-workers 2
destroy:  ## Détruit le lab et son dossier clab-netops/
	$(CLAB) destroy -t $(TOPO) --cleanup
inspect:  ## État des nœuds et IP de management
	$(CLAB) inspect -t $(TOPO)

# ---- J2 : Ansible
deps:  ## Dépendances (une seule fois) : netaddr + pynautobot dans l'Ansible pipx, collections
	pipx inject ansible netaddr pynautobot
	ansible-galaxy collection install -r ansible/requirements.yml
coeur: $(SOT)  ## Playbook 1 : OSPF + MPLS/LDP
	$(PB) 01-coeur.yml
mpbgp: $(SOT)  ## Playbook 2 : MP-BGP VPNv4 (RR p1)
	$(PB) 02-mpbgp.yml
vrf: $(SOT)  ## Playbook 3 : VRF + PE–CE + CE
	$(PB) 03-vrf.yml

checkup: $(SOT)  ## Checkup en escalier (OSPF/LDP, VPNv4, eBGP, routes, ping des postes)
	$(PB) 100-checkup_escalier.yml

run: $(SOT)  ## Applique tout (les 3 playbooks d'affilée)
	$(PB) run.yml

plan: $(SOT)  ## Diff avec la config réelle, sans appliquer : make plan N=pe1
	@test -n "$(N)" || { echo "Usage : make plan N=pe1"; exit 1; }
	$(PB) run.yml -l $(N) --check --diff

render: $(SOT)  ## J4 : rend la config voulue en texte, sans l'appliquer → rendu/<nœud>.cfg (N=pe1 pour l'afficher)
	$(PB) 04-rendu.yml $(if $(N),-l $(N))
	@$(if $(N),cat rendu/$(N).cfg,ls rendu/)

conforme: $(SOT)  ## J4 : compare chaque rendu à la config réelle (mode check, rien n'est appliqué)
	$(PB) 04-rendu.yml --tags rendu,conforme $(if $(N),-l $(N))

closedness: $(SOT)  ## Test d'étanchéité (pose le canari, teste, le retire)
	($(PB) 200-canary.yml -e etat=on)
	($(PB) 200-closed_network.yml); r=$$?; ($(PB) 200-canary.yml -e etat=off); exit $$r

# ---- CLI pour la démo || Doit être up avant
cli:  ## CLI d'un nœud : make cli N=p1
	docker exec -it $(N) Cli

# ---- VM tools : les fichiers restent sur la VM tools, pilotés en SSH
tools-status:  ## Conteneurs qui tournent sur la VM tools
	$(SSH) 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

nautobot-up:  ## Démarre Nautobot sur la VM tools
	$(SSH) 'bash -lc "cd $(NAUTOBOT) && poetry run invoke start"'

nautobot-down:  ## Arrête Nautobot sur la VM tools
	$(SSH) 'bash -lc "cd $(NAUTOBOT) && poetry run invoke stop"'

nautobot-sync:  ## Amorçage : pousse les host_vars dans Nautobot (inutile une fois Nautobot source de vérité)
	@export NAUTOBOT_TOKEN="$${NAUTOBOT_TOKEN:-$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env')}"; \
	$(PB) 300-nautobot-sync.yml

sot-cache:  ## Mode OFFLINE=1 : vérifie qu'une copie des données Nautobot existe déjà
	@test -n "$$(ls ansible/sot/host_vars/*.yml 2>/dev/null)" || { echo "Aucune copie dans ansible/sot/host_vars/ : lancer make sot-pull (Nautobot joignable) au moins une fois"; exit 1; }
	@echo "OFFLINE : données Nautobot du $$(date -r ansible/sot/host_vars '+%F %H:%M') (ansible/sot/host_vars/)"

sot-pull:  ## Lit Nautobot → ansible/sot/host_vars/ (lancé avant run/plan/checkup ; compare à host_vars/ s'il existe)
	@export NAUTOBOT_TOKEN="$${NAUTOBOT_TOKEN:-$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env')}"; \
	$(PB) 400-sot-pull.yml

nautobot-devices:  ## Liste les équipements présents dans Nautobot (nom, rôle, client)
	@TOKEN=$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env'); \
	curl -s -H "Authorization: Token $$TOKEN" "http://10.200.4.68:8080/api/dcim/devices/?limit=100&depth=1" \
	| python3 -c "import sys,json; r=json.load(sys.stdin); print(r['count'], 'équipements'); [print(f\"  {d['name']:8} {d['role']['name']:6} {(d['tenant'] or {}).get('name','-')}\") for d in r['results']]"

nautobot-ipam:  ## Liste les IP Nautobot par namespace (même LAN chez les deux clients)
	@TOKEN=$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env'); \
	curl -s -H "Authorization: Token $$TOKEN" "http://10.200.4.68:8080/api/ipam/ip-addresses/?limit=200&depth=2" \
	| python3 -c "import sys,json; r=json.load(sys.stdin); print(r['count'], 'adresses'); [print(f\"  {a['address']:18} {a['parent']['namespace']['name'] if a.get('parent') else '?'}\") for a in sorted(r['results'], key=lambda a: a['address'])]"

nautobot-backup:  ## Sauvegarde la base Nautobot sur la VM tools (~/nautobot-backups/<date>.sql)
	$(SSH) 'set -e; db=$$(docker ps -q --filter label=com.docker.compose.service=db | head -1); \
	  test -n "$$db" || { echo "Conteneur db introuvable : Nautobot est-il démarré ?"; exit 1; }; \
	  mkdir -p ~/nautobot-backups; f=~/nautobot-backups/$$(date +%F-%H%M).sql; \
	  docker exec "$$db" sh -c '"'"'pg_dump -U "$$POSTGRES_USER" "$$POSTGRES_DB"'"'"' > "$$f.tmp"; \
	  test -s "$$f.tmp" && mv "$$f.tmp" "$$f" && ls -lh "$$f"'

nautobot-tasks:  ## Liste les commandes invoke disponibles
	$(SSH) 'bash -lc "cd $(NAUTOBOT) && poetry run invoke --list"'
# ---- Branche observabilité (O1 · O2 · O3) — indépendante de J4, après J3
o1:  ## O1 : gnmic sur la VM Lab (fichier versionné, systemd, journald) abonné aux 9 cEOS → :9804
	$(OBS) 500-observabilite.yml

o2:  ## O2 : Prometheus (Compose, VM Tools) — vérifie d'abord que :9804 traverse, puis la cible UP et les 9 nœuds
	$(SSHA) 'set -e; $(PULL_T); \
	  timeout 5 bash -c "</dev/tcp/$(LAB_IP)/9804" && echo "OK  port 9804 de la VM Lab joignable depuis la VM Tools" \
	    || { echo "KO  9804 injoignable depuis la VM Tools : gnmic tourne-t-il (make o1) ? pare-feu ?"; exit 1; }; \
	  cd $(OBS_DIR) && docker compose up -d prometheus; \
	  for i in $$(seq 1 20); do curl -sf localhost:9090/-/ready >/dev/null && break; sleep 3; done; \
	  curl -sf -X POST localhost:9090/-/reload; sleep 20; \
	  echo "up{job=gnmic}  : $$(curl -s "localhost:9090/api/v1/query?query=up%7Bjob%3D%22gnmic%22%7D" | grep -o "\"[01]\"\]" | tr -dc 01)"; \
	  echo "nœuds stockés : $$(curl -s "localhost:9090/api/v1/query?query=count(count%20by%20(device)(gnmic_interfaces_interface_state_counters_in_octets))" | grep -o "\"[0-9]*\"\]" | tr -dc 0-9)"'

o3:  ## O3 : Grafana (Compose, VM Tools) — datasource ET tableau de bord provisionnés par fichier, vérifiés sans un clic
	$(SSHA) 'set -e; $(PULL_T); cd $(OBS_DIR); \
	  test -f .env || { echo ".env absent sur la VM Tools : cd $(OBS_DIR) && cp .env.example .env (puis choisir le mot de passe)"; exit 1; }; \
	  docker compose up -d grafana; \
	  for i in $$(seq 1 30); do curl -sf localhost:3000/api/health >/dev/null && break; sleep 3; done; \
	  . ./.env; A="admin:$$GF_SECURITY_ADMIN_PASSWORD"; \
	  curl -sf -u "$$A" localhost:3000/api/datasources/uid/prometheus >/dev/null && echo "OK  source de données provisionnée"; \
	  for d in netops-reseau netops-debit; do \
	    curl -sf -u "$$A" localhost:3000/api/dashboards/uid/$$d >/dev/null && echo "OK  tableau de bord $$d provisionné (dossier NetOps)" || echo "KO  tableau de bord $$d absent"; done'

obs: o1 o2 o3  ## O1 + O2 + O3 d'affilée

obs-status:  ## État de la chaîne : service gnmic, nœuds exposés, conteneurs et cible Prometheus
	@echo "gnmic : $$(systemctl is-active gnmic) — nœuds exposés : $$(curl -s localhost:9804/metrics | grep -o 'device="[^"]*"' | sort -u | wc -l)"
	@$(SSH) 'cd $(OBS_DIR) && docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Image}}"'

trafic:  ## O3 : trafic de test ≈ 58 kbit/s, défaut lc2 → lc3 (VRFB, passe par p2 Ethernet2 = make panne) [S=lc1 D=192.168.1.2] (Ctrl-C)
	docker exec -it $(or $(S),lc2) ping -O -i 0.2 -s 1400 $(or $(D),192.168.1.2)

panne:  ## O3 : coupe une interface (défaut p2 Ethernet2) et affiche l'heure UTC : make panne [N=p2 I=Ethernet2]
	$(PB) 510-experience-panne.yml -e etat=down $(if $(N),-e noeud=$(N)) $(if $(I),-e interface=$(I))

reprise:  ## O3 : rétablit l'interface coupée par make panne
	$(PB) 510-experience-panne.yml -e etat=up $(if $(N),-e noeud=$(N)) $(if $(I),-e interface=$(I))