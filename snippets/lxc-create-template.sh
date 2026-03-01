#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

#######################################################
# Function to display usage instructions
#######################################################
usage() {
cat <<EOF
Usage: $0 [OPTIONS]
Required:
  --hostname <name>            Hostname (default: alpine-docker-template)

Options:
  --vmid <id>                  Template LXC ID (default: next available >= 9000)
                                  If it exists, it will delete all clones, and rebuild everything from scratch.
  --rootfs <spec>              Root filesystem spec (default: volume=cache:10)
                                  [volume=]<volume> [,acl=<1|0>] [,mountoptions=<opt[;opt...]>] [,quota=<1|0>] [,replicate=<1|0>] [,ro=<1|0>] [,shared=<1|0>] [,size=<DiskSize>]
  --distro <name>              Distro (default: alpine) <alpine | debian | debian-13-standard | ubuntu>  etc...
  --root                          See all via 'pveam update && pveam available --section system'
  --ostype <type>              OS Type (default: alpine) <alpine | archlinux | centos | debian | devuan | fedora | gentoo | nixos | opensuse | ubuntu | unmanaged>
  --unprivileged <0|1>         Unprivileged container (default: 1)
  --nameserver <ip>            DNS Server (default: 1.1.1.1)
  --hookscript <path>          Hookscript path (default: infrastructure:snippets/lxc-hookscript-docker.sh)
                                  This script is executed during various steps in the LXC lifetime.
  --cores <num>                CPU Cores (default: 1) If blank, container can use all available cores
  --memory <mb>                Memory in MB (default: 1024)
  --swap <mb>                  Swap in MB (default: 512)
  --storage <id>               Target Proxmox Storage ID (default: cache) <cache | local>
  --password <pwd>             Root password. If not defined (recommended), root account is locked from login via SSH, etc.
  --map_host_tun <0|1>         Grants the container read and write permissions for the host TUN character device. Useful for VPNs, Tailscale, etc. (default: 0)
  --zvol_for_docker <path>     ZVol for Docker (default: cache/basevol-<vmid>-docker)
                                  Will be formatted in ext4, to be used for /var/lib/docker within each LXC
  --zvol_for_docker_size <sz>  ZVol size (default: 50G)
                                  Will hold all docker images, volumes, etc. Can be resized later if required.
  --help, -h                   Show this help message
EOF
exit 1
}

#######################################################
# Parse script arguments
#######################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --vmid)                 CTX_ID="$2";           [[ -z "$CTX_ID" ]] && usage;           shift 2 ;;
    --hostname)             CTX_HOSTNAME="$2";     [[ -z "$CTX_HOSTNAME" ]] && usage;     shift 2 ;;
    --rootfs)               CTX_ROOTFS="$2";       [[ -z "$CTX_ROOTFS" ]] && usage;       shift 2 ;;
    --distro)               CTX_DISTRO="$2";       [[ -z "$CTX_DISTRO" ]] && usage;       shift 2 ;;
    --ostype)               CTX_OSTYPE="$2";       [[ -z "$CTX_OSTYPE" ]] && usage;       shift 2 ;;
    --unprivileged)         CTX_UNPRIVILEGED="$2"; [[ -z "$CTX_UNPRIVILEGED" ]] && usage; shift 2 ;;
    --nameserver)           CTX_NAMESERVER="$2";   [[ -z "$CTX_NAMESERVER" ]] && usage;   shift 2 ;;
    --hookscript)           CTX_HOOKSCRIPT="$2";   [[ -z "$CTX_HOOKSCRIPT" ]] && usage;   shift 2 ;;
    --cores)                CTX_CORES="$2";        [[ -z "$CTX_CORES" ]] && usage;        shift 2 ;;
    --memory)               CTX_MEMORY="$2";       [[ -z "$CTX_MEMORY" ]] && usage;       shift 2 ;;
    --swap)                 CTX_SWAP="$2";         [[ -z "$CTX_SWAP" ]] && usage;         shift 2 ;;
    --storage)              CTX_STORAGE="$2";      [[ -z "$CTX_STORAGE" ]] && usage;      shift 2 ;;
    --password)             CTX_PASSWORD="$2";     [[ -z "$CTX_PASSWORD" ]] && usage;     shift 2 ;;
    --map_host_tun)         CTX_HOST_TUN="$2";     [[ -z "$CTX_HOST_TUN" ]] && usage;     shift 2 ;;
    --zvol_for_docker)      ZVOL_DOCKER="$2";      [[ -z "$ZVOL_DOCKER" ]] && usage;      shift 2 ;;
    --zvol_for_docker_size) ZVOL_DOCKER_SIZE="$2"; [[ -z "$ZVOL_DOCKER_SIZE" ]] && usage; shift 2 ;;
    --help|-h)              usage ;;
    *) echo "Unknown parameter: $1"; usage ;; # Handle unexpected flags
  esac
done

# if distro is specified, but ostype is not, or vice versa throw an error and exit.
if { [ -n "$CTX_DISTRO" ] && [ -z "$CTX_OSTYPE" ]; } || { [ -z "$CTX_DISTRO" ] && [ -n "$CTX_OSTYPE" ]; }; then
    echo "Error: If --distro is specified, --ostype must also be specified and vice versa."
    exit 1
fi

#######################################################
# Set Defaults
#######################################################
: "${CTX_HOSTNAME:=alpine-docker-template}"
: "${CTX_ROOTFS:=volume=cache:10}"
: "${CTX_DISTRO:=alpine}"
: "${CTX_OSTYPE:=alpine}"
: "${CTX_UNPRIVILEGED:=1}"
: "${CTX_NAMESERVER:=1.1.1.1}"
: "${CTX_HOOKSCRIPT:=infrastructure:snippets/lxc-hookscript-docker.sh}"
: "${CTX_CORES:=1}"
: "${CTX_MEMORY:=1024}"
: "${CTX_SWAP:=512}"
: "${CTX_STORAGE:=cache}"
: "${CTX_PASSWORD:=}"
: "${CTX_HOST_TUN:=0}"
: "${ZVOL_DOCKER:=cache/basevol-$CTX_ID-docker}"
: "${ZVOL_DOCKER_SIZE:=50G}"

# Default CTX_ID to the next available ID, in the range 9000-9099 by doing a ls on /etc/pve/lxc # This assumes we'll never have more than 100 LXC Templates in the whole cluster
[ -z "$CTX_ID" ] && for id in {9000..9099}; do [ ! -f "/etc/pve/lxc/${id}.conf" ] && { CTX_ID=$id; break; }; done

#######################################################
# Main Logic
#######################################################

# --- Check for existing template and dependents ---
if [ -f "/etc/pve/lxc/${CTX_ID}.conf" ] || zfs list "$ZVOL_DOCKER" &>/dev/null; then
    echo "Template LXC $CTX_ID or Zvol $ZVOL_DOCKER already exists."

    # Find dependent clones (ZFS volumes that originated from the template Zvol)
    # Filter for volumes where the origin matches the template Zvol followed by '@'
    DEPENDENT_VOLUMES=$(zfs list -H -o name,origin -t volume | awk -v vol="$ZVOL_DOCKER" '$2 ~ "^" vol "@" {print $1}')

    if [ -n "$DEPENDENT_VOLUMES" ]; then
        echo "WARNING: The following ZFS volumes are clones of this template:"
        echo "$DEPENDENT_VOLUMES"
        echo "Proceeding will DESTROY the template AND ALL CHILD LXCs associated with these volumes."
    else
        echo "Proceeding will destroy and re-create the template."
    fi

    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi

    # Destroy Dependents
    for CLONE_VOL in $DEPENDENT_VOLUMES; do
        # Extract LXC ID from dependent volume name (assuming format *basevol-ID-docker*)
        if [[ "$CLONE_VOL" =~ basevol-([0-9]+)-docker ]]; then
            CLONE_ID="${BASH_REMATCH[1]}"
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
if [ -f "/etc/pve/lxc/${CTX_ID}.conf" ]; then
    pct stop $CTX_ID &>/dev/null   # Stop the container silently if it is running
    # Destroy the container (purge removes config and disk)
    # Redirecting output to /dev/null to keep it clean, remove '&>/dev/null' if you want to see PVE logs
    pct destroy $CTX_ID --purge &>/dev/null
    echo "Container $CTX_ID destroyed."
fi

# --- Destroy Template ZFS Zvol if it exists ---
if zfs list "$ZVOL_DOCKER" &>/dev/null; then # Check if the ZFS dataset/volume exists
    zfs destroy -r "$ZVOL_DOCKER"       # Destroy recursively (-r) to handle any potential snapshots causing errors
    echo "Zvol $ZVOL_DOCKER destroyed."
fi

# Download LXC CT Template  # Or do it manually via: Datacenter > servername > local (storage) > CT Templates > Templates > <distro> > Download
echo "Updating template list..."
pveam update && echo "Update complete." # Update local distro database

# Find the full template filename based on the CTX_DISTRO search string
CT_TEMPLATE=$(pveam available --section system | awk -v pat="$CTX_DISTRO" '$0 ~ pat {print $2}' | sort -r | head -n 1) # Find latest match
: "${CT_TEMPLATE:?Error: No template found matching '$CTX_DISTRO'.}" # Exit if missing

# Check if already downloaded, otherwise download it
if pveam list local | grep -q "$CT_TEMPLATE"; then
    echo "Template '$CT_TEMPLATE' already exists on 'local' storage."
else
    echo "Downloading '$CT_TEMPLATE' to 'local'..."
    pveam download local "$CT_TEMPLATE" && echo "Download successful." # Perform the download
fi

# Create a ZFS volume for the template (adjust size as needed)
zfs create -s -V "$ZVOL_DOCKER_SIZE" "$ZVOL_DOCKER" && sleep 5
zfs set user:comment="ext4 zvol for /var/lib/docker" "$ZVOL_DOCKER"

# Format it as ext4 on the HOST
mkfs.ext4 -F /dev/zvol/$ZVOL_DOCKER

# Set up permissions on the zfs zvol so the LXC can access it
mkdir -p /mnt/tmp_docker_setup
mount /dev/zvol/$ZVOL_DOCKER /mnt/tmp_docker_setup
chown 100000:10000 /mnt/tmp_docker_setup
chmod 2775 /mnt/tmp_docker_setup
umount /mnt/tmp_docker_setup
rm -rf /mnt/tmp_docker_setup

# create the container
CREATE_ARGS=(
  "$CTX_ID" "/var/lib/vz/template/cache/$CT_TEMPLATE"
  --net0 "name=eth0,bridge=vmbr0,ip=dhcp"
  --timezone "host"
  --ssh-public-keys "/root/.ssh/authorized_keys"
  --mp0 "/dev/zvol/$ZVOL_DOCKER,mp=/var/lib/docker,backup=1"
  --features nesting=1,keyctl=1
)

[ -n "$CTX_PASSWORD" ] && CREATE_ARGS+=(--password "$CTX_PASSWORD")
[ -n "$CTX_MEMORY" ] && CREATE_ARGS+=(--memory "$CTX_MEMORY")
[ -n "$CTX_SWAP" ] && CREATE_ARGS+=(--swap "$CTX_SWAP")
[ -n "$CTX_HOSTNAME" ] && CREATE_ARGS+=(--hostname "$CTX_HOSTNAME")
[ -n "$CTX_STORAGE" ] && CREATE_ARGS+=(--storage "$CTX_STORAGE")
[ -n "$CTX_CORES" ] && CREATE_ARGS+=(--cores "$CTX_CORES")
[ -n "$CTX_OSTYPE" ] && CREATE_ARGS+=(--ostype "$CTX_OSTYPE")
[ -n "$CTX_ROOTFS" ] && CREATE_ARGS+=(--rootfs "$CTX_ROOTFS")
[ -n "$CTX_UNPRIVILEGED" ] && CREATE_ARGS+=(--unprivileged "$CTX_UNPRIVILEGED")
[ -n "$CTX_NAMESERVER" ] && CREATE_ARGS+=(--nameserver "$CTX_NAMESERVER")
[ -n "$CTX_HOOKSCRIPT" ] && CREATE_ARGS+=(--hookscript "$CTX_HOOKSCRIPT")

pct create "${CREATE_ARGS[@]}"

# APPLY EXTRA PERMISSIONS:
# Map UID 0-65535 inside to 100000-165535 on host (Standard)
# Map GID 0-9999 inside to 100000-109999 on host
# Map GID 10000 inside to 10000 on host (THE MAGIC LINE)
# Map GID 10001-65535 inside to 110001-165535 on host
cat <<EOF >> "/etc/pve/lxc/$CTX_ID.conf"
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 10000
lxc.idmap: g 10000 10000 1
lxc.idmap: g 10001 110001 55535
EOF

# Grants the container read and write permissions for the host TUN character device
# Bind mounts the TUN device directly into the container filesystem
if [ "$CTX_HOST_TUN" == 1 ]; then
cat <<EOF >> "/etc/pve/lxc/$CTX_ID.conf"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
fi

rm -f /var/lib/vz/template/cache/$CT_TEMPLATE  # Delete the template, now that we're done with it
pct start $CTX_ID                              # Start the container

# Wait for network connectivity
echo "Waiting for network connectivity..."
for i in {1..30}; do pct exec "$CTX_ID" -- ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && break || sleep 1; done

# Detect Alpine Linux
if pct exec $CTX_ID -- [ -f /etc/alpine-release ]; then
    echo "Detected Alpine Linux."
    pct exec $CTX_ID -- /bin/sh -c "apk update && apk upgrade"
    pct exec $CTX_ID -- /bin/sh -c "apk add bash tar curl docker docker-cli-compose tzdata shadow" # Install bash, docker, docker-compose, tzdata (for timezone) and shadow (for groupadd/usermod)
    pct exec $CTX_ID -- /bin/sh -c "rc-update add docker default"
    pct exec $CTX_ID -- /bin/sh -c "service docker start"
else
    echo "Detected Debian/Ubuntu."
    pct exec $CTX_ID -- bash -c "apt update && apt upgrade -y"           # update the container
    pct exec $CTX_ID -- bash -c "apt install -y curl"                    # install packages (curl)
    pct exec $CTX_ID -- bash -c "curl -fsSL https://get.docker.com | sh" # install docker
    pct exec $CTX_ID -- bash -c "systemctl enable --now docker"          # enable and start the docker daemon
fi

# Set up Group ID 10000 to match Proxmox Host
NON_ROOT_GROUP_NAME=$(getent group 10000 | cut -d: -f1)              # Get the name of group 10000 on the proxmox host if it exists
NON_ROOT_GROUP_NAME=${NON_ROOT_GROUP_NAME:-lxcgroup}                 # If not, default to 'lxcgroup'
pct exec $CTX_ID -- bash -c "groupadd -g 10000 $NON_ROOT_GROUP_NAME" # Create the same group inside the container with the same group id (10000)
pct exec $CTX_ID -- bash -c "usermod -aG $NON_ROOT_GROUP_NAME root"  # Add root user to the group since docker will normally run as root. Manually add other users as needed.

#pct exec $CTX_ID -- df -hT /var/lib/docker                           # verify disk space

# verify docker is using the correct storage driver - should be "overlay2"
DOCKER_DRIVER=$(pct exec $CTX_ID -- docker info --format '{{.Driver}}')
if [[ "$DOCKER_DRIVER" != "overlay2" && "$DOCKER_DRIVER" != "overlayfs" ]]; then
    echo "WARNING: Docker is using storage driver '$DOCKER_DRIVER' instead of 'overlay2' or 'overlayfs'."
    read -p "This may cause performance issues or nesting errors. Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting. Cleaning up..."
        pct stop $CTX_ID &>/dev/null
        pct destroy $CTX_ID --purge &>/dev/null
        zfs destroy -r "$ZVOL_DOCKER" &>/dev/null
        exit 1
    fi
fi

# Cleanup LXC before converting it into a template
if pct exec $CTX_ID -- [ -f /etc/alpine-release ]; then         # Detect Alpine Linux
    pct exec $CTX_ID -- bash -c "rm -rf /var/cache/apk/*"       # Remove APK cache
else                                                            # Default to Debian/Ubuntu
    pct exec $CTX_ID -- bash -c "apt clean"                     # Clean apt cache
    pct exec $CTX_ID -- bash -c "rm -rf /var/lib/apt/lists/*"   # Remove temporary files
fi

# Reset Machine ID (CRITICAL for DHCP)
# This forces the cloned LXC to generate a unique IP address on first boot
pct exec $CTX_ID -- bash -c "truncate -s 0 /etc/machine-id"
pct exec $CTX_ID -- bash -c "if [ -f /var/lib/dbus/machine-id ]; then rm /var/lib/dbus/machine-id; ln -s /etc/machine-id /var/lib/dbus/machine-id; fi"

#Clear logs and command history
pct exec $CTX_ID -- bash -c "truncate -s 0 /var/log/*log"
pct exec $CTX_ID -- bash -c "rm -f /root/.bash_history"

pct shutdown $CTX_ID                                            #shutdown the container
pct set $CTX_ID --delete mp0                                    #remove mp0 (zvol) before cloning or templating
pct template $CTX_ID                                            #convert it to a formal template (this doesn't work if you have mountpoints)
zfs snapshot "$ZVOL_DOCKER@clean"                               #Snapshot the docker disk so it can be cloned
