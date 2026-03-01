#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

# Global Variables
vmid="$1"                         # LXC VMID passed by Proxmox hook script
phase="$2"                        # Hook phase passed by Proxmox hook script

# Fetch Secrets
get_secrets() {
    # Usage: get_secrets "prefix_" (will get all secrets that start with "prefix_")
    local prefix="$1" max_retries=5 count=0 success=0 network_up=0 result="" BWS_ACCESS_TOKEN
    
    # Ensure the token exists
    [ -f "/etc/pve/priv/bws_access_token" ] && BWS_ACCESS_TOKEN=$(cat "/etc/pve/priv/bws_access_token")
    [ -z "$BWS_ACCESS_TOKEN" ] && echo "Error: No Bitwarden Secrets Manager Access token found in /etc/pve/priv/bws_access_token." && return 1
    
    # Ensure the network is up
    for i in {1..30}; do ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && network_up=1 && break; sleep 1; done
    [ "$network_up" -eq 0 ] && echo "ABORTING: Network connectivity not established." >&2 && return 1
    
    # Retrieve Bitwarden Secrets Manager Access Token
    echo "Fetching secrets from Bitwarden..."

    # Try to fetch secrets
    while [ $count -lt $max_retries ]; do
        result=$(/root/.local/bin/bws secret list --access-token "$BWS_ACCESS_TOKEN" --output json 2>&1)
        [ $? -eq 0 ] && { success=1; break; } || { echo "WARN: BWS connection failed (Attempt $((count+1))/$max_retries). Retrying in 5s..."; sleep 5; ((count++)); }
    done

    if [ $success -eq 1 ]; then
        echo "$result" | jq -r --arg prefix "$prefix" '
            .[] | 
            select(.key | startswith($prefix)) | 
            "export \(.key | sub($prefix; ""))=\(.value | @sh); "
        '
        return 0
    else
        echo "CRITICAL: BWS unreachable after $max_retries attempts. Error: $result"
        return 1
    fi
}

# Main Logic
case "$phase" in
    post-start)
        # Exit without error if /opt/docker doesn't exist
        pct exec "$vmid" -- [ -d "/opt/docker" ] || exit 0
        
        echo "Starting docker deployment sequence."
        
        # Git pull the latest infrastructure-as-code from repository
        git -C "/root/infrastructure" pull origin main --rebase --autostash || { echo "ABORTING: Could not pull latest infrastructure-as-code from Git."; exit 1; }
        
        # Fetch Environment Variables that start with "VMID_", exit if failed
        ENV_EXPORTS=$(get_secrets "${vmid}_") || { echo "ABORTING: Could not retrieve secrets from Bitwarden Secrets Manager."; exit 1; }

        # Find directories inside the LXC under the docker root folder -L follows symbolic links
        # Use mapfile to safely handle paths with spaces
        mapfile -t LXC_SERVICE_PATHS < <(pct exec "$vmid" -- find -L "/opt/docker" -mindepth 1 -maxdepth 1 -type d)

        if [ ${#LXC_SERVICE_PATHS[@]} -eq 0 ]; then
            echo "No docker service directories found in /opt/docker."
        else
            for LXC_SERVICE_PATH in "${LXC_SERVICE_PATHS[@]}"; do
                LXC_SERVICE_PATH="${LXC_SERVICE_PATH%$'\r'}" # Remove carriage return sometimes added by pct exec
                SERVICE_NAME=$(basename "$LXC_SERVICE_PATH")
                HOST_SERVICE_PATH="/root/infrastructure/docker/$SERVICE_NAME"

                # Sync latest docker config from host to LXC, overwriting config files from IAC, without deleting extra (appdata) files found in LXC
                if [ ! -d "$HOST_SERVICE_PATH" ]; then
                    echo "Can't find docker config on proxmox host at $HOST_SERVICE_PATH. Docker config on LXC at $LXC_SERVICE_PATH will not be updated."
                else
                    echo "Syncing $SERVICE_NAME config to LXC $vmid..."
                    # Sync via tar (recommended for few, smaller files)
                    tar -chf - -C "/root/infrastructure/docker/" "$SERVICE_NAME" | pct exec "$vmid" -- tar -xf - -C "/opt/docker/" --no-same-owner

                    # Sync via rsync (recommended for many files)
                    # MOUNTPOINT=$(pct mount "$vmid") && rsync -av "/root/infrastructure/docker/$SERVICE_NAME/" "$MOUNTPOINT/opt/docker/$SERVICE_NAME/" && pct unmount "$vmid"

                    # Sync via pct push
                    # pct push "$vmid" "/root/infrastructure/docker/$SERVICE_NAME" "/opt/docker/"
                fi

                # Start docker stack on LXC
                echo "Starting $SERVICE_NAME..."
                echo "Docker Output: $(pct exec "$vmid" -- /bin/bash -c "cd \"$LXC_SERVICE_PATH\" && $ENV_EXPORTS docker compose up -d --remove-orphans" 2>&1)"
            done
        fi

        # Cleanup
        PRUNE_OUT=$(pct exec "$vmid" -- docker image prune -f 2>&1)
        echo "Cleanup: $PRUNE_OUT"
        ;;

    pre-stop)
        # Exit without error if /opt/docker doesn't exist
        pct exec "$vmid" -- [ -d "/opt/docker" ] || exit 0

        # Stop all services
        echo "Stopping services."
        mapfile -t LXC_SERVICE_PATHS < <(pct exec "$vmid" -- find -L "/opt/docker" -mindepth 1 -maxdepth 1 -type d)
        
        if [ ${#LXC_SERVICE_PATHS[@]} -gt 0 ]; then
            for LXC_SERVICE_PATH in "${LXC_SERVICE_PATHS[@]}"; do
                LXC_SERVICE_PATH="${LXC_SERVICE_PATH%$'\r'}" # Remove carriage return sometimes added by pct exec
                SERVICE_NAME=$(basename "$LXC_SERVICE_PATH")
                 echo "Stopping $SERVICE_NAME..."
                 pct exec "$vmid" -- /bin/bash -c "cd \"$LXC_SERVICE_PATH\" && docker compose down"
            done
        fi
        
        echo "All services stopped."
        ;;
esac

exit 0