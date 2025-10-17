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
LXC_MEMORY=2048
LXC_SWAP=512
LXC_DISK_SIZE=8
LXC_CORES=2
LXC_PASSWORD="votremotdepasse"
DONETICK_PORT=2021

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

# Récupération des templates disponibles
echo ""
echo -e "${GREEN}===== Sélection du template =====${NC}"
echo "Récupération des templates disponibles..."

mapfile -t TEMPLATES < <(pveam available | grep -E "debian-12|ubuntu-24" | awk '{print $2}')

if [ ${#TEMPLATES[@]} -eq 0 ]; then
    echo -e "${YELLOW}Aucun template trouvé. Utilisation du template par défaut.${NC}"
    LXC_TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
else
    echo ""
    echo "Templates disponibles:"
    echo ""
    
    PS3="Sélectionnez le template à utiliser (numéro): "
    select TEMPLATE_NAME in "${TEMPLATES[@]}" "Autre (spécifier manuellement)"; do
        if [ -n "$TEMPLATE_NAME" ]; then
            if [ "$TEMPLATE_NAME" = "Autre (spécifier manuellement)" ]; then
                read -p "Entrez le chemin du template: " LXC_TEMPLATE
            else
                LXC_TEMPLATE="local:vztmpl/$TEMPLATE_NAME"
            fi
            echo -e "${GREEN}Template sélectionné: $LXC_TEMPLATE${NC}"
            break
        else
            echo -e "${RED}Sélection invalide. Veuillez réessayer.${NC}"
        fi
    done
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
echo "CPU: $LXC_CORES cœurs"
echo "Port Donetick: $DONETICK_PORT"
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

echo -e "${GREEN}===== Installation de Docker =====${NC}"
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

echo -e "${GREEN}===== Création des répertoires Donetick =====${NC}"
pct exec $LXC_ID -- bash -c "
  mkdir -p /opt/donetick/data
  mkdir -p /opt/donetick/config
"

echo -e "${GREEN}===== Création du fichier de configuration selfhosted.yaml =====${NC}"
pct exec $LXC_ID -- bash -c "cat > /opt/donetick/config/selfhosted.yaml << 'EOF'
# Donetick selfhosted configuration
# Documentation: https://docs.donetick.com

# IMPORTANT: Change this to a secure random 32-character string
jwt:
  secret: \"$(openssl rand -base64 32 | head -c 32)\"
  
server:
  port: 2021
  
database:
  type: sqlite
  path: /donetick-data/donetick.db
EOF
"

echo -e "${GREEN}===== Création du fichier docker-compose.yml =====${NC}"
pct exec $LXC_ID -- bash -c "cat > /opt/donetick/docker-compose.yml << 'EOF'
services:
  donetick:
    image: donetick/donetick:latest
    container_name: donetick
    restart: unless-stopped
    ports:
      - \"$DONETICK_PORT:2021\"
    volumes:
      - .//donetick-data
      - ./config:/config
    environment:
      - DT_ENV=selfhosted
      - DT_SQLITE_PATH=/donetick-data/donetick.db
EOF
"

echo -e "${GREEN}===== Installation de Docker Compose =====${NC}"
pct exec $LXC_ID -- bash -c "
  apt-get install -y docker-compose-plugin
"

echo -e "${GREEN}===== Démarrage de Donetick =====${NC}"
pct exec $LXC_ID -- bash -c "
  cd /opt/donetick
  docker compose pull
  docker compose up -d
"

# Récupération de l'adresse IP du conteneur
LXC_IP=$(pct exec $LXC_ID -- hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}===== Installation terminée =====${NC}"
echo ""
echo -e "${GREEN}Donetick est accessible à l'adresse : http://$LXC_IP:$DONETICK_PORT${NC}"
echo ""
echo "Informations du conteneur LXC:"
echo "  - ID: $LXC_ID"
echo "  - Nom: $LXC_NAME"
echo "  - Stockage: $LXC_STORAGE"
echo "  - IP: $LXC_IP"
echo "  - Port: $DONETICK_PORT"
echo ""
echo "Configuration située dans: /opt/donetick"
echo ""
echo "Commandes utiles:"
echo "  - Voir les logs: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml logs -f"
echo "  - Redémarrer: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml restart"
echo "  - Arrêter: pct exec $LXC_ID -- docker compose -f /opt/donetick/docker-compose.yml down"
