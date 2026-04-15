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

#Download and install the LATEST VERSION of each of these Cockpit plugins:
# https://github.com/45Drives/cockpit-file-sharing
# https://github.com/45Drives/cockpit-navigator
# https://github.com/45Drives/cockpit-identities

apt install -y curl wget jq # Ensure dependencies are installed


for PLUGIN in cockpit-file-sharing cockpit-navigator cockpit-identities; do
    echo "Fetching latest release of $PLUGIN..."
    
    # Get the latest release URL for the .deb package (using || true to prevent set -e from exiting if parsing fails)
    DEB_URL=$(curl -s "https://api.github.com/repos/45Drives/$PLUGIN/releases/latest" | jq -r '.assets[]? | select(.name | endswith(".deb")) | .browser_download_url' | head -n 1 || true)
    
    if [ -n "$DEB_URL" ]; then
        echo "Downloading $DEB_URL..."
        wget -qO "/tmp/${PLUGIN}.deb" "$DEB_URL"
        echo "Installing $PLUGIN..."
        apt install -y "/tmp/${PLUGIN}.deb"
        rm -f "/tmp/${PLUGIN}.deb"
    else
        echo "Error: Could not find .deb package for $PLUGIN in the latest release."
    fi
done

systemctl enable --now cockpit.socket # Enable the web service on boot


# Now open https://<YOUR-IP>:9090