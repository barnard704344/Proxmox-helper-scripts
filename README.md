# 🛠️ Proxmox Helper Scripts

A collection of one-line, copy-paste-friendly automation scripts for **Proxmox VE**. Designed to simplify common tasks like container setup, Docker installation, and application deployment.

---

## 📦 Available Scripts

### 🚀 Docker + Portainer Auto Installer (LXC)
Creates a new Debian 12 LXC container, installs Docker and Portainer with HTTPS, and prints the access URL.

**Run it with one line:**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/barnard704344/Proxmox-helper-scripts/main/docker-portainer-auto.sh)" </dev/tty
