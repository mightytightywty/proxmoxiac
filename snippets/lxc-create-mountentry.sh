#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

#######################################################
# Function to display usage instructions
#######################################################
usage() {
cat <<EOF
Usage: $0 --vmid <id> --hostpath <path> --lxcpath <path> [OPTIONS]

Maps a single file or a directory at --hostpath to the LXC container at --lxcpath.
These mounts will be completely ignored by Proxmox's backup system (vzdump), replication system, and GUI.

Required:
    --vmid <id>             LXC ID to add the mountpoint to
    --hostpath <path>       Path on Host or ZFS dataset name (examples below)
                                /mnt/storage
                                flash/appdata-service-name
    --lxcpath <path>        Path on LXC (examples below)
                                /mnt/storage
                                /opt/docker/service-name

Optional:
    --readonly <0|1>        Set the read-only flag (default: 0 [full-access])
                                0=full-access, 1=read-only
    --optional <0|1>        Don't fail container startup if mount fails (default: 0)
    --chown <user:group>    Recursively change hostpath ownership? (default: 100000:10000 [lxcuser:lxcgroup])
                                User 100000 on host = 0 in the LXC
    --no-chown              Don't change hostpath ownership
    --chmod <mode>          Recursively change hostpath permissions? (default: 2775)
    --no-chmod              Don't change hostpath permissions
    --help, -h              Show this help message
EOF
exit 1
}

#######################################################
# Parse script arguments
#######################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)      CTX_ID="$2";    [[ -z "$CTX_ID" ]]    && usage; shift 2 ;;
        --hostpath)  HOST_PATH="$2"; [[ -z "$HOST_PATH" ]] && usage; shift 2 ;;
        --lxcpath)   LXC_PATH="$2";  [[ -z "$LXC_PATH" ]]  && usage; shift 2 ;;
        --readonly)  READONLY="$2";  [[ -z "$READONLY" ]]  && usage; shift 2 ;;
        --optional)  OPTIONAL="$2";  [[ -z "$OPTIONAL" ]]  && usage; shift 2 ;;
        --chown)     CHOWN="$2";     [[ -z "$CHOWN" ]]     && usage; shift 2 ;;
        --no-chown)  SKIP_CHOWN=1;   shift 1 ;;
        --chmod)     CHMOD="$2";     [[ -z "$CHMOD" ]]     && usage; shift 2 ;;
        --no-chmod)  SKIP_CHMOD=1;   shift 1 ;;
        --help|-h)      usage ;;
        *) echo "Unknown parameter: $1"; usage ;; # Handle unexpected flags
    esac
done

: "${CHOWN:=100000:10000}"
: "${CHMOD:=2775}"

# If CTX_ID or HOST_PATH or LXC_PATH are missing, show the help
[[ -z "$CTX_ID" || -z "$HOST_PATH" || -z "$LXC_PATH" ]] && usage

# If LXC_PATH doesn't look like a path, show the help
[[ ! "$LXC_PATH" =~ ^/ ]] && echo "Error: LXC path must be an absolute path (starting with /)." && usage

# Container CTX_ID must exist
pct config $CTX_ID >/dev/null 2>&1 || { echo "Error: LXC $CTX_ID not found."; exit 1; }

# If HOST_PATH doesn't start with a forward slash, it's a ZFS dataset path. Check the zpool to ensure it exists
if [[ ! "$HOST_PATH" =~ ^/ ]]; then
    ZPOOL_NAME=$(echo "$HOST_PATH" | cut -d'/' -f1)
    # Ensure the zpool exists
    zpool list "$ZPOOL_NAME" >/dev/null 2>&1 || { echo "Error: ZFS zpool '$ZPOOL_NAME' not found."; exit 1; }

    # Ensure the dataset exists else create it
    zfs list "$HOST_PATH" >/dev/null 2>&1 || { echo "Creating ZFS dataset $HOST_PATH..."; zfs create -p "$HOST_PATH" || { echo "Error: Failed to create ZFS dataset."; exit 1; } }

    # Ensure the mountpoint on the host is valid
    HOST_PATH=$(zfs get -H -o value mountpoint "$HOST_PATH")
    [ -z "$HOST_PATH" ] && echo "Error: Could not determine mountpoint for ZFS dataset." && exit 1
    [[ "$HOST_PATH" == "legacy" || "$HOST_PATH" == "none" ]] && echo "Error: ZFS dataset $HOST_PATH does not have a valid mountpoint." && exit 1
fi

#######################################################
# Add the HOST_PATH to the container
#######################################################
if [[ -d "$HOST_PATH" || -f "$HOST_PATH" ]]; then
    # Remove the leading slash from $LXC_PATH because with lxc.mount.entry, the path is relative to the container's root
    FIXED_LXC_PATH="${LXC_PATH#/}"

    # If there's already a mountentry with the same HOST_PATH OR LXC_PATH in the CTX_ID.conf file, remove the line completely
    ESCAPED_HOST_PATH=$(printf '%s\n' "$HOST_PATH" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')
    ESCAPED_LXC_PATH=$(printf '%s\n' "$FIXED_LXC_PATH" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')

    if grep -qE "^lxc\.mount\.entry: +($ESCAPED_HOST_PATH |[^ ]+ +$ESCAPED_LXC_PATH )" "/etc/pve/lxc/${CTX_ID}.conf"; then
        echo "Removing existing mountentry pointing to $HOST_PATH or $LXC_PATH..."
        sed -i -E "/^lxc\.mount\.entry: +($ESCAPED_HOST_PATH |[^ ]+ +$ESCAPED_LXC_PATH )/d" "/etc/pve/lxc/${CTX_ID}.conf"
    fi

    # Build mount options
    MOUNT_OPTS="bind"
    [ "$READONLY" == "1" ] && MOUNT_OPTS="${MOUNT_OPTS},ro"
    [ "$OPTIONAL" == "1" ] && MOUNT_OPTS="${MOUNT_OPTS},optional"
    [ -d "$HOST_PATH" ] && MOUNT_OPTS="${MOUNT_OPTS},create=dir"
    [ -f "$HOST_PATH" ] && MOUNT_OPTS="${MOUNT_OPTS},create=file"

    # Add LXC Mount entry as a data file/directory without using mountpoints
    echo "lxc.mount.entry: $HOST_PATH $FIXED_LXC_PATH none ${MOUNT_OPTS} 0 0" >> "/etc/pve/lxc/${CTX_ID}.conf"
else
    echo "Error: Host path/file $HOST_PATH does not exist." && usage
fi

# Set permissions on the host path
if [[ -z "$SKIP_CHOWN" ]]; then
    chown -R "$CHOWN" "$HOST_PATH" # LXC's root user sees the files as owned by root (because 100000 on host = 0 in container) and can write without permission errors
fi

if [[ -z "$SKIP_CHMOD" ]]; then
    chmod -R "$CHMOD" "$HOST_PATH"
fi

# Confirm completion
echo "Successfully added $HOST_PATH to CT $CTX_ID at $LXC_PATH" 

# Warn if the container is running, as mountpoints usually require a reboot to attach
if pct status "$CTX_ID" 2>/dev/null | grep -q "running"; then
    echo "WARNING: Container $CTX_ID is currently running. You must REBOOT it for the new mountpoint to be visible."
fi

#######################################################
# Show Usage Instructions
#######################################################
cat << EOF

#######################################################
# Usage Instructions
#######################################################
DOCKER CONTAINERS in the LXC:
If they have PUID/PGID options:

    environment:
      - PUID=1000   # Doesn't matter much
      - PGID=10000  # CRITICAL: Maps to your host storage group
    volumes:
      - ./data:/data                                   # ZFS Dataset (appdata) - relative path
      - /opt/docker/apprise/config:/config             # ZFS Dataset (appdata) - absolute path
      - /mnt/storage/media:/media                      # Optionally Mount the MergerFS Pool (if attached to LXC)

Otherwise, it'll run as root, which is also fine because root was added to the custom group via:
usermod -aG customgroup root

For Standard Images (without PUID/PGID): Usually, you don't need to do anything if you ran the usermod command above.
However, if a container insists on running as a specific non-root user (like postgres runs as user postgres),
and it needs to write to /mnt/storage (rare for a database, but possible), you would simply force it to run as root in the compose file:

    services:
      stubborn-app:
        image: stubborn-image
        user: root  # Force it to run as root so it inherits the sausey group permissions
EOF
