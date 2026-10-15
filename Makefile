TOPO := netops.clab.yaml
CLAB ?= sudo containerlab
PB   := cd ansible && ansible-playbook
TOOLS    := NetOps@10.200.4.68
SSH      := ssh -o BatchMode=yes $(TOOLS)
NAUTOBOT := ~/nautobot-docker-compose

.PHONY: help deploy destroy inspect deps coeur mpbgp vrf run checkup plan closedness cli \
        tools-status nautobot-up nautobot-down nautobot-tasks nautobot-sync nautobot-devices nautobot-ipam

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
coeur:  ## Playbook 1 : OSPF + MPLS/LDP
	$(PB) 01-coeur.yml
mpbgp:  ## Playbook 2 : MP-BGP VPNv4 (RR p1)
	$(PB) 02-mpbgp.yml
vrf:  ## Playbook 3 : VRF + PE–CE + CE
	$(PB) 03-vrf.yml

checkup:  ## Checkup en escalier (OSPF/LDP, VPNv4, eBGP, routes, ping des postes)
	$(PB) 100-checkup_escalier.yml

run:  ## Applique tout (les 3 playbooks d'affilée)
	$(PB) run.yml

plan:  ## Diff avec la config réelle, sans appliquer : make plan N=pe1
	@test -n "$(N)" || { echo "Usage : make plan N=pe1"; exit 1; }
	$(PB) run.yml -l $(N) --check --diff

closedness:  ## Test d'étanchéité (pose le canari, teste, le retire)
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

nautobot-sync:  ## Alimente Nautobot depuis l'inventaire : équipements, clients, interfaces, IP
	@export NAUTOBOT_TOKEN="$${NAUTOBOT_TOKEN:-$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env')}"; \
	$(PB) 300-nautobot-sync.yml

nautobot-devices:  ## Liste les équipements présents dans Nautobot (nom, rôle, client)
	@TOKEN=$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env'); \
	curl -s -H "Authorization: Token $$TOKEN" "http://10.200.4.68:8080/api/dcim/devices/?limit=100&depth=1" \
	| python3 -c "import sys,json; r=json.load(sys.stdin); print(r['count'], 'équipements'); [print(f\"  {d['name']:8} {d['role']['name']:6} {(d['tenant'] or {}).get('name','-')}\") for d in r['results']]"

nautobot-ipam:  ## Liste les IP Nautobot par namespace (même LAN chez les deux clients)
	@TOKEN=$$($(SSH) 'grep -oP "^NAUTOBOT_SUPERUSER_API_TOKEN=\K.*" $(NAUTOBOT)/environments/creds.env'); \
	curl -s -H "Authorization: Token $$TOKEN" "http://10.200.4.68:8080/api/ipam/ip-addresses/?limit=200&depth=2" \
	| python3 -c "import sys,json; r=json.load(sys.stdin); print(r['count'], 'adresses'); [print(f\"  {a['address']:18} {a['parent']['namespace']['name'] if a.get('parent') else '?'}\") for a in sorted(r['results'], key=lambda a: a['address'])]"

nautobot-tasks:  ## Liste les commandes invoke disponibles
	$(SSH) 'bash -lc "cd $(NAUTOBOT) && poetry run invoke --list"'