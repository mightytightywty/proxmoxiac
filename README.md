# Proxmoxiac

**Infrastructure-As-Code (IaC) for Proxmox VE**

Proxmoxiac is a comprehensive suite of scripts designed to automate the post-installation setup, configuration, and ongoing management of Proxmox VE nodes. It embraces GitOps principles, allowing you to manage your infrastructure configuration via a Git repository.

## 🚀 Features

*   **Automated Post-Install Setup**: Updates Proxmox, installs dependencies, and configures system settings in one go.
*   **Git-Based Configuration**: Your host configuration is stored in a Git repository (`/root/infrastructure`), allowing for version control and easy restoration.
*   **Docker in LXC Automation**:
    *   Creates optimized LXC templates (Alpine/Debian/Ubuntu) pre-installed with Docker.
    *   **GitOps for Docker Stacks**: Automatically syncs Docker Compose files from your repo to your LXC containers on startup via a hookscript.
    *   **Bitwarden Secrets Manager Integration**: Injects secrets directly into your Docker containers at runtime.
*   **Storage Management**:
    *   Automated ZFS pool importing and upgrading.
    *   MergerFS setup for pooling drives.
    *   HD-Idle configuration for power saving.
    *   Helper scripts to mount ZFS datasets or host directories into LXCs.
*   **Networking**:
    *   Automated Tailscale installation (Exit Node, Subnet Router, SSH).
    *   SSH Key management (syncs from GitHub).
*   **Notifications**: Configures SMTP notifications for Proxmox alerts.

## 📋 Prerequisites

1.  **Proxmox VE**: A clean install of Proxmox VE (Non-ZFS boot disk recommended if you plan to pass through drives, but works with ZFS too).
2.  **GitHub Account**: You need to fork this repository to store your own configuration.
3.  **Bitwarden Secrets Manager (Optional, but recommended)**: For automated secret injection into containers.
4.  **ZFS Storage (Optional, but recommended)**
    *   **Ideal Setup**:
        *   Do NOT use ZFS for your boot disk. Use EXT4 instead for optimal performance.
        *   Create a ZFS pool of SSDs called "flash" (can be multiple SSDs if you like).
        *   Create single drive ZFS pools called "tank1", "tank2", etc. for each of your spinning HDDs.
        *   For each of your ZFS pools, create a dataset called "\<poolname\>/storage"

## 🛠️ Getting Started

### 1. Fork the Repository
Fork this repository into your own GitHub account. This will be your personal "Source of Truth" for your own infrastructure, and will be updated as you make changes. Be sure to mark it as private!

### 2. Install Proxmox
Perform a standard installation of Proxmox VE.

### 3. Run the Bootstrap Script
Access your Proxmox host shell (via SSH or Console) and run the following command.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mightytightywty/proxmoxiac/main/snippets/proxmox-after-install.sh)"
```

### 4. Follow the Prompts
The script will guide you through:
*   Linking your Git repository.
*   Setting up SSH keys.
*   Configuring storage (ZFS, MergerFS).
*   Installing optional tools (Tailscale, Powertop, HD-Idle).
*   Configuring notifications.

## 📂 Script Reference

### `proxmox-after-install.sh`
The main entry point. It bootstraps the system, sets up the `/root/infrastructure` directory to hold all of your Infrastructure-As-Code (IaC) files, and configures the host. It creates a host-specific config file (e.g., `hostname-host-config.sh`) to persist your choices, in case you ever want to re-run it.

### `lxc-create-template.sh`
Creates a reusable LXC template optimized for running Docker.
*   **Features**: Installs Docker, sets up ID mapping (Unprivileged container mapping to host groups), and configures ZVol storage for Docker images.
*   **Usage**:
    ```bash
    ./lxc-create-template.sh [OPTIONS]

    Required:
    --hostname <name>            Hostname (default: alpine-docker-template)

    Options:
    --vmid <id>                  Template LXC ID (default: next available >= 9000)
                                    If it exists, it will delete all clones, and rebuild everything from scratch.
    --rootfs <spec>              Root filesystem spec (default: volume=flash:10)
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
    --storage <id>               Target Proxmox Storage ID (default: flash) <flash | local>
    --password <pwd>             Root password. If not defined (recommended), root account is locked from login via SSH, etc.
    --map_host_tun <0|1>         Grants the container read and write permissions for the host TUN character device. Useful for VPNs, Tailscale, etc. (default: 0)
    --zvol_for_docker <path>     ZVol for Docker (default: flash/basevol-<vmid>-docker)
                                    Will be formatted in ext4, to be used for /var/lib/docker within each LXC
    --zvol_for_docker_size <sz>  ZVol size (default: 50G)
                                    Will hold all docker images, volumes, etc. Can be resized later if required.
    --help, -h                   Show this help message
    ```

### `lxc-create-clone.sh`
Creates a reusable LXC template optimized for running Docker.
*   **Features**:
    * Clones a previously created Docker-optimized LXC template into a functional container.
    * Rapidly deploys new services by cloning the base template, assigning unique IDs/MACs, and preparing the container for GitOps-driven Docker management.

*   **Usage**:
    ```bash
    ./lxc-create-clone.sh --hostname <hostname> [OPTIONS]

    Required:
        --hostname <name>   Hostname for the new LXC container

    Optional:
        --vmid <id>         Template LXC ID to clone from (default: 9000)
        --newid <id>        New LXC ID (default: next available >= 1000)
        --mac <address>     MAC address for the new container (default: random)
        --zpool <id>        zpol to store the disks on (default: flash)
        --help, -h          Show this help message
    ```

### `lxc-hookscript-docker.sh`
The "Magic" script. When attached to an LXC container, it automatically runs on `post-start` and `pre-stop`.
1.  Pulls the latest code from your Infrastructure repo.
2.  Fetches secrets from Bitwarden Secrets Manager.
3.  Syncs Docker Compose files from `/root/infrastructure/docker/<service_name>` to the container.
4.  Runs `docker compose up -d`.

### `lxc-create-mountpoint.sh`
Helper to easily add storage to your LXC containers.
*   **Usage**:
    ```bash
    ./lxc-create-mountpoint.sh --vmid <id> --hostpath <path> --lxcpath <path> [OPTIONS]

    Required:
    --vmid <id>            LXC ID to add the service to
    --hostpath <path>      Path on Host or ZFS dataset name (examples below)
                                /mnt/storage
                                flash/appdata-service-name
    --lxcpath <path>       Path on LXC (examples below)
                                /mnt/storage
                                /opt/docker/service-name

    Optional:
    --backup <1 | 0>       Set the backup flag
                                defaults to 1 for ZFS Datasets or 0 for standard paths
    --help, -h             Show this help message
    ```

### `setup-tailscale.sh`
Installs and configures Tailscale. It handles all standard tailscale flags like `--advertise-routes` and automatically applies `ethtool` optimizations for subnet routers. Feel free to run this on your LXCs or VMs as well.
*   **Usage**:
    ```bash
    ./setup-tailscale.sh --reset --ssh --advertise-exit-node --advertise-routes=192.168.1.0/24 --auth-key=your-tskey-would-go-here
    ```
*   **Notes**:
    * Additional [FLAGS] available for this script only: --non-interactive (will not ask for additional options)
    * Will automatically add your current subnet to --advertise-routes if added via prompt. You must do it yourself in --non-interactive mode.
    * Will automatically add IP Forwarding and ethtool performance enhancements if --advertise-routes is enabled, even in --non-interactive mode.
    * Will normal Tailscale arguments work as expected.
    * It's safe to re-run this script, but it will automatically reset unspecified settings to default values, unless you are in --non-interactive mode.

### `setup-hd-idle.sh`
Automates the installation and configuration of `hd-idle` to spin down mechanical hard drives to save power.
*   **Features**: Detects rotational drives via `smartctl`, installs `hd-idle`, and configures the idle timeout.
*   **Usage**:
    ```bash
    ./setup-hd-idle.sh [seconds]
    ```

### `setup-powertop-autoaspm.sh`
Optimizes power consumption on the Proxmox host.
*   **Features**: Installs `powertop` and configures `AutoASPM` (Active State Power Management) to reduce energy usage, particularly useful for home labs.
*   **Usage**:
    ```bash
    ./setup-hd-idle.sh [seconds]
    ```

### Generated Scripts
*   **`hostname-host-config.sh`**: Stores the configuration variables selected during the installation process.
*   Cron Scripts - Feel free to add whatever you like to these scripts.
    *   **`hostname-cron-hourly.sh`**: Checks storage usage and sends email alerts if usage > 90%.
    *   **`hostname-cron-weekly.sh`**: Runs `fstrim` on the host, all LXCs, and all VMs to reclaim unused space.

## 🔐 Secrets Management
This project integrates with **Bitwarden Secrets Manager**.
*   **Host Setup**: The installer sets up the BWS CLI.
*   **Container Setup**: The hookscript uses a machine token (stored in `/etc/pve/priv/bws_access_token`) to fetch secrets at runtime and inject them as environment variables into your Docker Compose stacks.

## 🤝 Contributing
Feel free to submit Pull Requests or open Issues to improve the scripts!