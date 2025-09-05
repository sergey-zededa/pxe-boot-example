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

# Boot Configuration
dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi,,${SERVER_IP}
pxe-service=tag:efi64,X86-64_EFI,"EVE-OS Network Boot",ipxe.efi
dhcp-boot=tag:ipxe,http://${SERVER_IP}/boot.ipxe
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

# Function to set up EVE-OS versions
setup_eve_versions() {
    echo "Setting up EVE-OS versions..."
    mkdir -p /data/httpboot /data/downloads /tftpboot

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
        else
            echo "Version ${version} found in cache"
        fi

        # Set up first version as default
        if [ -z "$DEFAULT_VERSION" ]; then
            DEFAULT_VERSION=$version
            echo "Setting ${version} as default version"
            cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
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

# Function to generate iPXE boot menu
generate_boot_menu() {
    echo "Generating iPXE boot menu..."

    # Create the main menu that will be served over HTTP
    cat > /data/httpboot/boot.ipxe <<EOL
#!ipxe

:start
menu EVE-OS Version Selection

EOL

    # Add menu items for each version
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo "item eve_${item_num} Install EVE-OS ${version}" >> /data/httpboot/boot.ipxe
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add menu footer and default selection
    cat >> /data/httpboot/boot.ipxe <<EOL

item --gap -- ------------------------------------------
item shell Drop to iPXE shell
item reboot Reboot computer

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto start
goto \${selected}
EOL

    # Add menu handlers for each version
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo ":eve_${item_num}" >> /data/httpboot/boot.ipxe
        echo "chain http://${SERVER_IP}/${version}/ipxe.efi.cfg || goto failed" >> /data/httpboot/boot.ipxe
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add utility handlers
    cat >> /data/httpboot/boot.ipxe <<EOL

:shell
shell
goto start

:reboot
reboot

:failed
echo Boot failed, returning to menu in 5 seconds...
sleep 5
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

# 6. Start services
echo "Starting services..."
echo "Starting nginx..."
nginx

echo "Starting dnsmasq..."
exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf --log-facility=-
echo "port=0" >> /etc/dnsmasq.conf
echo "interface=${LISTEN_INTERFACE}" >> /etc/dnsmasq.conf
echo "bind-interfaces" >> /etc/dnsmasq.conf
echo "enable-tftp" >> /etc/dnsmasq.conf
echo "tftp-root=/tftpboot" >> /etc/dnsmasq.conf

# Architecture detection for BIOS vs UEFI
echo "dhcp-match=set:bios,option:client-arch,0" >> /etc/dnsmasq.conf
echo "dhcp-match=set:efi32,option:client-arch,6" >> /etc/dnsmasq.conf
echo "dhcp-match=set:efi64,option:client-arch,7" >> /etc/dnsmasq.conf
echo "dhcp-match=set:efi64,option:client-arch,9" >> /etc/dnsmasq.conf

# iPXE detection - option 175 is sent by iPXE clients
echo "dhcp-match=set:ipxe,175" >> /etc/dnsmasq.conf

# Boot configuration for different architectures
# BIOS clients get undionly.kpxe, UEFI clients get ipxe.efi
echo "dhcp-boot=tag:bios,tag:!ipxe,undionly.kpxe,,${SERVER_IP}" >> /etc/dnsmasq.conf
echo "dhcp-boot=tag:efi32,tag:!ipxe,ipxe.efi,,${SERVER_IP}" >> /etc/dnsmasq.conf
echo "dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi,,${SERVER_IP}" >> /etc/dnsmasq.conf

# Once iPXE is loaded, serve the boot script directly via TFTP
echo "dhcp-boot=tag:ipxe,autoexec.ipxe,,${SERVER_IP}" >> /etc/dnsmasq.conf

# Set up proxy DHCP mode
echo "dhcp-range=${NETWORK_ADDRESS},proxy,${DHCP_SUBNET_MASK}" >> /etc/dnsmasq.conf

# TFTP server configuration
echo "enable-tftp" >> /etc/dnsmasq.conf
echo "tftp-root=/tftpboot" >> /etc/dnsmasq.conf

# Client type detection
echo "dhcp-match=set:ipxe,175" >> /etc/dnsmasq.conf
echo "dhcp-vendorclass=set:efi64,PXEClient:Arch:00007" >> /etc/dnsmasq.conf
echo "dhcp-vendorclass=set:efi64,PXEClient:Arch:00009" >> /etc/dnsmasq.conf

# Set TFTP server options
echo "dhcp-option=66,${SERVER_IP}" >> /etc/dnsmasq.conf
echo "dhcp-option=67,ipxe.efi" >> /etc/dnsmasq.conf

# Boot configuration
echo "pxe-service=tag:efi64,X86-64_EFI,\"EVE-OS Network Boot\",ipxe.efi" >> /etc/dnsmasq.conf

# iPXE client gets HTTP config
echo "dhcp-boot=tag:ipxe,http://${SERVER_IP}/boot.ipxe" >> /etc/dnsmasq.conf

# PXE service configuration for proxy DHCP
echo "pxe-service=tag:bios,x86PC,\"EVE-OS Network Boot\",undionly.kpxe,${SERVER_IP}" >> /etc/dnsmasq.conf
echo "pxe-service=tag:efi32,IA32_EFI,\"EVE-OS Network Boot\",ipxe.efi,${SERVER_IP}" >> /etc/dnsmasq.conf
echo "pxe-service=tag:efi64,X86-64_EFI,\"EVE-OS Network Boot\",ipxe.efi,${SERVER_IP}" >> /etc/dnsmasq.conf

# TFTP configuration
echo "tftp-no-blocksize" >> /etc/dnsmasq.conf

if [ "$DHCP_MODE" = "standalone" ]; then
    echo "Configuring standalone DHCP mode..."
    if [ -z "$DHCP_RANGE_START" ] || [ -z "$DHCP_RANGE_END" ] || [ -z "$DHCP_ROUTER" ]; then
        echo "Error: For DHCP_MODE=standalone, you must set DHCP_RANGE_START, DHCP_RANGE_END, and DHCP_ROUTER."
        exit 1
    fi
    echo "dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_SUBNET_MASK},12h" >> /etc/dnsmasq.conf
    echo "dhcp-option=option:router,${DHCP_ROUTER}" >> /etc/dnsmasq.conf
elif [ "$DHCP_MODE" = "proxy" ]; then
    echo "Configuring proxy DHCP mode..."
    # Calculate network address for proxy DHCP
    NETWORK_ADDRESS=$(echo ${SERVER_IP} | awk -F. '{print $1"."$2"."$3".0"}')
    echo "dhcp-range=${NETWORK_ADDRESS},proxy,${DHCP_SUBNET_MASK}" >> /etc/dnsmasq.conf
    if [ -n "$DHCP_ROUTER" ]; then
        echo "dhcp-option=3,${DHCP_ROUTER}" >> /etc/dnsmasq.conf
    fi
    if [ -n "$DHCP_DOMAIN_NAME" ]; then
        echo "dhcp-option=15,${DHCP_DOMAIN_NAME}" >> /etc/dnsmasq.conf
    fi
    if [ -n "$DHCP_BROADCAST_ADDRESS" ]; then
        echo "dhcp-option=28,${DHCP_BROADCAST_ADDRESS}" >> /etc/dnsmasq.conf
    fi
else
    echo "Error: Invalid DHCP_MODE specified. Must be 'proxy' or 'standalone'."
    exit 1
fi

if [ "$LOG_LEVEL" = "debug" ]; then
    echo "log-queries" >> /etc/dnsmasq.conf
    echo "log-dhcp" >> /etc/dnsmasq.conf
fi

# === 4. Generate Root iPXE Menu Script ===
echo "Generating iPXE boot menu..."

# Create the main menu that will be served over HTTP
echo "Generating boot.ipxe in HTTP root..."
cat > /data/httpboot/boot.ipxe <<- EOF
#!ipxe

:start
menu EVE-OS Version Selection

EOF

item_num=1
OLD_IFS=$IFS
IFS=','
for version in $EVE_VERSIONS; do
    echo "item eve_${item_num} Install EVE-OS ${version}" >> /tftpboot/boot.ipxe
    item_num=$((item_num+1))
done
IFS=$OLD_IFS

cat >> /tftpboot/boot.ipxe <<- EOF

item --gap -- ------------------------------------------
item shell Drop to iPXE shell
item reboot Reboot computer

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto start
goto \${selected}

EOF

item_num=1
OLD_IFS=$IFS
IFS=','
for version in $EVE_VERSIONS; do
    echo ":eve_${item_num}" >> /tftpboot/boot.ipxe
    echo "chain http://${SERVER_IP}/${version}/ipxe.efi.cfg || goto failed" >> /tftpboot/boot.ipxe
    item_num=$((item_num+1))
done
IFS=$OLD_IFS

cat >> /tftpboot/boot.ipxe <<- EOF

:shell
shell
goto start

:reboot
reboot

:failed
echo Boot failed, returning to menu in 5 seconds...
sleep 5
goto start

EOF

# Copy boot.ipxe to autoexec.ipxe for fallback
cp /tftpboot/boot.ipxe /tftpboot/autoexec.ipxe

# === 5. Add missing bootloaders ===
echo "Downloading iPXE bootloaders..."

# Download undionly.kpxe for BIOS clients if not present
if [ ! -f "/tftpboot/undionly.kpxe" ]; then
    echo "Downloading undionly.kpxe for BIOS clients..."
    curl -L -o /tftpboot/undionly.kpxe "https://boot.ipxe.org/undionly.kpxe"
fi

# Ensure ipxe.efi is available
if [ ! -f "/tftpboot/ipxe.efi" ] && [ -n "$DEFAULT_VERSION" ]; then
    echo "Copying ipxe.efi from EVE assets..."
    cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
fi

# === 6. Start Services ===
echo "Starting nginx..."
nginx

echo "Starting dnsmasq..."
dnsmasq --no-daemon
