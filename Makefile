TOPO := netops.clab.yaml
CLAB ?= sudo containerlab
PB   := cd ansible && ansible-playbook

.PHONY: help deploy destroy inspect deps coeur mpbgp vrf run checkup plan closedness cli

help:  ## Liste des cibles
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

# ---- J1 : le lab
deploy:  ## Crée les 13 conteneurs
	$(CLAB) deploy -t $(TOPO) --max-workers 2
destroy:  ## Détruit le lab et son dossier clab-netops/
	$(CLAB) destroy -t $(TOPO) --cleanup
inspect:  ## État des nœuds et IP de management
	$(CLAB) inspect -t $(TOPO)

# ---- J2 : Ansible
deps:  ## Dépendances (une seule fois) : netaddr dans l'Ansible pipx + collections
	pipx inject ansible netaddr
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

# Branche observabilité (zip séparé) : ce fichier n'existe que si on l'a ajouté
-include observabilite.mk
