#!/bin/sh

# Exit on any error
set -e

# === 1. Read Environment Variables ===
echo "Reading configuration from environment variables..."

# Mandatory variables
if [ -z "$EVE_VERSIONS" ]; then
    echo "Error: EVE_VERSIONS is a required environment variable. e.g. EVE_VERSIONS=\"14.5.1-lts,13.10.0\""
    exit 1
fi
if [ -z "$SERVER_IP" ]; then
    echo "Error: SERVER_IP is a required environment variable."
    exit 1
fi

# Optional variables with defaults
BOOT_MENU_TIMEOUT=${BOOT_MENU_TIMEOUT:="15"}
LOG_LEVEL=${LOG_LEVEL:="info"}
DHCP_MODE=${DHCP_MODE:="proxy"}
# ... (rest of DHCP variables)

# === 2. Setup Caching and Asset Directories ===
echo "Setting up asset and cache directories..."
mkdir -p /data/httpboot /data/downloads /tftpboot

# Convert comma-separated string to list for the loop
IFS=','

for version in $EVE_VERSIONS; do
    echo "---"
    if [ ! -d "/data/httpboot/${version}" ]; then
        echo "Version ${version} not found in cache. Downloading..."
        EVE_TAR_URL="https://github.com/lf-edge/eve/releases/download/${version}/amd64.kvm.generic.installer-net.tar"
        curl -L -o "/data/downloads/netboot-${version}.tar" "${EVE_TAR_URL}"
        
        echo "Extracting assets for version ${version}..."
        mkdir -p "/data/httpboot/${version}"
        tar -xvf "/data/downloads/netboot-${version}.tar" -C "/data/httpboot/${version}"
        rm "/data/downloads/netboot-${version}.tar"
    else
        echo "Version ${version} found in cache. Skipping download."
    fi
    # Always copy the bootloader for the first/default version
    if [ -z "$DEFAULT_VERSION" ]; then
        DEFAULT_VERSION=$version
        echo "Copying iPXE bootloader from default version ${DEFAULT_VERSION}..."
        cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
    fi
done
echo "---"

# === 3. Generate dnsmasq.conf ===
# ... (dnsmasq config generation remains the same as the last working version) ...

# === 4. Generate Root iPXE Menu Script ===
echo "Generating iPXE boot menu..."

# Start the script
cat > /tftpboot/boot.ipxe <<- EOF
#!ipxe

menu EVE-OS Version Selection

EOF

# Add menu items
item_num=1
for version in $EVE_VERSIONS; do
    echo "item --gap ${version} --- EVE-OS ${version} ---" >> /tftpboot/boot.ipxe
    echo "item eve_${item_num} Install EVE-OS ${version}" >> /tftpboot/boot.ipxe
    item_num=$((item_num+1))
done

# Add static menu items
cat >> /tftpboot/boot.ipxe <<- EOF

item --gap -- ------------------------------------------
item shell Drop to iPXE shell
item reboot Reboot computer

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected

goto 
EOF

# Add boot logic for each menu item
item_num=1
for version in $EVE_VERSIONS; do
    echo ":eve_${item_num}" >> /tftpboot/boot.ipxe
    echo "set version ${version}" >> /tftpboot/boot.ipxe
    echo "chain http://${SERVER_IP}/
EOF

# === 5. Start Services ===
# ... (start nginx and dnsmasq) ...
