#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

cat <<EOF
##############################################################################
# Install & Configure Cockpit (tested on a Debian 13 LXC on Proxmox v9.1)
# Usage: setup-cockpit.sh
# It's safe to re-run this script.
##############################################################################

EOF

apt update && apt upgrade -y                   # Update your package lists
apt install cockpit -y --no-install-recommends # Install the core Cockpit package

#Remove the line that says "root" from /etc/cockpit/disallowed-users
if [ -f "/etc/cockpit/disallowed-users" ]; then
    sed -i '/^root$/d' "/etc/cockpit/disallowed-users"
fi

# Install 45Drives Cockpit plugins:
# https://github.com/45Drives/cockpit-file-sharing
# https://github.com/45Drives/cockpit-navigator
# https://github.com/45Drives/cockpit-identities
apt install -y curl gnupg
curl -sSL https://repo.45drives.com/setup | bash
apt-get update
apt install cockpit-file-sharing cockpit-navigator cockpit-identities -y

systemctl enable --now cockpit.socket # Enable the web service on boot

echo "Success!"
echo "Open Cockpit at https://<YOUR-IP>:9090"