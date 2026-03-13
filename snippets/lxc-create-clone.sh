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

Options:
      --templateid <id>              Template LXC ID to clone from (default: 9000)
      --newid <id>                   New LXC ID (default: next available >= 1000)
      --mac <address>                MAC address for the new container (default: random)
      --zpool <id>                   zpool to store the disks on (default: flash)
      --help, -h                     Show this help message

Options to distiguish from Template LXC:
      --cores <integer> (1 - 8192)   CPU Cores (default: matches template)
      --memory <mb>                  Amount of RAM for the container in MB (default: matches template)
      --swap <mb>                    Swap in MB (default: matches template)
EOF
exit 1
}

#######################################################
# Parse script arguments
#######################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --templateid)   TEMPLATE_CTX_ID="$2";  [[ -z "$TEMPLATE_CTX_ID" ]]  && usage; shift 2 ;;
    --newid)        CLONE_CTX_ID="$2";     [[ -z "$CLONE_CTX_ID" ]]     && usage; shift 2 ;;
    --hostname)     CLONE_HOSTNAME="$2";   [[ -z "$CLONE_HOSTNAME" ]]   && usage; shift 2 ;;
    --mac)          CLONE_MAC="$2";        [[ -z "$CLONE_MAC" ]]        && usage; shift 2 ;;
    --zpool)        ZPOOL="$2";            [[ -z "$ZPOOL" ]]            && usage; shift 2 ;;
    --cores)        CTX_CORES="$2";        [[ -z "$CTX_CORES" ]]        && usage; shift 2 ;;
    --memory)       CTX_MEMORY="$2";       [[ -z "$CTX_MEMORY" ]]       && usage; shift 2 ;;
    --swap)         CTX_SWAP="$2";         [[ -z "$CTX_SWAP" ]]         && usage; shift 2 ;;
    --help|-h)      usage ;;
    *) echo "Unknown parameter: $1"; usage ;; # Handle unexpected flags
  esac
done


#######################################################
# Populate local variables, use defaults as needed
#######################################################
: "${TEMPLATE_CTX_ID:=9000}"
: "${ZPOOL:=flash}"

# Set the name of the EXISTING Zvol disk TEMPLATE_DOCKER_DISK
TEMPLATE_DOCKER_DISK_LIST=($(zfs list -H -o name | grep -E "^$ZPOOL/(base|sub)vol-$TEMPLATE_CTX_ID-docker$" || true))
[ ${#TEMPLATE_DOCKER_DISK_LIST[@]} -ne 1 ] && echo "Error: Expected exactly 1 Zvol matching $ZPOOL/(base|sub)vol-$TEMPLATE_CTX_ID-docker, but found ${#TEMPLATE_DOCKER_DISK_LIST[@]}." && exit 1
TEMPLATE_DOCKER_DISK="${TEMPLATE_DOCKER_DISK_LIST[0]}"

# Set the name of the new Zvol disk CLONE_DOCKER_DISK
CLONE_DOCKER_DISK="$ZPOOL/subvol-$CLONE_CTX_ID-docker"


#######################################################
# Check for requirements
#######################################################
# CLONE_HOSTNAME is required
[[ -z "$CLONE_HOSTNAME" ]] && { echo "Error: Must specify --hostname."; usage; }

# Template container must exist
pct config $TEMPLATE_CTX_ID >/dev/null 2>&1 || { echo "Error: Template LXC $TEMPLATE_CTX_ID not found."; exit 1; }


#######################################################
# Offer to delete clone lxc if it already exists
#######################################################
# --- Check for existing clone and dependents ---
if [ -f "/etc/pve/lxc/${CLONE_CTX_ID}.conf" ] || zfs list "$CLONE_DOCKER_DISK" &>/dev/null; then
    echo "Destination LXC $CLONE_CTX_ID or Zvol $CLONE_DOCKER_DISK already exists."

    # Find dependent clones (ZFS volumes that originated from this clone's Zvol)
    # Filter for volumes where the origin matches this clone's Zvol followed by '@'
    DEPENDENT_VOLUMES=$(zfs list -H -o name,origin -t volume | awk -v vol="$CLONE_DOCKER_DISK" '$2 ~ "^" vol "@" {print $1}')

    if [ -n "$DEPENDENT_VOLUMES" ]; then
        echo "WARNING: The following ZFS volumes are clones of this clone:"
        echo "$DEPENDENT_VOLUMES"
        echo "Proceeding will DESTROY this clone AND ALL CHILD LXCs associated with these volumes."
    else
        echo "Proceeding will DESTROY and re-create this clone."
    fi

    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi

    # Destroy Dependents
    for CLONE_VOL in $DEPENDENT_VOLUMES; do
        # Extract LXC ID from dependent volume name (assuming format *vol-ID-docker*)
        if [[ "$CLONE_VOL" =~ (base|sub)vol-([0-9]+)-docker ]]; then
            CLONE_ID="${BASH_REMATCH[2]}"
            echo "Stopping and destroying Child LXC $CLONE_ID..."
            pct stop "$CLONE_ID" &>/dev/null
            pct destroy "$CLONE_ID" --purge &>/dev/null
        fi
        
        # Destroy the dependent volume if it still exists
        if zfs list "$CLONE_VOL" &>/dev/null; then
            echo "Destroying Child Volume $CLONE_VOL..."
            zfs destroy -r "$CLONE_VOL"
        fi
    done
fi

# --- Destroy Template LXC Container if it exists ---
# Check if the config file exists (Standard PVE check for container existence)
if [ -f "/etc/pve/lxc/${CLONE_CTX_ID}.conf" ]; then
    pct stop $CLONE_CTX_ID &>/dev/null   # Stop the container silently if it is running
    # Destroy the container (purge removes config and disk)
    # Redirecting output to /dev/null to keep it clean, remove '&>/dev/null' if you want to see PVE logs
    pct destroy $CLONE_CTX_ID --purge &>/dev/null
    echo "Container $CLONE_CTX_ID destroyed."
fi

# --- Destroy Template ZFS Zvol if it exists ---
if zfs list "$CLONE_DOCKER_DISK" &>/dev/null; then # Check if the ZFS dataset/volume exists
    zfs destroy -r "$CLONE_DOCKER_DISK"       # Destroy recursively (-r) to handle any potential snapshots causing errors
    echo "Zvol $CLONE_DOCKER_DISK destroyed."
fi



#######################################################
# Populate additional defaults if not populated
#######################################################
# Default CLONE_MAC to a random MAC address if not populated
[ -z "$CLONE_MAC" ] && CLONE_MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# Default CLONE_CTX_ID to the next available CTX_ID, in the range 1000-1199 by doing a ls on /etc/pve/lxc
# This assumes we'll never have more than 200 LXCs in the whole cluster
[ -z "$CLONE_CTX_ID" ] && for id in {1000..1199}; do [ ! -f "/etc/pve/lxc/${id}.conf" ] && { CLONE_CTX_ID=$id; break; }; done


#######################################################
# Create the clone
#######################################################
pct stop "$TEMPLATE_CTX_ID" &>/dev/null                                                                          # Silently stop the Template LXC if it's started
zfs list -t snapshot "$TEMPLATE_DOCKER_DISK@clean" >/dev/null 2>&1 || zfs snapshot "$TEMPLATE_DOCKER_DISK@clean" # If it doesn't already exist, Snapshot the docker disk so it can be cloned
zfs clone "$TEMPLATE_DOCKER_DISK@clean" $CLONE_DOCKER_DISK                                                       # Clone the Template's docker disk (/var/lib/docker in the container)
pct clone $TEMPLATE_CTX_ID $CLONE_CTX_ID --hostname $CLONE_HOSTNAME                                              # Clone the Template LXC into a new Clone LXC
pct set $CLONE_CTX_ID --mp0 "/dev/zvol/$CLONE_DOCKER_DISK,mp=/var/lib/docker,backup=1"                           # Add the /var/lib/docker Zvol
pct set $CLONE_CTX_ID --net0 "name=eth0,bridge=vmbr0,hwaddr=$CLONE_MAC,ip=dhcp,type=veth"                        # Set the MAC address - don't forget to add the Static DHCP Mapping on your router
[ -n "$CTX_CORES" ] && pct set $CLONE_CTX_ID --cores "$CTX_CORES"                                                # Set the number of CPU cores
[ -n "$CTX_MEMORY" ] && pct set $CLONE_CTX_ID --memory "$CTX_MEMORY"                                             # Set the RAM in MB
[ -n "$CTX_SWAP" ] && pct set $CLONE_CTX_ID --swap "$CTX_SWAP"                                                   # Set the Swap in MB

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
