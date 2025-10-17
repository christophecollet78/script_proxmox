#!/bin/bash
#
# Script d'installation automatique de Donetick dans un LXC Proxmox
# Basé sur l'image Docker donetick/donetick
#

set -e

# Configuration par défaut
LXC_ID=200
LXC_NAME="donetick"
LXC_HOSTNAME="donetick"
LXC_MEMORY=1024
LXC_SWAP=256
LXC_DISK_SIZE=4
LXC_CORES=1
LXC_PASSWORD="votremotdepasse"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}===== Configuration du stockage =====${NC}"

# Récupération des stockages disponibles pour les conteneurs
echo "Récupération des stockages disponibles..."
mapfile -t STORAGES < <(pvesm status -content rootdir | awk 'NR>1 {print $1}')

if [ ${#STORAGES[@]} -eq 0 ]; then
    echo -e "${RED}Erreur: Aucun stockage disponible pour les conteneurs LXC${NC}"
    exit 1
fi

# Affichage du menu de sélection du stockage
echo ""
echo "Stockages disponibles pour les conteneurs LXC:"
echo ""

PS3="Sélectionnez le stockage à utiliser (numéro): "
select LXC_STORAGE in "${STORAGES[@]}"; do
    if [ -n "$LXC_STORAGE" ]; then
        echo -e "${GREEN}Stockage sélectionné: $LXC_STORAGE${NC}"
        break
    else
        echo -e "${RED}Sélection invalide. Veuillez réessayer.${NC}"
    fi
done

# Mise à jour de la liste des templates
echo ""
echo -e "${GREEN}===== Mise à jour de la liste des templates =====${NC}"
pveam update

# Récupération de la dernière version d'Alpine disponible
echo ""
echo -e "${GREEN}===== Sélection du template Alpine Linux (latest) =====${NC}"

ALPINE_TEMPLATE=$(pveam available --section system | grep alpine | sort -V | tail -1 | awk '{print $2}')

if [ -z "$ALPINE_TEMPLATE" ]; then
    echo -e "${RED}Erreur: Aucun template Alpine trouvé${NC}"
    exit 1
fi

echo -e "${YELLOW}Template Alpine Linux détecté: $ALPINE_TEMPLATE${NC}"

# Vérifier si le template est déjà téléchargé
if pveam list local | grep -q "$ALPINE_TEMPLATE"; then
    echo -e "${GREEN}Template déjà téléchargé${NC}"
    LXC_TEMPLATE="local:vztmpl/$ALPINE_TEMPLATE"
else
    echo -e "${YELLOW}Téléchargement du template Alpine Linux...${NC}"
    pveam download local "$ALPINE_TEMPLATE"
    LXC_TEMPLATE="local:vztmpl/$ALPINE_TEMPLATE"
    echo -e "${GREEN}Template téléchargé avec succès${NC}"
fi

read -p "Utiliser Alpine Linux $ALPINE_TEMPLATE (léger, recommandé) ? (O/n): " USE_ALPINE
if [[ "$USE_ALPINE" =~ ^[nN]$ ]]; then
    # Proposer d'autres templates
    echo "Récupération des autres templates disponibles..."
    mapfile -t TEMPLATES < <(pveam available --section system | grep -E "debian-12|ubuntu-24|alpine" | awk '{print $2}')
    
    echo ""
    echo "Templates disponibles:"
    echo ""
    
    PS3="Sélectionnez le template à utiliser (numéro): "
    select TEMPLATE_NAME in "${TEMPLATES[@]}" "Autre (spécifier manuellement)"; do
        if [ -n "$TEMPLATE_NAME" ]; then
            if [ "$TEMPLATE_NAME" = "Autre (spécifier manuellement)" ]; then
                read -p "Entrez le chemin du template: " LXC_TEMPLATE
            else
                # Vérifier si le template est téléchargé
                if ! pveam list local | grep -q "$TEMPLATE_NAME"; then
                    echo -e "${YELLOW}Téléchargement du template...${NC}"
                    pveam download local "$TEMPLATE_NAME"
                fi
                LXC_TEMPLATE="local:vztmpl/$TEMPLATE_NAME"
            fi
            echo -e "${GREEN}Template sélectionné: $LXC_TEMPLATE${NC}"
            break
        else
            echo -e "${RED}Sélection invalide. Veuillez réessayer.${NC}"
        fi
    done
fi

# Détection si c'est Alpine pour adapter l'installation
IS_ALPINE=false
if [[ "$LXC_TEMPLATE" =~ alpine ]]; then
    IS_ALPINE=true
    echo -e "${YELLOW}Mode Alpine détecté - installation optimisée${NC}"
fi

# Confirmation de la configuration
echo ""
echo -e "${GREEN}===== Récapitulatif de la configuration =====${NC}"
echo "ID du conteneur: $LXC_ID"
echo "Nom: $LXC_NAME"
echo "Stockage: $LXC_STORAGE"
echo "Template: $LXC_TEMPLATE"
echo "Mémoire: ${LXC_MEMORY}MB"
echo "Disque: ${LXC_DISK_SIZE}GB"
echo "CPU: $LXC_CORES cœur(s)"
echo "Port Donetick: 2021"
echo ""

read -p "Confirmer l'installation ? (o/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[oOyY]$ ]]; then
    echo -e "${RED}Installation annulée.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}===== Création du conteneur LXC =====${NC}"
pct create $LXC_ID $LXC_TEMPLATE \
  --hostname $LXC_HOSTNAME \
  --memory $LXC_MEMORY \
  --swap $LXC_SWAP \
  --cores $LXC_CORES \
  --rootfs $LXC_STORAGE:$LXC_DISK_SIZE \
  --password $LXC_PASSWORD \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --onboot 1

echo -e "${GREEN}===== Démarrage du conteneur =====${NC}"
pct start $LXC_ID

# Attendre que le conteneur soit prêt
echo "Attente du démarrage complet du conteneur..."
sleep 10

# Configuration réseau pour Alpine si nécessaire
if [ "$IS_ALPINE" = true ]; then
    echo -e "${GREEN}===== Configuration réseau Alpine =====${NC}"
    pct exec $LXC_ID -- ash -c "
      rc-service networking restart
      sleep 3
    "
fi

echo -e "${GREEN}===== Installation de Docker =====${NC}"

if [ "$IS_ALPINE" = true ]; then
    # Installation Docker pour Alpine Linux
    pct exec $LXC_ID -- ash -c "
      apk update
      apk add docker docker-cli-compose openrc
      
      # Configuration d'OpenRC pour Alpine
      rc-update add docker boot
      service docker start
    "
else
    # Installation Docker pour Debian/Ubuntu
    pct exec $LXC_ID -- bash -c "
      apt-get update
      apt-get install -y ca-certificates curl gnupg lsb-release
      
      # Installation de Docker
      curl -fsSL https://get.docker.com -o get-docker.sh
      sh get-docker.sh
      rm get-docker.sh
      
      # Activation de Docker au démarrage
      systemctl enable docker
      systemctl start docker
    "
fi

echo -e "${GREEN}===== Création des répertoires Donetick =====${NC}"
pct exec $LXC_ID -- sh -c "
  mkdir -p /opt/donetick/data
  mkdir -p /opt/donetick/config
"

echo -e "${GREEN}===== Génération du secret JWT =====${NC}"
JWT_SECRET=$(openssl rand -base64 32 | head -c 32)

echo -e "${GREEN}===== Création du fichier de configuration selfhosted.yaml =====${NC}"
pct exec $LXC_ID -- sh -c "cat > /opt/donetick/config/selfhosted.yaml << 'EOF'
# Donetick selfhosted configuration
# Documentation: https://docs.donetick.com

jwt:
  secret: \"$JWT_SECRET\"
  
server:
  port: 2021
  
database:
  type: sqlite
  path: /donetick-data/donetick.db
EOF
"

echo -e "${GREEN}===== Création du fichier docker-compose.yml =====${NC}"
pct exec $LXC_ID -- sh -c "cat > /opt/donetick/docker-compose.yml << 'EOF'
services:
  donetick:
    image: donetick/donetick:latest
    container_name: donetick
    restart: unless-stopped
    ports:
      - \"2021:2021\"
    volumes:
      - /opt/donetick//donetick-data
      - /opt/donetick/config:/config
    environment:
      - DT_ENV=selfhosted
      - DT_SQLITE_PATH=/donetick-data/donetick.db
EOF
"

echo -e "${GREEN}===== Démarrage de Donetick =====${NC}"
pct exec $LXC_ID -- sh -c "
  cd /opt/donetick
  docker compose pull
  docker compose up -d
"

# Récupération de l'adresse IP du conteneur avec retry
echo -e "${YELLOW}Récupération de l'adresse IP du conteneur...${NC}"
LXC_IP=""
for i in {1..10}; do
    LXC_IP=$(pct exec $LXC_ID -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -n "$LXC_IP" ]; then
        break
    fi
    echo "Tentative $i/10..."
    sleep 2
done

# Si toujours pas d'IP, essayer une autre méthode
if [ -z "$LXC_IP" ]; then
    LXC_IP=$(pct exec $LXC_ID -- hostname -I 2>/dev/null | awk '{print $1}')
fi

# Si toujours pas d'IP, vérifier dans la configuration Proxmox
if [ -z "$LXC_IP" ]; then
    echo -e "${YELLOW}Impossible de récupérer l'IP automatiquement${NC}"
    echo -e "${YELLOW}Vérifiez l'IP manuellement avec: pct exec $LXC_ID -- ip addr show${NC}"
    LXC_IP="<IP_A_DETERMINER>"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}===== Installation terminée ! =====${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [ "$LXC_IP" != "<IP_A_DETERMINER>" ]; then
    echo -e "${GREEN}Donetick est accessible à l'adresse : http://$LXC_IP:2021${NC}"
else
    echo -e "${YELLOW}Donetick sera accessible à l'adresse : http://<IP_DU_CONTENEUR>:2021${NC}"
    echo -e "${YELLOW}Pour obtenir l'IP, exécutez: pct exec $LXC_ID -- ip addr show eth0${NC}"
fi
echo ""
echo "Informations du conteneur LXC:"
echo "  - ID: $LXC_ID"
echo "  - Nom: $LXC_NAME"
echo "  - Stockage: $LXC_STORAGE"
echo "  - Template: $(basename $LXC_TEMPLATE)"
echo "  - IP: $LXC_IP"
echo "  - Port: 2021"
echo "  - Ressources: ${LXC_CORES} CPU / ${LXC_MEMORY}MB RAM / ${LXC_DISK_SIZE}GB Disque"
echo ""
echo "Configuration située dans: /opt/donetick"
echo ""
echo "Commandes utiles:"
echo "  - Console: pct enter $LXC_ID"
echo "  - Obtenir l'IP: pct exec $LXC_ID -- ip addr show eth0"
echo "  - Logs: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml logs -f"
echo "  - Redémarrer: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml restart"
echo "  - Arrêter: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml down"
echo "  - Mettre à jour: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml pull && docker compose up -d"
