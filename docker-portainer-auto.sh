#!/bin/bash

set +e  # Allow graceful handling of errors

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

# === Find LXC Template ===
echo "🔍 Searching all storages for Debian 12 template..."
TEMPLATE_FILE=$(find /mnt/pve/*/template/cache/ -maxdepth 1 -type f -name "$TEMPLATE_GLOB" 2>/dev/null | sort -Vr | head -n 1)

if [[ -z "$TEMPLATE_FILE" ]]; then
  echo "❌ No Debian 12 LXC template found!"
  echo "💡 Please upload one via Proxmox GUI or place it at:"
  echo "   /mnt/pve/<storage>/template/cache/$TEMPLATE_GLOB"
  exit 1
fi

TEMPLATE_STORAGE=$(echo "$TEMPLATE_FILE" | cut -d'/' -f4)
TEMPLATE_BASENAME=$(basename "$TEMPLATE_FILE")
echo "💾 Found template: $TEMPLATE_BASENAME on storage: $TEMPLATE_STORAGE"
echo "🆔 Preparing container with CTID: $CTID"

# === Prompt for Rootfs Storage ===
while true; do
  echo ""
  echo "🔍 Available storage options for container rootfs:"
  pvesm status --enabled 1 | awk '{print "  - " $1 " (" $2 ")"}'
  echo ""
  read -rp "💾 Enter storage to use for the container rootfs (e.g. nas, local-lvm): " ROOTFS_STORAGE

  pvesm status | awk '{print $1}' | grep -qx "$ROOTFS_STORAGE"
  if [[ $? -ne 0 ]]; then
    echo "❌ Storage '$ROOTFS_STORAGE' not found. Try again."
    continue
  fi

  STORAGE_TYPE=$(pvesm status | awk -v s="$ROOTFS_STORAGE" '$1==s {print $2}')
  if [[ -z "$STORAGE_TYPE" ]]; then
    echo "❌ Could not detect storage type for '$ROOTFS_STORAGE'. Try again."
    continue
  fi

  if [[ "$STORAGE_TYPE" == "lvm" ]]; then
    VG_ATTR=$(vgs --noheadings -o attr "$ROOTFS_STORAGE" 2>/dev/null | awk '{print $1}')
    if [[ "$VG_ATTR" != *"t"* ]]; then
      echo "❌ Storage '$ROOTFS_STORAGE' is plain LVM without a thin pool."
      echo "🛠️  LXC containers require 'lvmthin', 'nfs', or 'dir' type."
      echo "💡 Please choose another storage like 'local-lvm' or 'nas'."
      continue
    fi
  fi

  break
done

# === Fix rootfs argument
if [[ "$STORAGE_TYPE" == "dir" || "$STORAGE_TYPE" == "nfs" || "$STORAGE_TYPE" == "cifs" ]]; then
  ROOTFS_ARG="--rootfs $ROOTFS_STORAGE"
else
  SIZE_NUM="${DISK_SIZE//[!0-9]/}"
  ROOTFS_ARG="--rootfs $ROOTFS_STORAGE:$SIZE_NUM"
fi

echo "📦 Creating container on storage: $ROOTFS_STORAGE ($STORAGE_TYPE)"

# === Create container
CREATE_LOG=$(mktemp)
/usr/sbin/pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$HOSTNAME" \
  --password "$PASSWORD" \
  $ROOTFS_ARG \
  --net0 name=eth0,bridge="$BRIDGE",ip="$IP" \
  --ostype debian \
  --features nesting=1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --unprivileged 1 \
  >"$CREATE_LOG" 2>&1

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  echo "❌ Container config not found. Create failed."
  echo "==== pct create output ===="
  cat "$CREATE_LOG"
  echo "==========================="
  rm -f "$CREATE_LOG"
  exit 1
fi
rm -f "$CREATE_LOG"

# === Start container
echo "▶️ Starting container $CTID..."
pct start "$CTID"
sleep 5

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

# === Show access info
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
