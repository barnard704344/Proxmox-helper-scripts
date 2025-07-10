#!/bin/bash
set +e

echo "🚀 Proxmox Docker + Portainer Setup"

# === Get next available CTID ===
CTID=$(pvesh get /cluster/nextid)

# === Prompt for container hostname ===
exec 3</dev/tty
read -u 3 -rp "📝 Enter a name for the container (hostname): " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
  echo "❌ Hostname cannot be empty. Aborting."
  exit 1
fi

# === Prompt for root password ===
read -u 3 -rsp "🔐 Enter root password for container: " PASSWORD
echo ""
read -u 3 -rsp "🔐 Confirm root password: " PASSWORD_CONFIRM
echo ""
if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
  echo "❌ Passwords do not match. Aborting."
  exit 1
fi

# === Container settings ===
DISK_SIZE="8G"
MEMORY=2048
CORES=2
BRIDGE="vmbr0"
IP="dhcp"

# === Find LXC Template ===
echo "🔍 Searching all storages for Debian 12 template..."
TEMPLATE_GLOB="debian-12-standard_*_amd64.tar.zst"
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

# === Prompt for rootfs storage ===
while true; do
  echo ""
  echo "🔍 Available storage options for container rootfs:"
  pvesm status --enabled 1 | awk '{print "  - " $1 " (" $2 ")"}'
  echo ""
  read -u 3 -rp "💾 Enter storage to use for the container rootfs (e.g. nas, local-lvm): " ROOTFS_STORAGE

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

# === Handle rootfs size argument ===
if [[ "$STORAGE_TYPE" == "dir" || "$STORAGE_TYPE" == "nfs" || "$STORAGE_TYPE" == "cifs" ]]; then
  ROOTFS_ARG="--rootfs $ROOTFS_STORAGE"
else
  SIZE_NUM="${DISK_SIZE//[!0-9]/}"
  ROOTFS_ARG="--rootfs $ROOTFS_STORAGE:$SIZE_NUM"
fi

echo "📦 Creating container on storage: $ROOTFS_STORAGE ($STORAGE_TYPE)"

# === Create the container ===
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

if ! pct status "$CTID" &>/dev/null; then
  echo "❌ Container $CTID does not exist. Create failed."
  echo "==== pct create output ===="
  cat "$CREATE_LOG"
  echo "==========================="
  rm -f "$CREATE_LOG"
  exit 1
fi
rm -f "$CREATE_LOG"

# === Start the container ===
echo "▶️ Starting container $CTID..."
pct start "$CTID"
sleep 5

# === Install Docker, SSH, and Portainer ===
echo "🔧 Installing Docker, SSH, and Portainer inside CT $CTID..."
pct exec "$CTID" -- bash -c '
set -e
apt update && apt upgrade -y
apt install -y openssh-server ca-certificates curl gnupg lsb-release

# Enable root login via SSH
systemctl enable ssh
systemctl start ssh
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

# Install Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

# Deploy Portainer
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
'

# === Display Access Info ===
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
echo ""
echo "✅ Portainer is ready!"
echo "🔗 Access it at: https://$IP:9443"
echo "🔐 Login with root / your chosen password via SSH if needed."
