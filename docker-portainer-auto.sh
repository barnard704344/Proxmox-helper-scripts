#!/bin/bash

set -e

echo "🚀 Proxmox Docker + Portainer Setup"

# === Prompt for Template Storage ===
echo ""
echo "🔍 Available storage locations that support templates:"
pvesm status --enabled 1 | awk '/vztmpl/ {print "  - " $1}'
echo ""
read -rp "💾 Enter storage to use for templates (as shown above): " TEMPLATE_STORE

if ! pvesm status | awk '/vztmpl/ {print $1}' | grep -q "^$TEMPLATE_STORE$"; then
  echo "❌ Invalid storage selected. Aborting."
  exit 1
fi

# === Constants ===
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
TEMPLATE_SHORT="debian-12-standard"
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="portainer-deb12"
PASSWORD="changeme"
DISK_SIZE="8G"
MEMORY=2048
CORES=2
BRIDGE="vmbr0"
IP="dhcp"

echo ""
echo "🆔 Selected CTID: $CTID"
echo "📁 Using storage: $TEMPLATE_STORE"

# === Download template if missing ===
if ! ls "/var/lib/vz/template/cache/$TEMPLATE" >/dev/null 2>&1; then
  echo "📦 Template not found. Downloading $TEMPLATE_SHORT..."
  pveam update
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_SHORT"
fi

# === Create LXC container ===
echo "📦 Creating container $CTID..."
pct create "$CTID" "$TEMPLATE_STORE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --storage "$TEMPLATE_STORE" \
  --rootfs "$TEMPLATE_STORE:$DISK_SIZE" \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP" \
  --ostype debian \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --unprivileged 1 > /dev/null

# === Start container ===
echo "▶️ Starting container $CTID..."
pct start "$CTID"
sleep 10

# === Run Docker + Portainer setup inside CT ===
echo "🔧 Installing Docker and Portainer inside CT $CTID..."
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

# === Display access info ===
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "👉 Access it at: https://$IP:9443"
