#!/bin/sh
# Exit on any error
set -e

# Function to validate required environment variables
validate_environment() {
    if [ -z "$EVE_VERSIONS" ]; then
        echo "Error: EVE_VERSIONS is required. Example: EVE_VERSIONS=\"14.5.1-lts,13.10.0\""
        exit 1
    fi
    if [ -z "$SERVER_IP" ]; then
        echo "Error: SERVER_IP is required."
        exit 1
    fi
    if [ -z "$LISTEN_INTERFACE" ]; then
        echo "Error: LISTEN_INTERFACE is required (e.g. eth0)."
        exit 1
    fi

    # Set defaults for optional variables
    BOOT_MENU_TIMEOUT=${BOOT_MENU_TIMEOUT:="15"}
    LOG_LEVEL=${LOG_LEVEL:="info"}
    DHCP_MODE=${DHCP_MODE:="proxy"}
    DHCP_SUBNET_MASK=${DHCP_SUBNET_MASK:="255.255.255.0"}

    echo "iPXE Server IP: ${SERVER_IP}"
    echo "Interface: ${LISTEN_INTERFACE}"
    echo "DHCP Mode: ${DHCP_MODE}"
}

# Function to generate dnsmasq configuration
generate_dnsmasq_conf() {
    echo "Generating dnsmasq configuration..."

    # Create initial TFTP configuration that chains to HTTP
    cat > /tftpboot/ipxe.efi.cfg <<EOL
#!ipxe
dhcp
chain --autofree http://${SERVER_IP}/boot.ipxe || shell
EOL

    # Base configuration
    cat > /etc/dnsmasq.conf <<EOL
# Base Configuration
port=0
interface=${LISTEN_INTERFACE}
bind-interfaces
log-dhcp

# TFTP Configuration
enable-tftp
tftp-root=/tftpboot

# Client Detection
dhcp-match=set:ipxe,175
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9

# Non-iPXE UEFI clients get iPXE binary
dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi,,${SERVER_IP}
pxe-service=tag:efi64,X86-64_EFI,"EVE-OS Network Boot",ipxe.efi

# iPXE gets TFTP config that chains to HTTP
dhcp-boot=tag:ipxe,ipxe.efi.cfg,,${SERVER_IP}

# Force TFTP Server
dhcp-option=66,${SERVER_IP}
EOL

    # DHCP Mode-specific configuration
    if [ "$DHCP_MODE" = "standalone" ]; then
        if [ -z "$DHCP_RANGE_START" ] || [ -z "$DHCP_RANGE_END" ] || [ -z "$DHCP_ROUTER" ]; then
            echo "Error: standalone mode requires DHCP_RANGE_START, DHCP_RANGE_END, and DHCP_ROUTER"
            exit 1
        fi
        cat >> /etc/dnsmasq.conf <<EOL

# Standalone DHCP Configuration
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_SUBNET_MASK},12h
dhcp-option=option:router,${DHCP_ROUTER}
EOL
    else
        # Proxy DHCP mode
        NETWORK_ADDRESS=$(echo ${SERVER_IP} | awk -F. '{print $1"."$2"."$3".0"}')
        cat >> /etc/dnsmasq.conf <<EOL

# Proxy DHCP Configuration
dhcp-range=${NETWORK_ADDRESS},proxy,${DHCP_SUBNET_MASK}
EOL
    fi

    # Optional DHCP parameters
    [ -n "$DHCP_DOMAIN_NAME" ] && echo "dhcp-option=15,${DHCP_DOMAIN_NAME}" >> /etc/dnsmasq.conf
    [ -n "$DHCP_BROADCAST_ADDRESS" ] && echo "dhcp-option=28,${DHCP_BROADCAST_ADDRESS}" >> /etc/dnsmasq.conf

    # Debug logging if requested
    [ "$LOG_LEVEL" = "debug" ] && echo -e "\n# Debug Logging\nlog-queries\nlog-dhcp" >> /etc/dnsmasq.conf

    echo "dnsmasq configuration generated successfully"
}

# Function to set up directory structure and permissions
setup_directories() {
    echo "Setting up directory structure and permissions..."
    
    # Create required directories with proper permissions
    mkdir -p /data/httpboot /data/downloads /tftpboot
    
    # Set ownership and permissions for directories
    chown -R www-data:www-data /data/httpboot
    chmod 755 /data/httpboot
    
    chown -R dnsmasq:dnsmasq /tftpboot
    chmod 755 /tftpboot
    
    chown -R www-data:www-data /data/downloads
    chmod 755 /data/downloads
}

# Function to set up EVE-OS versions
setup_eve_versions() {
    echo "Setting up EVE-OS versions..."
    
    # Ensure directories exist
    setup_directories

    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo "\nProcessing EVE-OS version: ${version}"
        if [ ! -d "/data/httpboot/${version}" ]; then
            echo "Downloading version ${version}..."
            EVE_TAR_URL="https://github.com/lf-edge/eve/releases/download/${version}/amd64.kvm.generic.installer-net.tar"
            curl -L -o "/data/downloads/netboot-${version}.tar" "${EVE_TAR_URL}"

            echo "Extracting assets..."
            mkdir -p "/data/httpboot/${version}"
            tar -xf "/data/downloads/netboot-${version}.tar" -C "/data/httpboot/${version}/"
            rm "/data/downloads/netboot-${version}.tar"
            
            # Set proper permissions for extracted files
            chown -R www-data:www-data "/data/httpboot/${version}"
            find "/data/httpboot/${version}" -type f -exec chmod 644 {} \;
            find "/data/httpboot/${version}" -type d -exec chmod 755 {} \;
        else
            echo "Version ${version} found in cache"
        fi

        # Set up first version as default
        if [ -z "$DEFAULT_VERSION" ]; then
            DEFAULT_VERSION=$version
            echo "Setting ${version} as default version"
            cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
            chown dnsmasq:dnsmasq /tftpboot/ipxe.efi
            chmod 644 /tftpboot/ipxe.efi
            
            # Create 'latest' symlink
            ln -sf "${DEFAULT_VERSION}" /data/httpboot/latest
        fi

        # Update ipxe.efi.cfg with correct URL
        echo "Configuring ipxe.efi.cfg for version ${version}..."
        sed -i "s|^#\?set url.*|set url http://${SERVER_IP}/${version}/|" "/data/httpboot/${version}/ipxe.efi.cfg"
    # Use sed to handle both commented and uncommented versions with proper spacing
    # Create iPXE configuration file
    cat > "/data/httpboot/${version}/ipxe.efi.cfg" <<- EOF
#!ipxe
dhcp

# Set boot parameters
set url http://${SERVER_IP}/${version}/
set console console=ttyS0 console=ttyS1 console=ttyS2 console=ttyAMA0 console=ttyAMA1 console=tty0
set eve_args eve_soft_serial=\${mac:hexhyp} eve_reboot_after_install getty
set installer_args root=/initrd.image find_boot=netboot overlaytmpfs fastboot

# Hardware-specific console settings
iseq \${smbios/manufacturer} Huawei && set console console=ttyAMA0,115200n8 ||
iseq \${smbios/manufacturer} Huawei && set platform_tweaks pcie_aspm=off pci=pcie_bus_perf ||
iseq \${smbios/manufacturer} Supermicro && set console console=ttyS1,115200n8 ||
iseq \${smbios/manufacturer} QEMU && set console console=hvc0 console=ttyS0 ||

# Chain to appropriate bootloader
iseq \${buildarch} x86_64 && chain \${url}EFI/BOOT/BOOTX64.EFI ||
iseq \${buildarch} arm64 && chain \${url}EFI/BOOT/BOOTAA64.EFI ||
iseq \${buildarch} riscv64 && chain \${url}EFI/BOOT/BOOTRISCV64.EFI ||

boot
EOF
    sed -i "s|^#\s*set url.*|set url http://${SERVER_IP}/${version}/|; s|^\s*set url.*|set url http://${SERVER_IP}/${version}/|" "/data/httpboot/${version}/ipxe.efi.cfg"

    # Verify URL injection
    echo "Verifying URL injection..."
    if ! grep -q "^set url http://${SERVER_IP}/${version}/" "/data/httpboot/${version}/ipxe.efi.cfg"; then
        echo "Warning: URL injection may have failed for version ${version}. Please verify the configuration."
        echo "Current 'set url' line in ipxe.efi.cfg:"
        grep "set url" "/data/httpboot/${version}/ipxe.efi.cfg" || echo "No 'set url' line found!"
    else
        echo "URL successfully injected for version ${version}"
    fi

done
    IFS=$OLD_IFS
}

# Function to set file permissions
set_file_permissions() {
    echo "Setting final file permissions..."
    
    # Set permissions for boot menu and configuration files
    chown www-data:www-data /data/httpboot/boot.ipxe
    chmod 644 /data/httpboot/boot.ipxe
    
    find /data/httpboot -name "ipxe.efi.cfg" -exec chown www-data:www-data {} \;
    find /data/httpboot -name "ipxe.efi.cfg" -exec chmod 644 {} \;
    
    # Set permissions for TFTP files
    find /tftpboot -type f -exec chown dnsmasq:dnsmasq {} \;
    find /tftpboot -type f -exec chmod 644 {} \;
}

# Function to generate version-specific iPXE config
generate_version_config() {
    local version=$1
    echo "Generating iPXE config for version ${version}..."

    # Create version directory if it doesn't exist
    mkdir -p "/data/httpboot/${version}"

    # Generate version-specific ipxe.efi.cfg from template
    sed "s/{{SERVER_IP}}/${SERVER_IP}/g; s/{{VERSION}}/${version}/g" \
        /config/ipxe.efi.cfg.template > "/data/httpboot/${version}/ipxe.efi.cfg"

    echo "Generated iPXE config for version ${version}"
}

# Function to generate boot menu
generate_boot_menu() {
    echo "Generating iPXE boot menu..."

    # Create the main menu that will be served over HTTP
    cat > /data/httpboot/boot.ipxe <<EOL
#!ipxe

# Enable debugging
set debug all

:start
menu EVE-OS Boot Menu
item --gap -- EVE-OS Versions:
EOL

    # Add menu items for each version
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo "item eve_${item_num} EVE-OS ${version}" >> /data/httpboot/boot.ipxe
        generate_version_config "${version}"
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add menu footer and options
    cat >> /data/httpboot/boot.ipxe <<EOL

item --gap
item --gap -- Tools:
item shell Drop to iPXE shell
item reboot Reboot system
item retry Retry network configuration
item
item --gap -- ------------------------------------------
item --gap Version information:
item --gap Selected version will boot in ${BOOT_MENU_TIMEOUT} seconds
item --gap Server IP: ${SERVER_IP}

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto menu_error
goto \${selected}

:menu_error
echo Menu selection failed
echo Error: \${errno}
prompt --timeout 5000 Press any key to retry or wait 5 seconds...
goto start
EOL

    # Add menu handlers for each version
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        cat >> /data/httpboot/boot.ipxe <<EOL

:eve_${item_num}
echo Loading EVE-OS ${version}...
chain --replace --autofree http://${SERVER_IP}/${version}/ipxe.efi.cfg || goto chain_error

:chain_error
echo Chain load failed for EVE-OS ${version}
echo Error: \${errno}
echo Common error codes:
echo 1 - File not found
echo 2 - Access denied
echo 3 - Disk error
echo 4 - Network error
prompt --timeout 5000 Press any key to return to menu or wait 5 seconds...
goto start
EOL
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add utility handlers
    cat >> /data/httpboot/boot.ipxe <<EOL

:shell
echo Dropping to iPXE shell...
shell
goto start

:reboot
echo Rebooting system...
reboot

:retry
echo Retrying network configuration...
dhcp || goto retry_error
goto start

:retry_error
echo DHCP configuration failed
echo Error: \${errno}
prompt --timeout 5000 Press any key to return to menu or wait 5 seconds...
goto start
EOL

    echo "Boot menu generated successfully"
}

# === Main Script ===
echo "Starting EVE-OS iPXE Server..."

# 1. Validate environment
validate_environment

# 2. Set up EVE-OS versions and assets
setup_eve_versions

# 3. Generate boot menu
generate_boot_menu

# 4. Configure dnsmasq
generate_dnsmasq_conf

# 5. Download bootloaders
echo "Checking bootloaders..."
if [ ! -f "/tftpboot/undionly.kpxe" ]; then
    echo "Downloading undionly.kpxe..."
    curl -L -o /tftpboot/undionly.kpxe "https://boot.ipxe.org/undionly.kpxe"
fi

# 5. Set final permissions
set_file_permissions

# 6. Start services
echo "Starting services..."
echo "Starting nginx..."
nginx

echo "Starting dnsmasq..."
exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf --log-facility=-
