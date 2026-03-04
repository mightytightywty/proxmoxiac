#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

echo "===================================================================================="
echo "       Proxmox Helper Script Setup"
echo "       https://community-scripts.github.io/ProxmoxVE/scripts?id=post-pve-install"
echo "===================================================================================="
if read -p "Run Proxmox Helper Script 'PVE Post Install' (recommended) ? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    # Proxmox Helper Script - PVE Post Install
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
fi

echo "===================================================================================="
echo "       Proxmoxiac After Install Setup Script"
echo "===================================================================================="

# Helper Function for Prompts
prompt() {
    local var_name="$1" prompt_text="$2" default_val="$3" required="$4" input=""
    while true; do
        read -p "$prompt_text [$default_val]: " input
        input="${input:-$default_val}"
        if [[ -n "$input" || "$required" != "Y" ]]; then
            declare -g "$var_name=$input"
            break
        fi
        echo "Error: This field is required."
    done
}

# Add a line to a file if it doesn't already exist
add_line_if_missing() {
    local file="$1" line="$2"
    [[ ! -f "$file" ]] && mkdir -p "$(dirname "$file")" && touch "$file"   # Ensure the file exists, or create it
    [ -n "$line" ] && grep -Fxq "$line" "$file" || echo "$line" >> "$file" # Append line if not empty
}

# Add a line to crontab and re-load it.
# If you pass a search string (optional), it will delete all crontabs with that string before appending the new one at the bottom.
# If you don't, it will delete all crontabs that match the CRON_JOB exactly
# Usage: add_to_crontab "$CRON_JOB" ["$SEARCH_STRING"]
add_to_crontab() {
    echo "$1" | grep -qE '^(@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)|([-0-9*/,]+ +){4}[-0-9*/,]+) ' || { echo "Error: Invalid cron schedule format. Please try again."; exit 1; }
    (crontab -l 2>/dev/null | grep -Fv "${2:-$1}" || true; echo "$1") | crontab -
}

# Update Proxmox
read -p "Update Proxmox? (Y/n): " -n 1 -r && echo ""
if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    # Upgrade Proxmox
    apt update && apt upgrade -y && apt autoremove -y && apt autoclean -y
fi

# Install Dependencies
apt install -y jq git unzip
export PATH="$PATH:/root/.local/bin"

# Setup Infrastructure-As-Code Repository
echo "===================================================================================="
echo "       Infrastructure-As-Code Repository Setup"
echo "===================================================================================="
# Setup local Infrastructure-As-Code repository (clone if it doesn't exist, or update if it does)
if ! git -C "/root/infrastructure" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    prompt "GITHUB_USERNAME" "What's your Github Username?" "" "Y"
    prompt "IAC_REPO_URL" "Your Personal Proxmoxiac Fork Git Repo URL" "https://github.com/$GITHUB_USERNAME/proxmoxiac.git" "Y"
    if [[ $(curl -I -L -s -o /dev/null -w "%{http_code}" "$IAC_REPO_URL") == "200" ]]; then # check if git repo at $IAC_REPO_URL is public or private
        echo "Infrastructure-As-Code Repo is Public. No Access Token Required.";
    else
        echo "Infrastructure-As-Code Repo is Private. Access Token Required. See https://github.com/settings/personal-access-tokens. If creating a new one, save it in your password manager!";
        while true; do
            read -p "Please enter your Github Personal Access Token: " GITHUB_ACCESS_TOKEN
            if curl -s -H "Authorization: token $GITHUB_ACCESS_TOKEN" -f "https://api.github.com/user" > /dev/null; then
                echo "GitHub Access Token is valid - authentication successful."
                IAC_REPO_URL="https://${GITHUB_ACCESS_TOKEN}@${IAC_REPO_URL#https://}" #Update IAC_REPO_URL to include the GITHUB_ACCESS_TOKEN provided by user.
                break
            else
                echo "ERROR: GitHub Access Token is invalid or expired. Try again."
            fi
        done
    fi
    # Ensure /root/infrastructure is empty
    if [ -d "/root/infrastructure" ]; then
        echo "Warning: /root/infrastructure already exists but is not a valid git repository."
        read -p "Do you want to DELETE it and re-clone? (y/N): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "/root/infrastructure" || { echo "Aborting. Please resolve the directory conflict manually."; exit 1; }
    fi
    mkdir -p "/root/infrastructure"                                               # Ensure the full path exists
    chown -R root:root "/root/infrastructure" && chmod 700 "/root/infrastructure" # Restrict access to root only
    git clone "$IAC_REPO_URL" "/root/infrastructure"                              # Clone repo to local IAC path
else
    echo "Found existing Infrastructure-As-Code repository at '/root/infrastructure'. Checking for updates via git pull..."
    # Git pull the latest infrastructure-as-code from repository
    git -C "/root/infrastructure" pull origin main --rebase --autostash && echo "Git pull successful." || { echo "ERROR: Could not pull latest Infrastructure-As-Code from Git."; exit 1; }
fi

# Load or Create CONFIG_FILE
CONFIG_FILE="/root/infrastructure/snippets/$(hostname)-host-config.sh"                                      # Set the Host Config File Location (within /root/infrastructure)
[[ -f "$CONFIG_FILE" ]] && echo "Loading existing configuration from $CONFIG_FILE" && source "$CONFIG_FILE" # If Host Config File exists, execute it
add_line_if_missing $CONFIG_FILE "#!/bin/bash"                                # If Host Config File doesn't exist, create it, and add a shebang
add_line_if_missing $CONFIG_FILE "GITHUB_USERNAME=\"$GITHUB_USERNAME\""       # Save GITHUB_USERNAME to config file

# Setup Bitwarden Secrets Manager CLI via official install method - installs to /root/.local/bin/bws
curl -Ls https://bws.bitwarden.com/install | sh

# Ensure Bitwarden Secrets Manager Machine Account Token exists and is valid
while true; do
    BWS_ACCESS_TOKEN=$(cat "/etc/pve/priv/bws_access_token" 2>/dev/null || true)
    if /root/.local/bin/bws secret list --access-token "$BWS_ACCESS_TOKEN" --output json >/dev/null 2>&1; then
        echo "Bitwarden Secrets Manager authentication successful."
        break
    else
        echo "ERROR: Failed to authenticate with Bitwarden Secrets Manager. The token might be missing or invalid."
        read -p "Please enter your Bitwarden Secrets Manager Machine Account Access Token from https://vault.bitwarden.com/: " USER_TOKEN
        echo ""
        echo "$USER_TOKEN" > "/etc/pve/priv/bws_access_token"
        chmod 600 "/etc/pve/priv/bws_access_token"
        echo "Retrying..."
        sleep 3
    fi
done

echo "===================================================================================="
echo "       Public SSH Key Setup"
echo "===================================================================================="
read -p "Add your Public SSH Key? (highly recommended) (Y/n): " -n 1 -r && echo ""
if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    # Check for Public SSH Keys at https://github.com/$GITHUB_USERNAME.keys and if they exist, save them to /root/.ssh/authorized_keys
    if [ -n "$GITHUB_USERNAME" ]; then
        while true; do
            echo "Checking for public SSH keys on GitHub for user: $GITHUB_USERNAME"
            GITHUB_KEYS=$(curl -fs "https://github.com/$GITHUB_USERNAME.keys" || true)
            if [ -n "$GITHUB_KEYS" ] && [[ "$GITHUB_KEYS" == ssh-* ]]; then
                while IFS= read -r key; do
                    [ -n "$key" ] && add_line_if_missing "/root/.ssh/authorized_keys" "$key"
                done <<< "$GITHUB_KEYS"
                break
            else
                echo "No public keys found on GitHub for $GITHUB_USERNAME or user does not exist."
                echo "If you don't already have one, generate a new SSH keypair (and save it) with Bitwarden Desktop Client or your software of choice."
                echo "Then, add your key to github via https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account"
                read -p "Would you like to check GitHub again for keys? If not, you'll need to enter it here. (y/N): " -n 1 -r && echo ""
                [[ $REPLY =~ ^[Yy]$ ]] && continue || break
            fi
        done
    fi

    # Ensure a Public SSH Key exists in your authorized_keys file
    while true; do
        SSH_KEY_COUNT=$(grep -c "^ssh-" /root/.ssh/authorized_keys 2>/dev/null || echo 0)
        if [ "$SSH_KEY_COUNT" -gt 1 ]; then # Proxmox installs the first key automatically. Check that a 2nd, custom key exists.
            echo "Public SSH Key Found in /root/.ssh/authorized_keys"
            # Disable Password Authentication via a dedicated config file
            echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/disable_pw.conf && systemctl restart ssh
            break
        else
            echo "ERROR: Public SSH Key not found in /root/.ssh/authorized_keys"
            read -p "Please enter your Public SSH Key (ssh-ed25519 ...). This can be generated in Bitwarden Desktop Client if you don't have one already: " USER_SSH_KEY && echo ""
            # Ensure $USER_SSH_KEY starts with ssh- before adding to authorized keys
            [[ "$USER_SSH_KEY" =~ ^ssh- ]] && add_line_if_missing "/root/.ssh/authorized_keys" "$USER_SSH_KEY" || echo "Invalid SSH key format. It must start with 'ssh-'."
        fi
        sleep 1
    done
fi

echo "===================================================================================="
echo "       Notifications Setup"
echo "===================================================================================="
# Setup Pre-configured Datacenter > Notifications
if [ ${#SMTP_ENDPOINTS[@]} -gt 0 ]; then
    echo "Found ${#SMTP_ENDPOINTS[@]} Pre-configured SMTP Notification endpoints:"
    for SMTP_ENDPOINT in "${SMTP_ENDPOINTS[@]}"; do
        echo $SMTP_ENDPOINT;
        if read -p "Import above Pre-configured SMTP Notification endpoint from config file? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
            read -p "SMTP Password? [your-app-password]: ";          SMTP_PW_VAL="${REPLY:-your-app-password}"
            eval pvesh $SMTP_ENDPOINT --password $(printf %q "$SMTP_PW_VAL") || echo "Warning: Failed to apply notification setting: ${SMTP_ENDPOINT}"
        fi
    done
    echo ""
fi

# Setup New Datacenter > Notifications
if [ -f /etc/pve/notifications.cfg ] && grep -q "^smtp:" /etc/pve/notifications.cfg; then # Check if any notifications exist with type "smtp"
    echo "SMTP Notification endpoint already exists. Skipping SMTP setup."
elif read -p "Setup SMTP Notifications? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    : "${ADMIN_EMAIL:=$(pvesh get /access/users/root@pam --output=json | jq -r 'select(.email != null) .email')}" # Set ADMIN_EMAIL to the root@pam user's email address
    while true; do
        SMTP_ARGS=(create /cluster/notifications/endpoints/smtp --author "Proxmox-$(hostname)")
        read -p "SMTP Server Name? [SMTP-Alerts]: ";             SMTP_ARGS+=(--name "${REPLY:-SMTP-Alerts}")
        read -p "SMTP Server? [smtp.gmail.com]: ";               SMTP_ARGS+=(--server "${REPLY:-smtp.gmail.com}")
        # read -p "SMTP Port? [587]: ";                            SMTP_ARGS+=(--port "${REPLY:-587}") # Removed as it throws an error, and starttls defaults to 587 anyway
        read -p "SMTP Mode? [starttls]: ";                       SMTP_ARGS+=(--mode "${REPLY:-starttls}")
        read -p "SMTP Username? [your-email@gmail.com]: ";       SMTP_ARGS+=(--username "${REPLY:-your-email@gmail.com}")
        read -p "SMTP Password? [your-app-password]: ";          SMTP_PW_VAL="${REPLY:-your-app-password}"
        read -p "SMTP From Address? [from-address@gmail.com]: "; SMTP_ARGS+=(--from-address "${REPLY:-$ADMIN_EMAIL}")
        read -p "SMTP To Address? [$ADMIN_EMAIL]: ";             SMTP_ARGS+=(--mailto "${REPLY:-$ADMIN_EMAIL}")
        if pvesh "${SMTP_ARGS[@]}" --password "$SMTP_PW_VAL" && add_line_if_missing "$CONFIG_FILE" "SMTP_ENDPOINTS+=(\"$(printf "%q " "${SMTP_ARGS[@]}")\")"; then
            echo "Successfully Added SMTP Notifications"
        else
            read -p "Invalid SMTP Notification. Retry? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && continue
        fi
        break
    done
fi

# Set SMTP-Alerts as the default notification endpoint?
if [ -f /etc/pve/notifications.cfg ] && grep -q "^smtp: SMTP-Alerts" /etc/pve/notifications.cfg && ! pvesh get /cluster/notifications/matchers/default-matcher --output-format json 2>/dev/null | jq -e '.target | index("SMTP-Alerts")' >/dev/null; then
    if read -p "Set SMTP-Alerts as the default notification endpoint? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        if pvesh get /cluster/notifications/matchers/default-matcher >/dev/null 2>&1; then
            echo "Updating default-matcher to use SMTP-Alerts..."
            pvesh set /cluster/notifications/matchers/default-matcher --target SMTP-Alerts --comment "Route all notifications to SMTP-Alerts"
        else
            echo "Creating default-matcher for SMTP-Alerts..."
            pvesh create /cluster/notifications/matchers --name default-matcher --target SMTP-Alerts --comment "Route all notifications to SMTP-Alerts"
        fi
    fi
fi

echo "===================================================================================="
echo "       Crontab Setup"
echo "===================================================================================="

# Create cron-hourly file if it doesn't already exist
if [ ! -f "/root/infrastructure/snippets/$(hostname)-cron-hourly.sh" ]; then
cat <<'EOF' > "/root/infrastructure/snippets/$(hostname)-cron-hourly.sh"
#!/bin/bash

# Storage threshold to trigger a notification
THRESHOLD=${1:-90}

# Check storage
OUTPUT=$(/usr/sbin/pvesm status 2>&1 | /usr/bin/grep -Ev "disabled|error" | tr -d '%' | awk -v limit="$THRESHOLD" '$7 >= limit {print $1 " (" $2 ") is at " $7 "%"}')

# Send notification if required
[ -n "$OUTPUT" ] && echo -e "High Storage Usage Detected:\n$OUTPUT" | mail -s "Storage Warning" root

EOF
fi

# Create cron-weekly file if it doesn't already exist
if [ ! -f "/root/infrastructure/snippets/$(hostname)-cron-weekly.sh" ]; then
cat <<'EOF' > "/root/infrastructure/snippets/$(hostname)-cron-weekly.sh"
#!/bin/bash

# Schedule fstrim See: https://gist.github.com/Impact123/3dbd7e0ddaf47c5539708a9cbcaab9e3#discard

# Run fstrim on all running LXC containers
pct list | awk '$2 == "running" {print $1}' | while read ct; do pct fstrim ${ct}; done;

# Run fstrim on all running VMs
qm list | awk '$3 == "running" {print $1}' | while read vm; do qm guest exec ${vm} -- fstrim -av; done;

EOF
fi

# Permanently add "/root/.local/bin" to PATH, but only if it's not already there.
add_line_if_missing "/root/.bashrc" 'export PATH="$PATH:/root/.local/bin"'

# Add PATH to the TOP of crontab (only if it's not already there)
(echo "PATH=$PATH"; crontab -l 2>/dev/null | grep -Fv "PATH=$PATH" || true) | crontab -

# Schedule cron jobs
add_to_crontab "0 * * * * /root/infrastructure/snippets/$(hostname)-cron-hourly.sh"  # Hourly - Every hour, on the hour
echo "Successfully added cron job for /root/infrastructure/snippets/$(hostname)-cron-hourly.sh"
add_to_crontab "30 0 * * 0 /root/infrastructure/snippets/$(hostname)-cron-weekly.sh" # Weekly - Sundays at 12:30am
echo "Successfully added cron job for /root/infrastructure/snippets/$(hostname)-cron-weekly.sh"

# Enable built-in job to run fstrim weekly on Proxmox host too. It should be enabled by default, but it doesn't hurt to double-check.
systemctl enable fstrim.timer

echo "===================================================================================="
echo "       Install Software"
echo "===================================================================================="

# Setup HD-Idle
read -p "Install HD-Idle Tool to auto-spin down hard drives when idle? (Y/n): " -n 1 -r && echo ""
if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    [[ -n "$HDD_IDLE_SECONDS" && ! "$HDD_IDLE_SECONDS" =~ ^[0-9]+$ ]] && echo "Error: '$HDD_IDLE_SECONDS' is not a valid number." && HDD_IDLE_SECONDS=""
    while [[ -z "$HDD_IDLE_SECONDS" ]]; do
        read -r -p "How long should the drives be idle before spinning down? (in seconds) [600]: " HDD_IDLE_SECONDS && HDD_IDLE_SECONDS="${HDD_IDLE_SECONDS:-600}"
        [[ ! "$HDD_IDLE_SECONDS" =~ ^[0-9]+$ ]] && echo "Error: Please enter a valid integer." && HDD_IDLE_SECONDS=""
    done
    add_line_if_missing $CONFIG_FILE "HDD_IDLE_SECONDS=\"$HDD_IDLE_SECONDS\""
    /bin/bash /root/infrastructure/snippets/setup-hd-idle.sh "$HDD_IDLE_SECONDS"
fi

# Setup Tailscale
read -p "Install Tailscale directly on Proxmox Host? (Y/n): " -n 1 -r && echo ""
if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    [[ "${TAILSCALE_ARGS[*]}" != *"--non-interactive"* ]]     && TAILSCALE_ARGS+=("--non-interactive") # Tell the install script to run non-interactively
    [[ "${TAILSCALE_ARGS[*]}" != *"--reset"* ]]               && TAILSCALE_ARGS+=("--reset") # Reset unspecified settings to default values
    [[ "${TAILSCALE_ARGS[*]}" != *"--auto-update"* ]]         && read -p "Enable Automatic Updates? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && TAILSCALE_ARGS+=("--auto-update")
    [[ "${TAILSCALE_ARGS[*]}" != *"--ssh"* ]]                 && read -p "Enable Tailscale SSH? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && TAILSCALE_ARGS+=("--ssh")
    [[ "${TAILSCALE_ARGS[*]}" != *"--advertise-exit-node"* ]] && read -p "Advertise Exit Node? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && TAILSCALE_ARGS+=("--advertise-exit-node")
    if [[ "${TAILSCALE_ARGS[*]}" != *"--advertise-routes"* ]]; then
        read -p "Advertise Routes? (Y/n): " -n 1 -r && echo ""
        if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
            DEFAULT_ROUTE=$(ip route | awk -v d="$(ip route | awk '/^default/ {print $5; exit}')" '$3==d && /scope link/ {print $1; exit}')
            [[ -n "$DEFAULT_ROUTE" ]] && TAILSCALE_ARGS+=("--advertise-routes=$DEFAULT_ROUTE")
        fi
    fi
    [[ "${TAILSCALE_ARGS[*]}" != *"--accept-routes"* ]]       && read -p "Accept Routes? (This is NOT recommended - it can cause routing conflicts with Proxmox) (y/N): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ ]] && TAILSCALE_ARGS+=("--accept-routes")

    # Save TAILSCALE_ARGS to CONFIG_FILE, intentionally leaving out --auth-key
    for TAILSCALE_ARG in "${TAILSCALE_ARGS[@]}"; do add_line_if_missing "$CONFIG_FILE" "TAILSCALE_ARGS+=(\"$TAILSCALE_ARG\")"; done

    [[ "${TAILSCALE_ARGS[*]}" != *"--auth-key"* ]]            && read -p "Do you want to use a Tailscale Auth Key? (y/N): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ ]] && read -p "Enter your Tailscale Auth Key: " TAILSCALE_AUTH_KEY && TAILSCALE_ARGS+=("--auth-key=${TAILSCALE_AUTH_KEY:-}")

    /bin/bash /root/infrastructure/snippets/setup-tailscale.sh "${TAILSCALE_ARGS[@]}"
fi

# DISABLED FOR NOW, as it seems to be preventing drive spindown
# Setup Powertop and AutoASPM for Power Usage Optimization
# read -p "Install Powertop and AutoASPM for Power Usage Optimization? (Y/n): " -n 1 -r && echo ""
# if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
#     /bin/bash /root/infrastructure/snippets/setup-powertop-autoaspm.sh
# fi

echo "===================================================================================="
echo "       ZFS Setup"
echo "===================================================================================="
# ZFS - Find and Import all unimported pools
mapfile -t pools < <(zpool import | awk '/pool:/ {print $2}') # Extract unimported pool names into array
if [ ${#pools[@]} -gt 0 ]; then
    echo "Found ${#pools[@]} unimported ZFS pools: ${pools[*]}"
    read -p "Do you want to import them? (Y/n): " -n 1 -r && echo ""
    if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        for p in "${pools[@]}"; do echo "Importing $p..."; zpool import -f "$p"; done # Force import each pool
    fi
fi

# Loop through all imported zpools
mapfile -t pools < <(zpool list -H -o name)
for p in "${pools[@]}"; do
    # Offer to disable sync if sync is currently enabled
    if [[ "$(zfs get -H -o value sync "$p")" == "enabled" ]]; then
        read -p "Sync is currently enabled on ZFS Pool '$p'. For consumer SSDs, it's recommended to disable it to improve performance and drastically reduce premature wear. Proceed? (Y/n): " -n 1 -r && echo ""
        [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && zfs set sync=disabled $p
    fi

    # Offer to disable atime (Access Time) to allow disks to spin down
    if [[ "$(zfs get -H -o value atime "$p")" == "on" ]]; then
        read -p "Atime is currently enabled on ZFS Pool '$p'. Disabling it is recommended for performance and to allow HDDs to spin down. Proceed? (Y/n): " -n 1 -r && echo ""
        [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && zfs set atime=off $p
    fi

    # Offer to upgrade pool if it's eligible for an upgrade
    [ "$p" == "rpool" ] && continue # Skip rpool (typical boot pool name) to avoid incompatibility (the bootloader may not support new ZFS features yet)
    zpool upgrade | grep -w "$p" >/dev/null || continue # Skip this zpool if no upgrades are available
    read -p "ZFS Pool '$p' has an upgrade available. Upgrade to latest features? This is irreversible. (Y/n): " -n 1 -r && echo ""
    [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && zpool upgrade "$p"
done

# ZFS - Ensure everything is mounted
zfs mount -a

echo "ZFS import and upgrade process complete."

echo "===================================================================================="
echo "       Storage Setup"
echo "===================================================================================="
# OPTIONALLY Drop local-lvm and reallocate space to the root partition
if pvesm status | grep -q "local-lvm"; then
    read -p "Delete local-lvm partition and reallocate the space to the root partition? Please be extra sure you don't have anything important there. (Y/n): " -n 1 -r && echo ""
    if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        pvesm remove local-lvm              # Remove the configuration entry for local-lvm  # Or do it manually via: Datacenter > Storage > local-lvm > Click Remove
        lvremove -y /dev/pve/data           # Deletes the Logical Volume named data (partition that backs local-lvm) inside the pve Volume Group.
        lvresize -l +100%FREE /dev/pve/root # Resize root Logical Volume to use all the newly freed up space.
        resize2fs /dev/mapper/pve-root      # Resizes the actual file system (ext4) to match the new volume size. (No reboot needed)
    fi
fi

# Add Proxmox storage "infrastructure" for Infrastructure-As-Code Repository
pvesm status | grep -q "infrastructure" || pvesm add dir infrastructure --path "/root/infrastructure" --content snippets

# Add Pre-configured Proxmox storage from config file
[ ${#PVESM[@]} -gt 0 ] && for PVESM_ARGS in "${PVESM[@]}"; do
    STORAGE_NAME=$(echo "$PVESM_ARGS" | awk '{print $3}')
    if pvesm status | grep -q "$STORAGE_NAME"; then
        echo "Found Pre-configured Proxmox Storage '$STORAGE_NAME', but it already exists. Skipping..."
    else
        read -p "Found Pre-configured Proxmox Storage '$STORAGE_NAME'. Do you want to re-create it? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && eval pvesm $PVESM_ARGS
    fi
done

# Add New Proxmox storage
while true; do
    echo -e "\nCurrently available Proxmox storage (Datacenter > Storage):"
    pvesm status
    read -p "Add an additional Proxmox storage? (Y/n): " -n 1 -r && echo ""
    if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
        PVESM_ARGS=(add)
        read -p "Storage Type? [zfspool] Options: (btrfs | cephfs | cifs | dir | esxi | iscsi | iscsidirect | lvm | lvmthin | nfs | pbs | rbd | zfs | zfspool): "; PVESM_ARGS+=("${REPLY:-zfspool}")
        read -p "Storage ID (Name)? [flash]: ";                       PVESM_ARGS+=("${REPLY:-flash}")
        read -p "ZFS Pool? [flash]: ";                                PVESM_ARGS+=(--pool "${REPLY:-flash}")
        read -p "Content Types, comma separated? [images,rootdir]: "; PVESM_ARGS+=(--content "${REPLY:-images,rootdir}")
        read -p "Thin Provisioning? [1]: ";                           PVESM_ARGS+=(--sparse "${REPLY:-1}")
        read -p "Storage Blocksize? [16k]: ";                         PVESM_ARGS+=(--blocksize "${REPLY:-16k}")
        pvesm "${PVESM_ARGS[@]}" && add_line_if_missing "$CONFIG_FILE" "PVESM+=(\"$(printf "%q " "${PVESM_ARGS[@]}")\")" && echo "Successfully added Proxmox storage." || echo "Syntax entered was invalid. Could not save as Proxmox storage."
        continue
    fi
    break
done

echo "===================================================================================="
echo "       FSTAB Setup"
echo "===================================================================================="
read -p "Setup FSTAB mounts? (mergerfs will be auto-installed if required) (Y/n): " -n 1 -r && echo ""
if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
    # Create a backup of fstab
    cp "/etc/fstab" "/etc/fstab.bak.$(date +%F_%T)" && echo "Backup created at /etc/fstab.bak.$(date +%F_%T)"

    # Use the latest version from "/root/infrastructure/snippets/$(hostname)-fstab"
    [ -f "/root/infrastructure/snippets/$(hostname)-fstab" ] && cp "/root/infrastructure/snippets/$(hostname)-fstab" "/etc/fstab"

    # add proxmoxiac sample lines if they're not already in the file
    if ! grep -q "proxmoxiac" /etc/fstab; then
cat <<EOF >> "/etc/fstab"
# =================================================================================================
# proxmoxiac
# Uncomment/add/modify the below lines as needed. Then, ctrl-x, y, and [Enter] to save and exit.
# =================================================================================================
# /flash/storage                               /mnt/flash   fuse.mergerfs defaults,nonempty,allow_other,use_ino,cache.files=off,moveonenospc=true,dropcacheonclose=true,minfreespace=10G,fsname=mergerfs,category.create=ff 0 0
# /tank/storage:/tank2/storage                 /mnt/tank    fuse.mergerfs defaults,nonempty,allow_other,use_ino,cache.files=off,moveonenospc=true,dropcacheonclose=true,minfreespace=10G,fsname=mergerfs,category.create=ff 0 0
# /flash/storage:/tank1/storage:/tank2/storage /mnt/storage fuse.mergerfs defaults,nonempty,allow_other,use_ino,cache.files=off,moveonenospc=true,dropcacheonclose=true,minfreespace=10G,fsname=mergerfs,category.create=ff 0 0
EOF
    fi
    
    # Open fstab in a text editor and ensure it's valid.
    while true; do
        ${EDITOR:-nano} /etc/fstab                                                  # Open fstab in default editor or nano
        echo "Checking FSTAB mounts for valid syntax..."
        grep -q " fuse.mergerfs " /etc/fstab && apt install -y mergerfs             # Install mergerfs if used in fstab
        mapfile -t FSTAB_ENTRIES < <(grep -vE "^#|^$|/dev|/proc" /etc/fstab)
        for FSTAB_ENTRY in "${FSTAB_ENTRIES[@]}"; do
            MOUNTPOINT=$(echo "$FSTAB_ENTRY" | awk '{print $2}')
            [ -n "$MOUNTPOINT" ] && mkdir -p "$MOUNTPOINT"                          # Ensure each of the mountpoint directories listed in FSTAB actually exist
        done
        systemctl daemon-reload                                                     # Sync systemd with the modified fstab
        if mount -a; then break; fi                                                 # Reload the new fstab entries - Automatically break the loop if mount is successful
        read -p "Errors found. Press any key to try again..." -n 1 -r -s && echo "" # Pause to let user read errors before reopening editor
    done

    # Update infrastructure-as-code copy of fstab
    cp "/etc/fstab" "/root/infrastructure/snippets/$(hostname)-fstab" && echo "Backup created at /root/infrastructure/snippets/$(hostname)-fstab"

    mount -a # (or just reboot)
    # df -h #verify the mount points
fi

echo "===================================================================================="
echo "       Non-Root User and Group Permissions Setup"
echo "===================================================================================="
# LXC User Setup - Creates UID 100000 (the same UID as LXC Container Root) to minimize risk of LXC mountpoint permission issues
CURRENT_USER_100000=$(getent passwd 100000 | cut -d: -f1)
if [ -n "$CURRENT_USER_100000" ]; then
    echo "User ID 100000 already exists with name: $CURRENT_USER_100000"
    prompt "NON_ROOT_USER_NAME" "Enter a new name to rename this user (or press enter to keep current)" "$CURRENT_USER_100000" "Y"
    if [ "$NON_ROOT_USER_NAME" != "$CURRENT_USER_100000" ]; then
        usermod -l "$NON_ROOT_USER_NAME" "$CURRENT_USER_100000"
        # groupmod -n "$NON_ROOT_USER_NAME" "$CURRENT_USER_100000" # disabled because it may not exist
        echo "User renamed to $NON_ROOT_USER_NAME"
    fi
else
    prompt "NON_ROOT_USER_NAME" "Enter name for new User ID 100000 (will own LXC shares)" "lxcuser" "Y"
    useradd -u 100000 -U -m -s /bin/bash "$NON_ROOT_USER_NAME"
    echo "User $NON_ROOT_USER_NAME created with UID 100000"
fi

# LXC Group Setup - Creates GID 10000 (the same GID as LXC Container Root) to minimize risk of LXC mountpoint permission issues
CURRENT_GROUP_10000=$(getent group 10000 | cut -d: -f1)
if [ -n "$CURRENT_GROUP_10000" ]; then
    echo "Group ID 10000 already exists with name: $CURRENT_GROUP_10000"
    prompt "NON_ROOT_GROUP_NAME" "Enter a new name to rename this group (or press enter to keep current)" "$CURRENT_GROUP_10000" "Y"
    if [ "$NON_ROOT_GROUP_NAME" != "$CURRENT_GROUP_10000" ]; then
        groupmod -n "$NON_ROOT_GROUP_NAME" "$CURRENT_GROUP_10000"
        echo "Group renamed to $NON_ROOT_GROUP_NAME"
    fi
else
    prompt "NON_ROOT_GROUP_NAME" "Enter name for new Group ID 10000 (will own LXC shares)" "lxcgroup" "Y"
    groupadd -g 10000 "$NON_ROOT_GROUP_NAME"
    echo "Group $NON_ROOT_GROUP_NAME created with GID 10000"
fi

# Recursively update owner, group, and permissions for fstab entries
mapfile -t FSTAB_ENTRIES < <(grep -vE "^#|^$|/dev|/proc" /etc/fstab)
for FSTAB_ENTRY in "${FSTAB_ENTRIES[@]}"; do
    MOUNTPOINT=$(echo "$FSTAB_ENTRY" | awk '{print $2}')
    if [ -n "$MOUNTPOINT" ]; then
        mkdir -p "$MOUNTPOINT"
        read -p "Recursively update Owner, Group, and Permissions for $MOUNTPOINT to $NON_ROOT_USER_NAME:$NON_ROOT_GROUP_NAME (with 2755; SetGID bit 2 + rwxrwxr-x)? (Y/n): " -n 1 -r && echo ""
        if [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]]; then
            chown -R $NON_ROOT_USER_NAME:$NON_ROOT_GROUP_NAME "$MOUNTPOINT" # LXC's root user sees the files as owned by root (because 100000 on host = 0 in container) and can write without permission errors
            chmod -R 2775 "$MOUNTPOINT" # Sets permissions to rwxrwxr-x with the SetGID bit 2. Any new file or folder created in this dir will inherit the GID of the parent folder (10000) instead of the primary group of the user who created it.
        fi
    fi
done

echo "===================================================================================="
echo "       Commit changes to Git"
echo "===================================================================================="
# Commit changes to git
if [ -d "/root/infrastructure/.git" ]; then
    echo "Committing configuration changes to Git..."
    git -C "/root/infrastructure" add .
    git -C "/root/infrastructure" commit -m "Post-install update for $(hostname) on $(date +%F)" || echo "No changes to commit."
    git -C "/root/infrastructure" push origin main || echo "Warning: Could not push changes to remote repository."
fi

echo "===================================================================================="
echo "       Congrats, you're all set!"
echo "===================================================================================="