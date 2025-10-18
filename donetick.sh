#!/bin/bash
set -e

# Variables modifiables
CT_HOSTNAME="donetick"
CT_ROOT_PASSWORD="MotDePasseFort123!"  # Remplace par un mot de passe sécurisé
STORAGE="local-lvm"
MEMORY=1024
CORES=1
NET_BRIDGE="vmbr0"

# Fonction pour trouver un ID libre LXC (100-199)
find_free_ctid() {
  for id in $(seq 100 199); do
    if ! pct status $id &>/dev/null; then
      echo $id
      return
    fi
  done
  echo "Erreur : aucun ID LXC libre trouvé dans la plage 100-199." >&2
  exit 1
}

CT_ID=$(find_free_ctid)
echo "ID libre trouvé pour conteneur LXC : $CT_ID"

echo "Création du conteneur LXC Debian 13..."
pct create $CT_ID debian-13-standard_2025XXXXXX_amd64.tar.zst \
  --hostname $CT_HOSTNAME \
  --storage $STORAGE \
  --password $CT_ROOT_PASSWORD \
  --memory $MEMORY \
  --cores $CORES \
  --net0 name=eth0,bridge=$NET_BRIDGE,ip=dhcp \
  --features nesting=1,keyctl=1 \
  --unprivileged 0

echo "Démarrage du conteneur..."
pct start $CT_ID
sleep 10

echo "Installation automatique de Donetick dans le conteneur..."

pct exec $CT_ID -- bash -c "
set -e
apt update && apt upgrade -y
apt install -y wget apt-transport-https software-properties-common unzip curl

wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
apt update
apt install -y dotnet-runtime-8.0

mkdir -p /opt/donetick/config /opt/donetick/data
cd /opt/donetick

wget -q https://github.com/donetick/donetick/releases/latest/download/donetick-linux-x64.zip -O donetick.zip
unzip -q donetick.zip && chmod +x donetick
rm donetick.zip

SECRET=\$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
cat > /opt/donetick/config/selfhosted.yaml <<EOL
secret: \"\$SECRET\"
database:
  type: sqlite
  sqlite:
    file: /opt/donetick/data/donetick.db
server:
  port: 2021
EOL

cat > /etc/systemd/system/donetick.service <<EOL
[Unit]
Description=Donetick selfhosted
After=network.target

[Service]
WorkingDirectory=/opt/donetick
ExecStart=/opt/donetick/donetick
Environment=DT_ENV=selfhosted
Environment=DT_SQLITE_PATH=/opt/donetick/data/donetick.db
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable --now donetick
"

echo "Installation terminée. Donetick tourne sur le port 2021 dans le conteneur LXC $CT_ID."

echo "Récupérez l'IP du conteneur avec :"
echo "pct exec $CT_ID ip -4 addr show eth0 | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'"
