#!/bin/bash

set -e

# === Auto settings ===
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="portainer-deb12"
PASSWORD="changeme"
STORAGE="local-lvm"
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
DISK_SIZE="8G"
MEMORY=2048
CORES=2
BRIDGE="vmbr0"
IP="dhcp"

echo "🚀 Proxmox Docker + Portainer Setup"
echo "🆔 Creating CTID: $CTID"

# === Ensure Debian 12 template is present ===
if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]; then
  echo "📦 Template not found. Downloading..."
  pveam update
  pveam download local $TEMPLATE
fi

# === Create LXC container ===
echo "📦 Creating container $CTID..."
pct create $CTID /var/lib/vz/template/cache/$TEMPLATE \
  --hostname $HOSTNAME \
  --password $PASSWORD \
  --storage $STORAGE \
  --rootfs $STORAGE:$DISK_SIZE \
  --net0 name=eth0,bridge=$BRIDGE,ip=$IP \
  --ostype debian \
  --features nesting=1 \
  --cores $CORES \
  --memory $MEMORY \
  --unprivileged 1 > /dev/null

# === Start container ===
echo "▶️ Starting container..."
pct start $CTID
sleep 10

# === Run setup inside container ===
echo "🛠 Installing Docker + Portainer inside CT $CTID..."
pct exec $CTID -- bash -c '
set -e
apt update && apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
'

# === Show result ===
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
echo ""
echo "✅ DONE! Portainer is running in CT $CTID"
echo "🔗 Access it at: https://$IP:9443"
