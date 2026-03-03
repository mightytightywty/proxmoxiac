#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

cat <<EOF
##############################################################################
# Install & Configure HD-Idle (tested on Proxmox)
# Usage: setup-hd-idle.sh [idle_seconds]
# If [idle_seconds] is not passed (or it's not a valid number), the user will be prompted to choose an idle time before spindown.
# This script will find all spinning HDDs, and add them to the config file.
# It's safe to re-run this script.
##############################################################################
EOF

# These are the two important lines that will be added/updated in the config file:
# START_HD_IDLE=true
# HD_IDLE_OPTS="-i 0 -a sdc -i 600 -a sdd -i 600"
#
# Options Used:
# -i 0 disables default spindown
# -a sda -i 600 Spindown sda after 600 seconds (10 minutes)

# Set HDD_IDLE_SECONDS
HDD_IDLE_SECONDS="$1"

# Validate HDD_IDLE_SECONDS if passed, otherwise prompt
[[ -n "$HDD_IDLE_SECONDS" && ! "$HDD_IDLE_SECONDS" =~ ^[0-9]+$ ]] && echo "Error: '$HDD_IDLE_SECONDS' is not a valid number." && HDD_IDLE_SECONDS=""
while [[ -z "$HDD_IDLE_SECONDS" ]]; do
    read -r -p "How long should the drives be idle before spinning down? (in seconds) [600]: " HDD_IDLE_SECONDS && HDD_IDLE_SECONDS="${HDD_IDLE_SECONDS:-600}"
    [[ ! "$HDD_IDLE_SECONDS" =~ ^[0-9]+$ ]] && echo "Error: '$HDD_IDLE_SECONDS' is not a valid number." && HDD_IDLE_SECONDS=""
done

# hdparm and smartmontools help us find all spinning HDDs (likely preinstalled on Proxmox)
apt update >> /dev/null 2>&1 & apt install -y hdparm smartmontools

# Build the Options String
HD_IDLE_OPTS="-i 0"
while read -r DISK SIZE; do
    smartctl -i "/dev/$DISK" 2>/dev/null | grep -qi "rpm" && HD_IDLE_OPTS="$HD_IDLE_OPTS -a $DISK -i $HDD_IDLE_SECONDS" || true
done < <(lsblk -ndo NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}')

# if No spinning disks were found then
if [ "$HD_IDLE_OPTS" = "-i 0" ]; then
    echo "No drives found matching criteria. Exiting."
    echo "Debug Info - All sd disks found:"
    lsblk -d -n -o NAME,SIZE | grep "^sd"
    exit 1
fi

# Install hd-idle
apt install -y hd-idle

# Backup the existing Config File
CONFIG_FILE="/etc/default/hd-idle"
[ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%F_%T)" || touch "$CONFIG_FILE"

# Set START_HD_IDLE=true
sed -i '/^#\?START_HD_IDLE=/d' "$CONFIG_FILE"
echo "START_HD_IDLE=true" >> "$CONFIG_FILE"

# Set HD_IDLE_OPTS
sed -i '/^#\?HD_IDLE_OPTS=/d' "$CONFIG_FILE"
echo "HD_IDLE_OPTS=\"$HD_IDLE_OPTS\"" >> "$CONFIG_FILE"

echo "Success! Config updated."
echo "New Options: $HD_IDLE_OPTS"
systemctl enable hd-idle
systemctl restart hd-idle

# Display current spinning drive states
while read -r DISK SIZE; do
    smartctl -i "/dev/$DISK" 2>/dev/null | grep -qi "rpm" && { echo -n "/dev/$DISK ($SIZE): "; hdparm -C "/dev/$DISK" | grep 'drive state'; } || true
done < <(lsblk -ndo NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}')