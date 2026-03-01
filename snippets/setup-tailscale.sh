#!/bin/bash
set -e # Exit on Error

# Ensure the script is run as root
[ "$EUID" -ne 0 ] && echo "Please run as root (sudo)." && exit 1

##############################################################################
# INSTALL & CONFIGURE TAILSCALE (tested on Debian and Alpine)
# Usage: setup-tailscale.sh --reset --auto-update --ssh --advertise-exit-node --advertise-routes=192.168.1.0/24 --auth-key=your-tskey-would-go-here
# Additional [FLAGS] available for this script only: --non-interactive (will not ask for additional options)
# Will automatically add your current subnet to --advertise-routes if added via prompt. You must do it yourself in --non-interactive mode.
# Will automatically add IP Forwarding and ethtool performance enhancements if --advertise-routes is enabled, even in --non-interactive mode.
# All normal Tailscale arguments work as expected.
# It's safe to re-run this script, but it will automatically reset unspecified settings to default values, unless you are in --non-interactive mode.
##############################################################################

# Add a line to a file if it doesn't already exist
add_line_if_missing() {
    local file="$1" line="$2"
    [[ ! -f "$file" ]] && mkdir -p "$(dirname "$file")" && touch "$file"   # Ensure the file exists, or create it
    [ -n "$line" ] && grep -Fxq "$line" "$file" || echo "$line" >> "$file" # Append line if not empty
}

# Install Tailscale
if ! command -v tailscale &> /dev/null; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "Tailscale already installed."
fi

TAILSCALE_ARGS=("$@") # Pass all script arguments to Tailscale
if [[ "${TAILSCALE_ARGS[*]}" != *"--non-interactive"* ]]; then
    [[ "${TAILSCALE_ARGS[*]}" != *"--reset"* ]]               && TAILSCALE_ARGS+=("--reset") # Reset unspecified settings to default values
    [[ "${TAILSCALE_ARGS[*]}" != *"--auto-update"* ]]         && [ ! -f "/etc/alpine-release" ] && read -p "Enable Automatic Updates? (Y/n): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ || -z $REPLY ]] && TAILSCALE_ARGS+=("--auto-update")
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
    [[ "${TAILSCALE_ARGS[*]}" != *"--auth-key"* ]]            && read -p "Do you want to use a Tailscale Auth Key? (y/N): " -n 1 -r && echo "" && [[ $REPLY =~ ^[Yy]$ ]] && read -p "Enter your Tailscale Auth Key: " TAILSCALE_AUTH_KEY && TAILSCALE_ARGS+=("--auth-key=${TAILSCALE_AUTH_KEY:-}")
fi

# If --advertise-routes (Subnet Router Mode) is included in TAILSCALE_ARGS, additional steps are required
if [[ "${TAILSCALE_ARGS[*]}" == *"--advertise-routes"* ]]; then
    # IP forwarding is required to use a Linux device as a subnet router
    # See https://tailscale.com/docs/features/subnet-routers
    echo "Enabling IP Forwarding for Tailscale Subnet Router..."
    CONF_FILE="/etc/sysctl.d/99-tailscale.conf"
    [ ! -f "$CONF_FILE" ] && CONF_FILE="/etc/sysctl.conf"
    add_line_if_missing "$CONF_FILE" 'net.ipv4.ip_forward = 1'
    add_line_if_missing "$CONF_FILE" 'net.ipv6.conf.all.forwarding = 1'

    sysctl -p "$CONF_FILE" #apply ip forwarding settings immediately, without requiring a reboot

    # Improve Performance for Tailscale Subnet Routers
    # See https://tailscale.com/kb/1320/performance-best-practices#linux-optimizations-for-subnet-routers-and-exit-nodes
    if command -v apt &> /dev/null; then
        apt update && apt install -y ethtool
    elif command -v apk &> /dev/null; then
        apk add ethtool
    fi

    # Run ethtool optimization once (for this session)
    ETHTOOL_IFACE=$(ip -o route get 8.8.8.8 | awk '{print $5}')
    ethtool -K "$ETHTOOL_IFACE" rx-udp-gro-forwarding on rx-gro-list off

    # Restart Tailscale for it to take effect
    command -v systemctl &> /dev/null && systemctl restart tailscaled || rc-service tailscale restart

    # Check systemctl is-enabled networkd-dispatcher
    if command -v systemctl &> /dev/null && systemctl is-enabled networkd-dispatcher &> /dev/null; then
        # networkd-dispatcher is enabled on this machine. Use it to run ethtool on every boot
        printf '#!/bin/sh\n\nethtool -K %s rx-udp-gro-forwarding on rx-gro-list off \n' "$(ip -o route get 8.8.8.8 | awk '{print $5}')" > /etc/networkd-dispatcher/routable.d/50-tailscale
        chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale
    else
        # networkd-dispatcher is not enabled - use crontab to run ethtool on every boot
        CRON_JOB="@reboot $(command -v ethtool) -K $ETHTOOL_IFACE rx-udp-gro-forwarding on rx-gro-list off"
        SEARCH_KEY="rx-udp-gro-forwarding"                       # A unique string to search for to prevent duplicates
        # Remove any existing occurrences of the job and append the new one
        (crontab -l 2>/dev/null | grep -v "$SEARCH_KEY" || true; echo "$CRON_JOB") | crontab -
        echo "Success! Updated ethtool command in root crontab."
        echo "Current crontab configuration:"
        echo "------------------------------"
        crontab -l
    fi
    # Run this after rebooting the server to verify it worked. It should return: rx-udp-gro-forwarding: on
    # ethtool -k vmbr0 | grep udp-gro-forwarding
fi

# Create final argument array, excluding --non-interactive (if present)
for arg in "${TAILSCALE_ARGS[@]}"; do
    [[ "$arg" != "--non-interactive" ]] && TAILSCALE_FINAL_ARGS+=("$arg")
done

# Configure and bring up Tailscale
tailscale up "${TAILSCALE_FINAL_ARGS[@]}"

# Output current tailscale configs
tailscale status
tailscale debug prefs
