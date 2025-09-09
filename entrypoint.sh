#!/bin/sh
# Exit on any error
set -e

# Function to print usage information
print_usage() {
    cat << EOF
Usage: docker run [options] ipxe-server:latest

Required Environment Variables:
  EVE_VERSIONS          Comma-separated list of EVE-OS versions (e.g. "14.5.1-lts,13.10.0")
  SERVER_IP             IP address of the server (e.g. "192.168.1.50")
  LISTEN_INTERFACE      Network interface to listen on (e.g. "eth0")

DHCP Mode Configuration:
  DHCP_MODE            Either "proxy" or "standalone" (default: "proxy")

Standalone DHCP Mode Variables:
  DHCP_RANGE_START     Start of IP range to lease (required in standalone mode)
  DHCP_RANGE_END       End of IP range to lease (required in standalone mode)
  DHCP_ROUTER          Gateway IP address (required in standalone mode)
  DHCP_SUBNET_MASK     Subnet mask (default: "255.255.255.0")

Proxy DHCP Mode Variables:
  PRIMARY_DHCP_IP      IP address of primary DHCP server (optional)

Optional Configuration:
  BOOT_MENU_TIMEOUT    Timeout in seconds for boot menu (default: 15)
  LOG_LEVEL            Set to "debug" for verbose logging (default: "info")
  DHCP_DOMAIN_NAME     Domain name for DHCP clients
  DHCP_BROADCAST_ADDRESS Broadcast address for the network

Example:
  docker run -d --net=host --privileged \
    -v ./ipxe_data:/data \
    -e EVE_VERSIONS="14.5.1-lts,13.10.0" \
    -e SERVER_IP="192.168.1.50" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="standalone" \
    -e DHCP_RANGE_START="192.168.1.100" \
    -e DHCP_RANGE_END="192.168.1.150" \
    -e DHCP_ROUTER="192.168.1.1" \
    ipxe-server:latest
EOF
}

# Function to validate IP address format
validate_ip() {
    local ip=$1
    local name=$2
    if ! echo "$ip" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null; then
        echo "Error: Invalid IP address format for $name: $ip"
        return 1
    fi
    for octet in $(echo "$ip" | tr '.' ' '); do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
            echo "Error: Invalid IP address format for $name: $ip"
            return 1
        fi
    done
    return 0
}

# Function to validate EVE versions format
validate_eve_versions() {
    local versions=$1
    if ! echo "$versions" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?(,[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?)*$' >/dev/null; then
        echo "Error: Invalid EVE_VERSIONS format. Expected format: X.Y.Z-suffix[,X.Y.Z-suffix,...]"
        return 1
    fi
    return 0
}

# Function to validate required environment variables and system state
validate_environment() {
    local has_error=0

    # Check required variables
    if [ -z "$EVE_VERSIONS" ]; then
        echo "Error: EVE_VERSIONS is required"
        has_error=1
    else
        validate_eve_versions "$EVE_VERSIONS" || has_error=1
    fi

    if [ -z "$SERVER_IP" ]; then
        echo "Error: SERVER_IP is required"
        has_error=1
    else
        validate_ip "$SERVER_IP" "SERVER_IP" || has_error=1
    fi

    if [ -z "$LISTEN_INTERFACE" ]; then
        echo "Error: LISTEN_INTERFACE is required"
        has_error=1
    fi

    # Set defaults for optional variables
    BOOT_MENU_TIMEOUT=${BOOT_MENU_TIMEOUT:="15"}
    LOG_LEVEL=${LOG_LEVEL:="info"}
    DHCP_MODE=${DHCP_MODE:="proxy"}
    DHCP_SUBNET_MASK=${DHCP_SUBNET_MASK:="255.255.255.0"}

    # Validate interface and IP configuration
    if ! ip addr show "$LISTEN_INTERFACE" &>/dev/null; then
        echo "Error: Interface $LISTEN_INTERFACE not found"
        has_error=1
    elif ! ip addr show "$LISTEN_INTERFACE" | grep -q "$SERVER_IP"; then
        echo "Error: IP $SERVER_IP not configured on $LISTEN_INTERFACE"
        has_error=1
    fi

    # Check HTTP port availability
    if netstat -ln | grep -q ':80.*LISTEN'; then
        echo "Error: Port 80 is already in use"
        has_error=1
    fi

    # Validate DHCP mode-specific configuration
    case "$DHCP_MODE" in
        standalone)
            if [ -z "$DHCP_RANGE_START" ] || [ -z "$DHCP_RANGE_END" ] || [ -z "$DHCP_ROUTER" ]; then
                echo "Error: standalone mode requires DHCP_RANGE_START, DHCP_RANGE_END, and DHCP_ROUTER"
                has_error=1
            else
                validate_ip "$DHCP_RANGE_START" "DHCP_RANGE_START" || has_error=1
                validate_ip "$DHCP_RANGE_END" "DHCP_RANGE_END" || has_error=1
                validate_ip "$DHCP_ROUTER" "DHCP_ROUTER" || has_error=1

                # Verify DHCP range is valid
                start_num=$(echo "$DHCP_RANGE_START" | awk -F. '{print ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4}')
                end_num=$(echo "$DHCP_RANGE_END" | awk -F. '{print ($1 * 256^3) + ($2 * 256^2) + ($3 * 256) + $4}')
                if [ "$start_num" -gt "$end_num" ]; then
                    echo "Error: DHCP_RANGE_START ($DHCP_RANGE_START) is greater than DHCP_RANGE_END ($DHCP_RANGE_END)"
                    has_error=1
                fi

                # Verify router is in the same subnet
                router_network=$(echo "$DHCP_ROUTER" | cut -d. -f1-3)
                start_network=$(echo "$DHCP_RANGE_START" | cut -d. -f1-3)
                if [ "$router_network" != "$start_network" ]; then
                    echo "Warning: DHCP_ROUTER ($DHCP_ROUTER) is not in the same subnet as DHCP_RANGE_START ($DHCP_RANGE_START)"
                fi
            fi
            ;;
        proxy)
            # Validate proxy mode requirements
            NETWORK_ADDRESS=$(echo "${SERVER_IP}" | awk -F. '{print $1"."$2"."$3".0"}')
            if [ -n "$PRIMARY_DHCP_IP" ]; then
                validate_ip "$PRIMARY_DHCP_IP" "PRIMARY_DHCP_IP" || has_error=1
                # Verify primary DHCP server is reachable
                if ! ping -c 1 -W 1 "$PRIMARY_DHCP_IP" >/dev/null 2>&1; then
                    echo "Warning: PRIMARY_DHCP_IP ($PRIMARY_DHCP_IP) is not responding to ping"
                fi
            fi
            ;;
        *)
            echo "Error: DHCP_MODE must be either 'proxy' or 'standalone'"
            has_error=1
            ;;
    esac

    # Validate optional IP addresses if provided
    if [ -n "$DHCP_BROADCAST_ADDRESS" ]; then
        validate_ip "$DHCP_BROADCAST_ADDRESS" "DHCP_BROADCAST_ADDRESS" || has_error=1
    fi

    # Validate numeric values
    if ! echo "$BOOT_MENU_TIMEOUT" | grep -E '^[0-9]+$' >/dev/null; then
        echo "Error: BOOT_MENU_TIMEOUT must be a positive integer"
        has_error=1
    fi

    # Print configuration if validation passed
    if [ "$has_error" -eq 0 ]; then
        echo "Configuration:"
        echo "  Server IP: ${SERVER_IP}"
        echo "  Interface: ${LISTEN_INTERFACE}"
        echo "  DHCP Mode: ${DHCP_MODE}"
        echo "  Boot Menu Timeout: ${BOOT_MENU_TIMEOUT}s"
        echo "  Log Level: ${LOG_LEVEL}"
        [ -n "$DHCP_DOMAIN_NAME" ] && echo "  Domain Name: ${DHCP_DOMAIN_NAME}"
        [ -n "$DHCP_BROADCAST_ADDRESS" ] && echo "  Broadcast Address: ${DHCP_BROADCAST_ADDRESS}"

        if [ "$DHCP_MODE" = "standalone" ]; then
            echo "  DHCP Range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
            echo "  Router: ${DHCP_ROUTER}"
            echo "  Subnet Mask: ${DHCP_SUBNET_MASK}"
        elif [ -n "$PRIMARY_DHCP_IP" ]; then
            echo "  Primary DHCP Server: ${PRIMARY_DHCP_IP}"
        fi
    else
        print_usage
        exit 1
    fi
}

# Function to generate autoexec.ipxe
generate_autoexec() {
    printf "Generating autoexec.ipxe...\n"
    sed "s/{{SERVER_IP}}/${SERVER_IP}/g" /config/autoexec.ipxe.template > /tftpboot/autoexec.ipxe
    chmod 644 /tftpboot/autoexec.ipxe
    chown dnsmasq:dnsmasq /tftpboot/autoexec.ipxe
}

# Function to generate dnsmasq configuration
generate_dnsmasq_conf() {
    printf "Generating dnsmasq configuration...\n"

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

# TFTP optimizations for large files
tftp-blocksize=8192
tftp-no-blocksize=no
tftp-max-failures=100
tftp-mtu=1500

# Client Detection
dhcp-match=set:ipxe,175                   # iPXE ROM
dhcp-match=set:efi64,option:client-arch,7  # EFI x64
dhcp-match=set:efi64,option:client-arch,9  # EFI x64
dhcp-match=set:ipxe-ok,option:user-class,iPXE

# Server options
dhcp-option=66,${SERVER_IP}              # TFTP server

# Boot configuration for BIOS clients
dhcp-boot=tag:!ipxe,tag:!efi64,undionly.kpxe

# Boot configuration for UEFI clients
dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi

# Boot configuration for iPXE clients
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

    # Validate configuration
    echo "Validating dnsmasq configuration..."
    if ! dnsmasq --test --conf-file=/etc/dnsmasq.conf; then
        echo "ERROR: dnsmasq configuration validation failed"
        echo "Current configuration:"
        cat /etc/dnsmasq.conf
        exit 1
    fi
    echo "dnsmasq configuration generated and validated successfully"
}

# Function to set up directory structure and permissions
setup_directories() {
    echo "Setting up directory structure and permissions..."
    
    # Create base directories
    echo "Creating base directories..."
    mkdir -p /data/httpboot /data/downloads /tftpboot
    
    # Create standard directory structure for /data/httpboot
    echo "Creating httpboot directory structure..."
    mkdir -p /data/httpboot/latest
    mkdir -p /data/httpboot/latest/EFI/BOOT
    
    # Set up TFTP directory structure
    echo "Creating TFTP directory structure..."
    mkdir -p /tftpboot
    
    # Set base directory permissions
    echo "Setting base directory permissions..."
    chown -R www-data:www-data /data/httpboot
    find /data/httpboot -type d -exec chmod 755 {} \;
    
    chown -R dnsmasq:dnsmasq /tftpboot
    find /tftpboot -type d -exec chmod 755 {} \;
    
    chown -R www-data:www-data /data/downloads
    find /data/downloads -type d -exec chmod 755 {} \;
    
    # Create version template directory structure
    echo "Creating version template structure..."
    mkdir -p /data/template/EFI/BOOT
    chown -R www-data:www-data /data/template
    chmod 755 /data/template
    find /data/template -type d -exec chmod 755 {} \;
    
    echo "Directory structure setup complete"
}

# Function to set up EVE-OS versions
setup_eve_versions() {
    echo "Setting up EVE-OS versions..."
    
    # Ensure directories exist
    setup_directories

    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
            printf "\nProcessing EVE-OS version: %s\n" "${version}"
        if [ ! -d "/data/httpboot/${version}" ]; then
            echo "Downloading version ${version}..."
            EVE_TAR_URL="https://github.com/lf-edge/eve/releases/download/${version}/amd64.kvm.generic.installer-net.tar"
            if ! curl -L --fail -o "/data/downloads/netboot-${version}.tar" "${EVE_TAR_URL}"; then
                echo "Error: Failed to download EVE-OS version ${version}"
                echo "URL: ${EVE_TAR_URL}"
                exit 1
            fi

            echo "Extracting assets..."
            mkdir -p "/data/httpboot/${version}"
            
            # Create a temporary directory for extraction
            TEMP_DIR="/data/downloads/temp-${version}"
            mkdir -p "${TEMP_DIR}"
            
            if ! tar -xf "/data/downloads/netboot-${version}.tar" -C "${TEMP_DIR}"; then
                echo "Error: Failed to extract EVE-OS files for version ${version}"
                rm -rf "${TEMP_DIR}"
                exit 1
            fi

            # List contents for debugging
            echo "Archive contents:"
            ls -la "${TEMP_DIR}"

            # Set up directory structure
            mkdir -p "/data/httpboot/${version}/EFI/BOOT/"

            # Generate version-specific GRUB configuration
            sed "s/{{SERVER_IP}}/${SERVER_IP}/g; s/{{VERSION}}/${version}/g" \
                /config/grub.cfg.template > "/data/httpboot/${version}/EFI/BOOT/grub.cfg"
            chown www-data:www-data "/data/httpboot/${version}/EFI/BOOT/grub.cfg"
            chmod 644 "/data/httpboot/${version}/EFI/BOOT/grub.cfg"

            # Handle EFI-related files first
            if [ -f "${TEMP_DIR}/EFI/BOOT/BOOTX64.EFI" ]; then
                echo "Copying EFI boot files..."
                cp -r "${TEMP_DIR}/EFI" "/data/httpboot/${version}/"
            elif [ -f "${TEMP_DIR}/installer.iso" ]; then
                echo "Found installer.iso, extracting EFI files..."
                ISO_EXTRACT_DIR="${TEMP_DIR}/iso"
                mkdir -p "${ISO_EXTRACT_DIR}"
                if 7z x "${TEMP_DIR}/installer.iso" -o"${ISO_EXTRACT_DIR}" EFI/BOOT/BOOTX64.EFI >/dev/null; then
                    if [ -f "${ISO_EXTRACT_DIR}/EFI/BOOT/BOOTX64.EFI" ]; then
                        echo "Copying EFI files from ISO..."
                        cp -r "${ISO_EXTRACT_DIR}/EFI" "/data/httpboot/${version}/"
                    else
                        echo "Warning: No EFI/BOOT/BOOTX64.EFI found in ISO"
                    fi
                else
                    echo "Warning: Failed to extract files from installer.iso"
                fi
                rm -rf "${ISO_EXTRACT_DIR}"
            else
                echo "Warning: No EFI boot files found in archive"
            fi

            # Copy remaining files
            for file in kernel initrd.img ucode.img rootfs.img ipxe.efi ipxe.efi.cfg; do
                if [ -f "${TEMP_DIR}/${file}" ]; then
                    echo "Copying ${file}..."
                    cp "${TEMP_DIR}/${file}" "/data/httpboot/${version}/"
                fi
            done

            # Clean up
            rm -rf "${TEMP_DIR}"
            rm "/data/downloads/netboot-${version}.tar"
            
            # Debug - show what files we have before rename
            echo "\nInitial files for version ${version}:"
            ls -laR "/data/httpboot/${version}/" || echo "Failed to list directory"

            # Rename rootfs.img if it exists
            [ -f "/data/httpboot/${version}/rootfs.img" ] && mv "/data/httpboot/${version}/rootfs.img" "/data/httpboot/${version}/rootfs_installer.img"
            
            # Ensure permissions
            chown -R www-data:www-data "/data/httpboot/${version}"
            find "/data/httpboot/${version}" -type f -exec chmod 644 {} \;
            find "/data/httpboot/${version}" -type d -exec chmod 755 {} \;

            echo "\nVerifying file structure after permission updates:"
            echo "Files for version ${version}:"
            ls -laR "/data/httpboot/${version}/" || echo "Failed to list directory"

            # Check for BOOTX64.EFI and handle ISO if needed
            if [ ! -f "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI" ] && [ -f "/data/httpboot/${version}/installer.iso" ]; then
                echo "\nBOOTX64.EFI not found but installer.iso exists. Attempting extraction..."
                ISO_EXTRACT_DIR="/tmp/iso-${version}"
                mkdir -p "${ISO_EXTRACT_DIR}"
                if 7z x "/data/httpboot/${version}/installer.iso" -o"${ISO_EXTRACT_DIR}" EFI/BOOT/BOOTX64.EFI; then
                    if [ -f "${ISO_EXTRACT_DIR}/EFI/BOOT/BOOTX64.EFI" ]; then
                        echo "Found BOOTX64.EFI in ISO, copying to target location..."
                        mkdir -p "/data/httpboot/${version}/EFI/BOOT"
                        cp "${ISO_EXTRACT_DIR}/EFI/BOOT/BOOTX64.EFI" "/data/httpboot/${version}/EFI/BOOT/"
                        chown www-data:www-data "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI"
                        chmod 644 "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI"
                    else
                        echo "ERROR: BOOTX64.EFI not found in extracted ISO content"
                    fi
                else
                    echo "ERROR: Failed to extract BOOTX64.EFI from ISO"
                fi
                rm -rf "${ISO_EXTRACT_DIR}"
            fi

# Final verification
echo "\nFinal file structure verification for ${version}:"
if [ -f "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "✓ BOOTX64.EFI is present and accessible"
    ls -l "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI"
    
    # Ensure all files are readable
    find "/data/httpboot/${version}" -type f -exec sh -c 'if ! su -s /bin/sh www-data -c "test -r {}" ; then echo "Warning: {} not readable by www-data"; fi' \;
    
    # Test nginx config
    echo "\nTesting nginx configuration..."
    nginx -t
    
    # Verify that nginx can access files
    if ! su -s /bin/sh www-data -c "cat /data/httpboot/${version}/ipxe.efi.cfg" > /dev/null 2>&1; then
        echo "Warning: www-data cannot read ipxe.efi.cfg"
    else
        echo "✓ www-data can read ipxe.efi.cfg"
    fi
else
    echo "✗ WARNING: BOOTX64.EFI is missing!"
fi
            
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
            
            echo "Setting up TFTP boot files..."
            # Copy and configure TFTP boot files
            if [ -f "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" ]; then
                echo "Setting up UEFI TFTP boot file..."
                cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
                chown dnsmasq:dnsmasq /tftpboot/ipxe.efi
                chmod 644 /tftpboot/ipxe.efi
            else
                echo "Warning: ipxe.efi not found in version ${DEFAULT_VERSION}"
            fi
            
            echo "Setting up latest version symlink..."
            # Create latest directory structure
            rm -rf "/data/httpboot/latest"
            mkdir -p "/data/httpboot/latest"
            
            # Use rsync to copy files while preserving structure
            echo "Copying files to latest directory..."
            if ! rsync -av --delete "/data/httpboot/${version}/" "/data/httpboot/latest/"; then
                echo "Warning: Error during file copy to latest directory"
                # Fallback to cp if rsync fails
                cd "/data/httpboot/${version}" && find . -type f -exec cp --parents {} "/data/httpboot/latest/" \;
            fi
            
            # Set correct ownership and permissions
            echo "Setting latest directory permissions..."
            set_file_permissions
            
            # Verify latest directory structure
            echo "\nVerifying latest directory structure:"
            VERIFY_ERRORS=0
            
            # Check required files and permissions
            for file in "EFI/BOOT/BOOTX64.EFI" "ipxe.efi.cfg" "ipxe.efi"; do
                if [ -f "/data/httpboot/latest/${file}" ]; then
                    echo "✓ ${file} is present"
                    if su -s /bin/sh www-data -c "test -r /data/httpboot/latest/${file}"; then
                        echo "✓ ${file} is readable by www-data"
                    else
                        echo "✗ WARNING: ${file} is not readable by www-data"
                        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
                    fi
                else
                    echo "✗ WARNING: ${file} is missing"
                    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
                fi
            done
            
            # Check directory permissions
            if [ ! -x "/data/httpboot/latest" ] || [ ! -x "/data/httpboot/latest/EFI" ] || [ ! -x "/data/httpboot/latest/EFI/BOOT" ]; then
                echo "✗ WARNING: One or more directories are not executable"
                VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
            fi
            
            # Report verification results
            if [ "$VERIFY_ERRORS" -eq 0 ]; then
                echo "\n✓ Latest directory verification completed successfully"
            else
                echo "\n✗ Latest directory verification completed with ${VERIFY_ERRORS} errors"
            fi
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
    local version=$1
    echo "Setting file permissions..."

    if [ -n "$version" ]; then
        echo "Setting permissions for version ${version}..."
        # Version-specific files
        if [ -d "/data/httpboot/${version}" ]; then
            echo "Setting version directory permissions..."
            chown -R www-data:www-data "/data/httpboot/${version}"
            find "/data/httpboot/${version}" -type d -exec chmod 755 {} \;
            find "/data/httpboot/${version}" -type f -exec chmod 644 {} \;

            # Special handling for EFI files
            if [ -d "/data/httpboot/${version}/EFI/BOOT" ]; then
                echo "Setting EFI directory permissions..."
                chmod 755 "/data/httpboot/${version}/EFI" "/data/httpboot/${version}/EFI/BOOT"
                [ -f "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI" ] && chmod 644 "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI"
            fi

            # Set iPXE config permissions
            echo "Setting iPXE config permissions..."
            find "/data/httpboot/${version}" -name "ipxe.efi.cfg" -exec chmod 644 {} \;
            find "/data/httpboot/${version}" -name "*.ipxe" -exec chmod 644 {} \;
        fi
    else
        echo "Setting global file permissions..."
        # Global boot menu
        if [ -f "/data/httpboot/boot.ipxe" ]; then
            echo "Setting boot menu permissions..."
            chown www-data:www-data /data/httpboot/boot.ipxe
            chmod 644 /data/httpboot/boot.ipxe
        fi

        # TFTP files
        echo "Setting TFTP file permissions..."
        find /tftpboot -type f -exec chown dnsmasq:dnsmasq {} \;
        find /tftpboot -type f -exec chmod 644 {} \;

        # Latest directory
        if [ -d "/data/httpboot/latest" ]; then
            echo "Setting latest directory permissions..."
            chown -R www-data:www-data "/data/httpboot/latest"
            find "/data/httpboot/latest" -type d -exec chmod 755 {} \;
            find "/data/httpboot/latest" -type f -exec chmod 644 {} \;
        fi

        # iPXE configs (global)
        echo "Setting global iPXE config permissions..."
        find /data/httpboot -name "ipxe.efi.cfg" -exec chown www-data:www-data {} \;
        find /data/httpboot -name "ipxe.efi.cfg" -exec chmod 644 {} \;
        find /data/httpboot -name "*.ipxe" -exec chown www-data:www-data {} \;
        find /data/httpboot -name "*.ipxe" -exec chmod 644 {} \;
    fi

    echo "File permissions updated successfully"
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
    
    # Create initial menu file
    cat > /data/httpboot/boot.ipxe <<'EOF'
#!ipxe

# Enable debugging and wait for network
set debug all
set debug dhcp,net

:retry_dhcp
echo Configuring network...
dhcp || goto retry_dhcp_fail

echo Network configured successfully:
echo IP: ${net0/ip}
echo Netmask: ${net0/netmask}
echo Gateway: ${net0/gateway}
echo DNS: ${net0/dns}

# Main menu
:start
menu EVE-OS Boot Menu
item --gap -- System Information:
item --gap -- Client IP: ${net0/ip}
item --gap -- Architecture: ${buildarch}
item --gap -- Manufacturer: ${smbios/manufacturer}
item --gap --
item --gap -- Available versions:
EOF
    
    # Add menu items
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo "item eve_${item_num} EVE-OS ${version}" >> /data/httpboot/boot.ipxe
        generate_version_config "${version}"
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS
    
    # Add menu footer
    cat >> /data/httpboot/boot.ipxe <<'EOF'

item
item --gap -- Tools:
item shell Drop to iPXE shell
item reboot Reboot system
item retry Retry network configuration
item
item --gap -- --------------------------------------------
item --gap Version information:
item --gap Selected version will boot in ${BOOT_MENU_TIMEOUT} seconds
item --gap Server IP: ${SERVER_IP}

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto menu_error
goto ${selected}

:retry_dhcp_fail
echo DHCP configuration failed. Retrying in 3 seconds...
sleep 3
goto retry_dhcp

:menu_error
echo Menu selection failed
echo Error: ${errno}
echo Error message: ${errstr}
prompt --timeout 5000 Press any key to retry or wait 5 seconds...
goto start
EOF

    # Add menu handlers
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        cat >> /data/httpboot/boot.ipxe <<EOF

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
EOF
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add utility handlers
    cat >> /data/httpboot/boot.ipxe <<EOF

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
EOF

    # Set permissions
    chmod 644 /data/httpboot/boot.ipxe
    chown www-data:www-data /data/httpboot/boot.ipxe
    
    echo "Boot menu generated successfully"
}

# === Main Script ===
echo "Starting EVE-OS iPXE Server..."

# 1. Validate environment
validate_environment

# 2. Set up EVE-OS versions and assets
setup_eve_versions

# Source iPXE configuration functions
# Function to generate version-specific iPXE config
generate_version_config() {
    local version=$1
    echo "Generating iPXE config for version ${version}..."

    # Create version directory if it doesn't exist
    mkdir -p "/data/httpboot/${version}"

    # Generate config from template
    echo "Using template from /config/ipxe.efi.cfg.template"
    if [ ! -f "/config/ipxe.efi.cfg.template" ]; then
        echo "ERROR: Template file /config/ipxe.efi.cfg.template not found!"
        exit 1
    fi

    # Replace variables in template
    echo "Injecting variables: SERVER_IP=${SERVER_IP}, VERSION=${version}"
    sed "s/{{SERVER_IP}}/${SERVER_IP}/g; s/{{VERSION}}/${version}/g" \
        /config/ipxe.efi.cfg.template > "/data/httpboot/${version}/ipxe.efi.cfg"

    # Set permissions
    chmod 644 "/data/httpboot/${version}/ipxe.efi.cfg"
    chown www-data:www-data "/data/httpboot/${version}/ipxe.efi.cfg"

    # Verify the generated config
    echo "Verifying generated config..."
    if ! grep -q "^#!ipxe" "/data/httpboot/${version}/ipxe.efi.cfg"; then
        echo "ERROR: Generated config missing required iPXE header!"
        exit 1
    fi
    if ! grep -q "set next-server ${SERVER_IP}" "/data/httpboot/${version}/ipxe.efi.cfg"; then
        echo "WARNING: Server IP variable injection may have failed"
    fi
    if ! grep -q "set boot-url http://${SERVER_IP}/${version}" "/data/httpboot/${version}/ipxe.efi.cfg"; then
        echo "WARNING: Boot URL variable injection may have failed"
    fi

    echo "Successfully generated iPXE config for version ${version}"
}

# Function to generate boot menu
generate_boot_menu() {
    echo "Generating iPXE boot menu..."
    
    # Create initial menu file
    cat > /data/httpboot/boot.ipxe <<'EOF'
#!ipxe

# Enable debugging
set debug all
set debug dhcp,net

# Configure network settings
:retry_dhcp
echo Configuring network...
dhcp || goto retry_dhcp_fail

echo Network configured successfully:
echo IP: ${net0/ip}
echo Netmask: ${net0/netmask}
echo Gateway: ${net0/gateway}
echo DNS: ${net0/dns}

# Main menu
:start
menu EVE-OS Boot Menu
item --gap -- Available versions:
EOF
    
    # Add menu items
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        echo "item eve_${item_num} EVE-OS ${version}" >> /data/httpboot/boot.ipxe
        generate_version_config "${version}"
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS
    
    # Add menu footer
    cat >> /data/httpboot/boot.ipxe <<'EOF'

item
item --gap -- Tools:
item shell Drop to iPXE shell
item reboot Reboot system
item retry Retry network configuration
item
item --gap -- --------------------------------------------
item --gap Version information:
item --gap Selected version will boot in ${BOOT_MENU_TIMEOUT} seconds
item --gap Server IP: ${SERVER_IP}
item --gap Client IP: ${net0/ip}
item --gap Architecture: ${buildarch}

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto menu_error
goto ${selected}

:retry_dhcp_fail
echo DHCP configuration failed. Retrying in 3 seconds...
sleep 3
goto retry_dhcp

:menu_error
echo Menu selection failed
echo Error: ${errno}
prompt --timeout 5000 Press any key to retry or wait 5 seconds...
goto start
EOF

    # Add menu handlers for each version
    item_num=1
    OLD_IFS=$IFS
    IFS=','
    for version in $EVE_VERSIONS; do
        cat >> /data/httpboot/boot.ipxe <<EOF

:eve_${item_num}
echo Loading EVE-OS ${version}...
echo Attempting to chain load http://${SERVER_IP}/${version}/ipxe.efi.cfg
chain --replace --autofree http://${SERVER_IP}/${version}/ipxe.efi.cfg || goto chain_error_${item_num}

:chain_error_${item_num}
echo Chain load failed for EVE-OS ${version}
echo Error: \${errno}
echo Common error codes:
echo 1 - File not found
echo 2 - Access denied
echo 3 - Disk error
echo 4 - Network error
prompt --timeout 5000 Press any key to return to menu or wait 5 seconds...
goto start
EOF
        item_num=$((item_num+1))
    done
    IFS=$OLD_IFS

    # Add utility handlers
    cat >> /data/httpboot/boot.ipxe <<'EOF'

:shell
echo Dropping to iPXE shell...
shell
goto start

:reboot
echo Rebooting system...
reboot

:retry
echo Retrying network configuration...
goto retry_dhcp
EOF

    # Set permissions
    chmod 644 /data/httpboot/boot.ipxe
    chown www-data:www-data /data/httpboot/boot.ipxe
    
    echo "Boot menu generated successfully"
}

# Generate iPXE boot menu
generate_boot_menu

# 4. Configure boot files
generate_autoexec
generate_dnsmasq_conf

# 5. Download bootloaders
echo "Checking bootloaders..."
if [ ! -f "/tftpboot/undionly.kpxe" ]; then
    echo "Downloading undionly.kpxe..."
    curl -L -o /tftpboot/undionly.kpxe "https://boot.ipxe.org/undionly.kpxe"
fi

# 5. Set final permissions
set_file_permissions

# 6. Final pre-start validation
echo "Running final validation checks..."

# Verify critical files and permissions
echo "Checking critical files and permissions..."

check_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "ERROR: Critical file missing: $file"
        exit 1
    fi

    if ! su -s /bin/sh www-data -c "test -r \"$file\""; then
        echo "ERROR: www-data cannot read: $file"
        exit 1
    fi
}

check_file "/data/httpboot/boot.ipxe"
check_file "/data/httpboot/latest/ipxe.efi"
check_file "/data/httpboot/latest/ipxe.efi.cfg"
check_file "/data/httpboot/latest/EFI/BOOT/BOOTX64.EFI"

# Verify boot.ipxe content
echo "Verifying boot.ipxe content..."
if ! grep -q "chain --replace --autofree" /data/httpboot/boot.ipxe || \
   ! grep -q "menu EVE-OS Boot Menu" /data/httpboot/boot.ipxe || \
   ! grep -q "#!ipxe" /data/httpboot/boot.ipxe; then
    echo "ERROR: boot.ipxe appears to be invalid"
    echo "Missing one or more required elements:"
    echo "  - #!ipxe header"
    echo "  - menu EVE-OS Boot Menu"
    echo "  - chain --replace --autofree command"
    echo "\nCurrent content:"
    cat /data/httpboot/boot.ipxe
    exit 1
fi

# Test nginx configuration
echo "Testing nginx configuration..."
if ! nginx -t; then
    echo "ERROR: Invalid nginx configuration"
    exit 1
fi

# Test dnsmasq configuration
echo "Testing dnsmasq configuration..."
if ! dnsmasq --test; then
    echo "ERROR: Invalid dnsmasq configuration"
    exit 1
fi

# Start services with enhanced logging
echo "Starting services..."
echo "Starting nginx with debug logging..."
nginx -g "daemon off; error_log /dev/stdout debug;" &
NGINX_PID=$!

echo "Starting dnsmasq with debug logging..."
exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf --log-facility=- --log-dhcp --log-queries
