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

# === Prompt for storage to use
echo ""
echo "🔍 Available storage options:"
pvesm status --enabled 1 | awk '{print "  - " $1 " (" $2 ")"}'
echo ""
read -rp "💾 Enter storage to use for the container (e.g. nas, local-lvm): " STORAGE_NAME
if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE_NAME"; then
  echo "❌ Storage '$STORAGE_NAME' not found. Aborting."
  exit 1
fi

# === Detect storage type
STORAGE_TYPE=$(pvesm status | awk -v s="$STORAGE_NAME" '$1==s {print $2}')

# === Locate template on that storage
echo "🔍 Searching for Debian 12 template in $STORAGE_NAME..."
TEMPLATE_FILE=$(find /mnt/pve/$STORAGE_NAME/template/cache/ -maxdepth 1 -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -Vr | head -n 1)

if [ -z "$TEMPLATE_FILE" ]; then
  echo "❌ No Debian 12 template found in /mnt/pve/$STORAGE_NAME/template/cache/"
  echo "💡 Download one via GUI or manually place a file like:"
  echo "   /mnt/pve/$STORAGE_NAME/template/cache/$TEMPLATE_GLOB"
  exit 1
fi

TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "💾 Found template: $TEMPLATE_BASENAME"
echo "🆔 Using CTID: $CTID"
echo "📦 Storage type: $STORAGE_TYPE"

# === Set rootfs argument based on storage type
if [[ "$STORAGE_TYPE" == "dir" || "$STORAGE_TYPE" == "nfs" || "$STORAGE_TYPE" == "cifs" ]]; then
  ROOTFS_ARG="--rootfs $STORAGE_NAME"
else
  ROOTFS_ARG="--rootfs $STORAGE_NAME:$DISK_SIZE"
fi

# === Create container using full template path
pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  --storage "$STORAGE_NAME" \
  $ROOTFS_ARG \
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

# === Install Docker + Portainer
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

# === Final message
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
