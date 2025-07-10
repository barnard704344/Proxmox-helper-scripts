#!/bin/bash

set -e

echo "🚀 Proxmox Docker + Portainer Setup"

# === Constants ===
TEMPLATE_GLOB="debian-12-standard_*_amd64.tar.zst"
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="portainer-deb12"
PASSWORD="changeme"
DISK_SIZE="8G"
MEMORY=2048
CORES=2
BRIDGE="vmbr0"
IP="dhcp"

# === Scan all template paths
echo "🔍 Scanning for Debian 12 LXC template..."
TEMPLATE_FILE=$(find /mnt/pve/*/template/cache/ -maxdepth 1 -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -Vr | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
  echo "❌ No Debian 12 LXC template found!"
  echo "💡 Please download a template via the Proxmox GUI or manually place one at:"
  echo "   /mnt/pve/<storage>/template/cache/$TEMPLATE_GLOB"
  exit 1
fi

echo "💾 Found template: $TEMPLATE_FILE"
echo "🆔 Using CTID: $CTID"

# === Create the container using full path (no vztmpl!)
pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --storage "$(echo "$TEMPLATE_FILE" | cut -d'/' -f4)" \
  --rootfs "$(echo "$TEMPLATE_FILE" | cut -d'/' -f4):$DISK_SIZE" \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP" \
  --ostype debian \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --unprivileged 1 > /dev/null

# === Start container
echo "▶️ Starting container $CTID..."
pct start "$CTID"
sleep 10

# === Install Docker + Portainer inside CT
echo "🔧 Installing Docker and Portainer in CT $CTID..."
pct exec "$CTID" -- bash -c '
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

# === Display Access Info
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
