#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

#######################################################
# Function to display usage instructions
#######################################################
usage() {
cat <<EOF
Usage: $0 --hostname <hostname> [OPTIONS]

Required:
      --hostname <name>   Hostname for the new LXC container

Optional:
      --vmid <id>         Template LXC ID to clone from (default: 9000)
      --newid <id>        New LXC ID (default: next available >= 1000)
      --mac <address>     MAC address for the new container (default: random)
      --zpool <id>        zpol to store the disks on (default: cache)
      --help, -h          Show this help message
EOF
exit 1
}

#######################################################
# Parse script arguments
#######################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid)     TEMPLATE_CTX_ID="$2"; [[ -z "$TEMPLATE_CTX_ID" ]] && usage; shift 2 ;;
    --newid)    CLONE_CTX_ID="$2";    [[ -z "$CLONE_CTX_ID" ]] && usage;    shift 2 ;;
    --hostname) CLONE_HOSTNAME="$2";  [[ -z "$CLONE_HOSTNAME" ]] && usage;  shift 2 ;;
    --mac)      CLONE_MAC="$2";       [[ -z "$CLONE_MAC" ]] && usage;       shift 2 ;;
    --zpool)    ZPOOL="$2";        [[ -z "$CLONE_MAC" ]] && usage;       shift 2 ;;
    --help|-h)  usage ;;
    *) echo "Unknown parameter: $1"; usage ;; # Handle unexpected flags
  esac
done

#######################################################
# Populate defaults if not populated
#######################################################
: "${TEMPLATE_CTX_ID:=9000}"
: "${ZPOOL:=cache}"
TEMPLATE_DOCKER_DISK="$ZPOOL/basevol-$TEMPLATE_CTX_ID-docker"

# CLONE_HOSTNAME is required
[[ -z "$CLONE_HOSTNAME" ]] && { echo "Error: Must specify --hostname."; usage; }

# Template container must exist
pct config $TEMPLATE_CTX_ID >/dev/null 2>&1 || { echo "Error: Template LXC $TEMPLATE_CTX_ID not found."; exit 1; }

# Template docker Zvol disk must exist
zfs list "$TEMPLATE_DOCKER_DISK" >/dev/null 2>&1 || { echo "Error: Template Zvol $TEMPLATE_DOCKER_DISK not found."; exit 1; }

# Default CLONE_MAC to a random MAC address if not populated
[ -z "$CLONE_MAC" ] && CLONE_MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# Default CLONE_CTX_ID to the next available CTX_ID, in the range 1000-1199 by doing a ls on /etc/pve/lxc
# This assumes we'll never have more than 200 LXCs in the whole cluster
[ -z "$CLONE_CTX_ID" ] && for id in {1000..1199}; do [ ! -f "/etc/pve/lxc/${id}.conf" ] && { CLONE_CTX_ID=$id; break; }; done

#######################################################
# Create the clone
#######################################################
CLONE_DOCKER_DISK="$ZPOOL/subvol-$CLONE_CTX_ID-docker"                                     # CLONE_DOCKER_DISK is derived from the CLONE_CTX_ID
zfs clone "$TEMPLATE_DOCKER_DISK@clean" $CLONE_DOCKER_DISK                                # Clone the Template's docker disk (/var/lib/docker in the container)
pct clone $TEMPLATE_CTX_ID $CLONE_CTX_ID --hostname $CLONE_HOSTNAME                       # Clone the Template LXC into a new Clone LXC
pct set $CLONE_CTX_ID --mp0 "/dev/zvol/$CLONE_DOCKER_DISK,mp=/var/lib/docker,backup=1"    # Add the /var/lib/docker Zvol
pct set $CLONE_CTX_ID --net0 "name=eth0,bridge=vmbr0,hwaddr=$CLONE_MAC,ip=dhcp,type=veth" # Set the MAC address - don't forget to add the Static DHCP Mapping on your router

#######################################################
# Start the clone and display info to the user
#######################################################
pct start $CLONE_CTX_ID
# Wait for network connectivity
echo "Waiting for network connectivity..."
pct exec "$CLONE_CTX_ID" -- /bin/sh -c 'i=0; while [ $i -lt 30 ]; do ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && exit 0; sleep 1; i=$((i+1)); done; exit 1'


#Display the Clone details to the user
CLONE_IP=$(pct exec $CLONE_CTX_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
CLONE_MAC_ACTUAL=$(pct config $CLONE_CTX_ID | grep "^net0:" | grep -oP 'hwaddr=\K[0-9A-Fa-f:]{17}')
echo "#######################################################"
echo "Clone Complete!"
echo "Hostname: $CLONE_HOSTNAME"
echo "VMID:     $CLONE_CTX_ID"
echo "IP:       $CLONE_IP"
echo "MAC:      $CLONE_MAC_ACTUAL"
echo "#######################################################"
