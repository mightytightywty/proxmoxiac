#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

#####################################################################################
# INSTALL & CONFIGURE Proxmox Backup Server v4.x on any Debian based system (or LXC)
# Usage: setup-proxmox-backup-server.sh
# It's safe to re-run this script, it will simply update your OS and PBS
#####################################################################################

# Detect if the user is running this script on a Proxmox VE host system. If so, warn them, and ask to confirm
if command -v pveversion >/dev/null 2>&1 || [ -d "/etc/pve" ]; then
    echo "WARNING: It appears you are running this script directly on a Proxmox VE Host system."
    echo "Installing Proxmox Backup Server directly alongside Proxmox VE is supported but can cause package conflicts if not careful."
    echo "It is generally recommended to install PBS in a dedicated VM or LXC container."
    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r; echo ""; [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
fi

# Update the Debian 13 base system
apt update && apt upgrade -y
apt install -y curl gnupg2 ca-certificates

# Download Proxmox key
wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg

# Add the PBS 4.x repository
cat <<EOF > /etc/apt/sources.list.d/pbs-no-subscription.sources
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
EOF

# Install Proxmox Backup Server
apt update && apt upgrade -y
apt install -y proxmox-backup-server

# Disable pbs-enterprise repo - Borrowed from (https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pbs-install.sh)
echo "Disabling 'pbs-enterprise' repository"
# Use Enabled: false instead of commenting to avoid malformed entry
if grep -q "^Enabled:" /etc/apt/sources.list.d/pbs-enterprise.sources 2>/dev/null; then
    sed -i 's/^Enabled:.*/Enabled: false/' /etc/apt/sources.list.d/pbs-enterprise.sources
else
    echo "Enabled: false" >>/etc/apt/sources.list.d/pbs-enterprise.sources
fi
echo "Disabled 'pbs-enterprise' repository"

# Disable subscription nag - Borrowed from (https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pbs-install.sh)
echo "Disabling subscription nag"
echo "DPkg::Post-Invoke { \"if [ -s /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ] && ! grep -q -F 'NoMoreNagging' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; then sed -i '/data\\.status/{s/\\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; fi\" };" >/etc/apt/apt.conf.d/no-nag-script
echo "Disabled subscription nag (clear browser cache!)"