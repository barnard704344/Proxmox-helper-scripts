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

# === Search mounted storage for valid template ===
echo "🔍 Scanning mounted storages for LXC template: $TEMPLATE_GLOB"
TEMPLATE_FILE=""
TEMPLATE_STORE=""

for path in /mnt/pve/*/template/cache/; do
  if [ -d "$path" ]; then
    FILE=$(find "$path" -maxdepth 1 -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -rV | head -n 1)
    if [ -n "$FILE" ]; then
      TEMPLATE_FILE="$FILE"
      TEMPLATE_STORE=$(echo "$FILE" | cut -d'/' -f4)  # Extract 'nas' or 'local' etc
      break
    fi
  fi
done

# === Fail if not found ===
if [ -z "$TEMPLATE_FILE" ]; then
  echo "❌ No usable Debian 12 template found in /mnt/pve/*/template/cache/"
  echo "💡 To fix: download a template using GUI or place it manually into:"
  echo "   /mnt/pve/<storage>/template/cache/$TEMPLATE_GLOB"
  exit 1
fi

TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "💾 Found template: $TEMPLATE_BASENAME in storage: $TEMPLATE_STORE"
echo "🆔 Creating container with CTID: $CTID"

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

# === Show final access link ===
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
