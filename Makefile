TOPO := netops.clab.yaml
CLAB ?= sudo containerlab
PB   := cd ansible && ansible-playbook     # Ansible de la VM (pipx)
 
.PHONY: help deploy destroy inspect deps coeur mpbgp vrf provision checkup cli
 
help:  ## Liste des cibles
	@grep -E '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'
 
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
	ansible-galaxy collection install -r ansible/collections.yml
coeur:  ## Playbook 1 : OSPF + MPLS/LDP
	$(PB) 01-coeur.yml
mpbgp:  ## Playbook 2 : MP-BGP VPNv4 (RR p1)
	$(PB) 02-mpbgp.yml
vrf:  ## Playbook 3 : VRF + PE–CE + CE
	$(PB) 03-vrf.yml
provision:  ## Les 3 playbooks d'affilée
	$(PB) site.yml
 
# ---- Démo
cli:  ## CLI d'un nœud : make cli N=p1
	docker exec -it $(N) Cli
