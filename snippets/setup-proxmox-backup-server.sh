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
apt-get update && apt-get dist-upgrade -y

# Download Proxmox key
wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg

# Add the PBS 4.x repository
echo "deb http://download.proxmox.com/debian/pbs trixie pbs-no-subscription" > /etc/apt/sources.list.d/pbs.list

# Install Proxmox Backup Server
apt-get update && apt-get install proxmox-backup-server -y