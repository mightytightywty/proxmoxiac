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

Required:
  --vmid <id>            LXC ID to add the mountpoint to
  --hostpath <path>      Path on Host or ZFS dataset name (examples below)
                            /mnt/storage
                            flash/appdata-service-name
  --lxcpath <path>       Path on LXC (examples below)
                            /mnt/storage
                            /opt/docker/service-name

Optional:
  --acl <0|1>            Enable ACLs? (default: null [system default])
  --backup <0|1>         Set the backup flag (defaults to 1 for ZFS Datasets or 0 for standard paths)
  --readonly <0|1>       Set the read-only flag (default: 0 [full-access])
                            0=full-access, 1=read-only
  --replicate <0|1>      Replication Enabled? (default: 1 [enabled])
  --chown <user:group>   Recursively change hostpath ownership? (default: 100000:10000 [lxcuser:lxcgroup])
                            -1=Don't change hostpath ownership
                            User 100000 on host = 0 in the LXC
  --chmod <mode>         Recursively change hostpath permissions? (default: 2775)
                            -1=Don't change hostpath permissions
  --help, -h             Show this help message
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
    --acl)       ACL="$2";       [[ -z "$ACL" ]]       && usage; shift 2 ;;
    --backup)    BACKUP="$2";    [[ -z "$BACKUP" ]]    && usage; shift 2 ;;
    --readonly)  READONLY="$2";  [[ -z "$READONLY" ]]  && usage; shift 2 ;;
    --replicate) REPLICATE="$2"; [[ -z "$REPLICATE" ]] && usage; shift 2 ;;
    --chown)     CHOWN="$2";     [[ -z "$CHOWN" ]]     && usage; shift 2 ;;
    --chmod)     CHMOD="$2";     [[ -z "$CHMOD" ]]     && usage; shift 2 ;;
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

    BACKUP=${BACKUP:-1} # Default Backup to 1 if not set
else
    # If it's a standard path, ensure it exists on the host
    [ ! -d "$HOST_PATH" ] && echo "Error: Host path $HOST_PATH does not exist." && usage

    BACKUP=${BACKUP:-0} # Default Backup to 0 if not set
fi

# Set ownership on the host path
if [[ "$CHOWN" != "-1" ]]; then
    chown -R "$CHOWN" "$HOST_PATH"
fi

# Set permissions on the host path
if [[ "$CHMOD" != "-1" ]]; then
    chmod -R "$CHMOD" "$HOST_PATH"
fi

# If there's already a mountpoint pointing to HOST_PATH in the CTX_ID.conf file, remove the mountpoint
ESCAPED_HOST_PATH=$(printf '%s\n' "$HOST_PATH" | sed 's/[].[^$\\*+?()|{}]/\\&/g')
EXISTING_MP=$(grep -E "^mp[0-9]+: ([^,]*=)?$ESCAPED_HOST_PATH," "/etc/pve/lxc/${CTX_ID}.conf" | cut -d':' -f1 || true)
if [ -n "$EXISTING_MP" ]; then
    echo "Removing existing mountpoint $EXISTING_MP pointing to $HOST_PATH..."
    pct set "$CTX_ID" --delete "$EXISTING_MP"
fi

#######################################################
# Add the dataset to the container
#######################################################
MP_ID=0; while grep -q "^mp$MP_ID:" "/etc/pve/lxc/${CTX_ID}.conf"; do MP_ID=$((MP_ID+1)); done  # Iterate to find next free mp index
MP_OPTS="$HOST_PATH,mp=$LXC_PATH,backup=$BACKUP"                                                # Baseline mountpoint options
[ -n "$ACL" ] && MP_OPTS="${MP_OPTS},acl=$ACL"                                                  # Add ACL if applicable
[ -n "$READONLY" ] && MP_OPTS="${MP_OPTS},ro=$READONLY"                                         # Add Read-Only if applicable
[ -n "$REPLICATE" ] && MP_OPTS="${MP_OPTS},replicate=$REPLICATE"                                # Add Replicate if applicable
pct set "$CTX_ID" --mp"$MP_ID" "$MP_OPTS"                                                       # Apply mountpoint
echo "Successfully added $HOST_PATH to CT $CTX_ID at $LXC_PATH as mp$MP_ID with backup=$BACKUP" # Confirm completion

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
