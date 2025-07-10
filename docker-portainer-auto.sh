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

# === Get all storages that support LXC templates ===
echo "🔍 Searching for available template in valid storage..."
VALID_STORES=($(pvesm status --enabled 1 | awk '/vztmpl/ {print $1}'))

if [ ${#VALID_STORES[@]} -eq 0 ]; then
  echo "❌ No storage found with 'vztmpl' content enabled."
  echo "Use: pvesm set <storage> --content vztmpl"
  exit 1
fi

TEMPLATE_STORE=""
TEMPLATE_FILE=""

# === Search for existing Debian 12 template ===
for store in "${VALID_STORES[@]}"; do
  CACHE_PATH="/mnt/pve/${store}/template/cache"
  FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -rV | head -n 1)
  if [ -n "$FILE" ]; then
    TEMPLATE_STORE="$store"
    TEMPLATE_FILE="$FILE"
    break
  fi
done

# === Download template if not found ===
if [ -z "$TEMPLATE_FILE" ]; then
  echo "📦 No template found. Downloading into '${VALID_STORES[0]}'..."
  pveam update
  TEMPLATE_VERSION=$(pveam available | grep "$TEMPLATE_NAME_PREFIX" | sort -rV | head -n 1 | awk '{print $1}')
  pveam download "${VALID_STORES[0]}" "$TEMPLATE_VERSION"
  TEMPLATE_STORE="${VALID_STORES[0]}"
  CACHE_PATH="/mnt/pve/${TEMPLATE_STORE}/template/cache"
  TEMPLATE_FILE=$(find "$CACHE_PATH" -type f -name "$TEMPLATE_GLOB" | sort -rV | head -n 1)
fi

# === Final check ===
if [ -z "$TEMPLATE_FILE" ]; then
  echo "❌ Failed to locate or download template."
  exit 1
fi

TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "💾 Using template: $TEMPLATE_BASENAME from $TEMPLATE_STORE"
echo "🆔 Creating CTID: $CTID"

# === Create container ===
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

# === Output Access URL ===
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
