#!/bin/bash

set -e

echo "🚀 Proxmox Docker + Portainer Setup"

# === Constants ===
TEMPLATE_NAME_PREFIX="debian-12-standard"
TEMPLATE_GLOB="${TEMPLATE_NAME_PREFIX}_*_amd64.tar.zst"
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="portainer-deb12"
PASSWORD="changeme"
DISK_SIZE="8G"
MEMORY=2048
CORES=2
BRIDGE="vmbr0"
IP="dhcp"

# === Detect a valid template store with vztmpl support ===
TEMPLATE_STORE=$(pvesm status --enabled 1 | awk '/vztmpl/ {print $1; exit}')
if [ -z "$TEMPLATE_STORE" ]; then
  echo "❌ No storage with 'vztmpl' content enabled was found. Please enable it using:"
  echo "    pvesm set <storage> --content vztmpl"
  exit 1
fi

echo "💾 Using detected template store: $TEMPLATE_STORE"

# === Template path resolution ===
CACHE_PATH="/mnt/pve/${TEMPLATE_STORE}/template/cache"
TEMPLATE_FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" | sort -rV | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
  echo "📦 No Debian 12 LXC template found in $CACHE_PATH"
  echo "🔻 Downloading latest available version of $TEMPLATE_NAME_PREFIX..."
  pveam update
  pveam available | grep "$TEMPLATE_NAME_PREFIX" | sort -rV | head -n 1 | awk '{print $1}' | xargs -I {} pveam download "$TEMPLATE_STORE" {}
  TEMPLATE_FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" | sort -rV | head -n 1)
fi

TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "📦 Using template: $TEMPLATE_BASENAME"

# === Create the container ===
echo "📦 Creating container $CTID..."
pct create "$CTID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE_BASENAME}" \
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

# === Install Docker + Portainer ===
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

# === Final Output ===
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
