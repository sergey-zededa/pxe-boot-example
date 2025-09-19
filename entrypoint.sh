#!/bin/sh
# Exit on any error
set -e

# Function to process configuration templates
process_template() {
    local template_path=$1
    local output_path=$2
    local template_name=$(basename "$template_path")
    local variables=$3
    local temp_script=$(mktemp)
    local temp_vars=$(mktemp)

    # Check template existence
    if [ ! -f "$template_path" ]; then
        echo "ERROR: Template $template_name not found!"
        rm -f "$temp_script" "$temp_vars"
        exit 1
    fi

    echo "Processing template: $template_name"
    echo "Output path: $output_path"

    # Write variables to temporary file for processing
    echo "$variables" > "$temp_vars"

    # Create a temporary sed script
    echo "Creating sed script with variable substitutions"
    while IFS='=' read -r key value; do
        if [ -n "$key" ]; then
            echo "s/{{${key}}}/${value//\//\\/}/g" >> "$temp_script"
            echo "  - Substituting: {{${key}}} → ${value}"
        fi
    done < "$temp_vars"

    # If no substitutions were added, create a no-op script
    if [ ! -s "$temp_script" ]; then
        echo "No variables provided; copying template as-is"
        echo 'p' > "$temp_script"
    fi

    # Process template using the script
    sed -f "$temp_script" "$template_path" > "$output_path"
    local sed_status=$?

    # Clean up
    rm -f "$temp_script" "$temp_vars"

    # Verify output
    if [ $sed_status -ne 0 ] || [ ! -f "$output_path" ]; then
        echo "ERROR: Failed to generate output file: $output_path"
        echo "sed exit status: $sed_status"
        exit 1
    fi

    echo "Successfully processed $template_name"
}

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

# Function to check if either pattern exists in a file
check_patterns() {
    local file="$1"
    local pattern1="$2"
    local pattern2="$3"
    local desc="$4"
    local found1=false
    local found2=false

    if grep -F "$pattern1" "$file" >/dev/null 2>&1; then
        found1=true
    fi
    if grep -F "$pattern2" "$file" >/dev/null 2>&1; then
        found2=true
    fi

    if [ "$found1" = false ] && [ "$found2" = false ]; then
        echo "WARNING: $desc not found in generated config"
        echo "Expected either:"
        echo "  $pattern1"
        echo "  $pattern2"
        return 1
    fi
    return 0
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

    # Validate interface and IP configuration (more robust)
    if [ ! -d "/sys/class/net/${LISTEN_INTERFACE}" ]; then
        echo "Error: Interface $LISTEN_INTERFACE not found"
        has_error=1
    else
        # Do not hard-fail if the container's view doesn't have the host IP; warn instead
        if ! ip -o addr show dev "$LISTEN_INTERFACE" 2>/dev/null | grep -q "$SERVER_IP"; then
            echo "Warning: IP $SERVER_IP not observed on $LISTEN_INTERFACE inside container"
        fi
    fi

    # Check HTTP port availability using ss (netstat may be unavailable)
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn | grep -q ":80"; then
            echo "Error: Port 80 is already in use"
            has_error=1
        fi
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
    process_template \
        "/config/autoexec.ipxe.template" \
        "/tftpboot/autoexec.ipxe" \
        "SERVER_IP=${SERVER_IP}"
    chmod 644 /tftpboot/autoexec.ipxe
chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} /tftpboot/autoexec.ipxe
}

# Function to generate nginx configuration (production defaults)
# - concise logging
# - single error_log declaration
# - strict file serving from /data/httpboot
# The template contains no DEBUG-only branches to avoid drift between modes.
generate_nginx_conf() {
    printf "Generating nginx configuration...\n"

    # Process template
    process_template \
        "/config/nginx.conf.template" \
        "/etc/nginx/nginx.conf" \
        "DEBUG=${DEBUG}"

    # Validate configuration
    echo "Validating nginx configuration..."
    if ! nginx -t; then
        echo "ERROR: nginx configuration validation failed"
        echo "Current configuration:"
        cat /etc/nginx/nginx.conf
        exit 1
    fi
    echo "nginx configuration generated and validated successfully"
}

# Function to generate dnsmasq configuration
generate_dnsmasq_conf() {
    printf "Generating dnsmasq configuration...\n"

    # Check template existence
    if [ ! -f "/config/dnsmasq.conf.template" ]; then
        echo "ERROR: dnsmasq.conf.template not found in /config"
        exit 1
    fi

    # Compute network address for proxy mode
    NETWORK_ADDRESS=$(echo ${SERVER_IP} | awk -F. '{print $1"."$2"."$3".0"}')

    # Set standalone mode flag for template
    if [ "$DHCP_MODE" = "standalone" ]; then
        STANDALONE_MODE=1
    else
        STANDALONE_MODE=0
    fi

    # Set debug flag for template
    if [ "$LOG_LEVEL" = "debug" ]; then
        DEBUG=1
    else
        DEBUG=0
    fi

    # Build mode-specific DHCP configuration block (with real newlines)
    if [ "$DHCP_MODE" = "standalone" ]; then
        DHCP_CONFIG=$(printf '%s\n' \
            "# Standalone DHCP Configuration" \
            "dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_SUBNET_MASK},12h" \
            "dhcp-option=option:router,${DHCP_ROUTER}")
    else
        DHCP_CONFIG=$(printf '%s\n' \
            "# Proxy DHCP Configuration" \
            "dhcp-range=${NETWORK_ADDRESS},proxy,${DHCP_SUBNET_MASK}")
        # Note: In proxy mode, do NOT use dhcp-relay. Combining dhcp-relay with any dhcp-range is invalid in dnsmasq.
        # PRIMARY_DHCP_IP is retained for connectivity validation only.
    fi

    # Optional blocks (single-line strings)
    DOMAIN_CONFIG=""
    [ -n "$DHCP_DOMAIN_NAME" ] && DOMAIN_CONFIG="domain=${DHCP_DOMAIN_NAME}"

    BROADCAST_CONFIG=""
    [ -n "$DHCP_BROADCAST_ADDRESS" ] && BROADCAST_CONFIG="dhcp-option=28,${DHCP_BROADCAST_ADDRESS}"

    DEBUG_CONFIG=""
    if [ "$LOG_LEVEL" = "debug" ]; then
        DEBUG_CONFIG=$(printf '%s\n' "# Debug Logging" "log-queries" "log-dhcp")
    fi

    # Generate configuration using template (substitute only simple variables first)
    echo "Processing dnsmasq configuration template..."
    TEMPLATE_VARS=$(printf '%s\n' \
        "LISTEN_INTERFACE=${LISTEN_INTERFACE}" \
        "SERVER_IP=${SERVER_IP}" \
        "DHCP_SUBNET_MASK=${DHCP_SUBNET_MASK}" \
        "NETWORK_ADDRESS=${NETWORK_ADDRESS}")

    process_template \
        "/config/dnsmasq.conf.template" \
        "/etc/dnsmasq.conf" \
        "$TEMPLATE_VARS"

    # Replace block placeholders with their multi-line content using awk
    awk -v DHCP="$DHCP_CONFIG" \
        -v DOMAIN="$DOMAIN_CONFIG" \
        -v BC="$BROADCAST_CONFIG" \
        -v DEBUGB="$DEBUG_CONFIG" '
      {
        if (index($0, "{{DHCP_CONFIG}}")) { if (DHCP != "") print DHCP; next }
        if (index($0, "{{DOMAIN_CONFIG}}")) { if (DOMAIN != "") print DOMAIN; next }
        if (index($0, "{{BROADCAST_CONFIG}}")) { if (BC != "") print BC; next }
        if (index($0, "{{DEBUG_CONFIG}}")) { if (DEBUGB != "") print DEBUGB; next }
        print
      }
    ' /etc/dnsmasq.conf > /etc/dnsmasq.conf.tmp && mv /etc/dnsmasq.conf.tmp /etc/dnsmasq.conf

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
    # CRITICAL: Since TFTP now serves from /data/httpboot, dnsmasq needs read access
    echo "Setting base directory permissions with shared TFTP/HTTP access..."
    
    # Add dnsmasq user to www-data group for shared access
    adduser dnsmasq www-data 2>/dev/null || true
    
    chown -R www-data:www-data /data/httpboot
    find /data/httpboot -type d -exec chmod 755 {} \;
    find /data/httpboot -type f -exec chmod 644 {} \;
    
chown -R ${DNSMASQ_USER}:${DNSMASQ_GROUP} /tftpboot
    find /tftpboot -type d -exec chmod 755 {} \;
    find /tftpboot -type f -exec chmod 644 {} \;
    
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

# Ensure version directory contains kernel/initrd/ucode/rootfs_installer assets.
# If missing and installer.iso exists, attempt extraction from common ISO paths.
ensure_version_assets() {
    local version="$1"
    local dir="/data/httpboot/${version}"
    local changed=0

    [ -d "$dir" ] || return 0

    echo "Ensuring kernel assets for ${version}..."

    # If rootfs_installer.img is missing but rootfs.img is present, rename it
    if [ ! -f "$dir/rootfs_installer.img" ] && [ -f "$dir/rootfs.img" ]; then
        mv "$dir/rootfs.img" "$dir/rootfs_installer.img"
        changed=1
    fi

    # Always try to extract missing files from installer.iso if it exists
    if [ -f "$dir/installer.iso" ]; then
        echo "Extracting missing kernel components from installer.iso for ${version}..."
        
        # Create temporary directory for ISO extraction
        local temp_iso_dir="$dir/temp_iso_extract"
        mkdir -p "$temp_iso_dir"
        
        # Extract specific files from ISO using known EVE-OS structure
        echo "Extracting files from installer.iso using EVE-OS structure..."
        if 7z x "$dir/installer.iso" -o"$temp_iso_dir" -y >/dev/null 2>&1; then
            echo "ISO extraction successful, copying required files..."
            
            # Copy kernel from boot/kernel (actual EVE-OS location)
            if [ ! -f "$dir/kernel" ] && [ -f "$temp_iso_dir/boot/kernel" ]; then
                echo "Extracting kernel from boot/kernel"
                cp "$temp_iso_dir/boot/kernel" "$dir/kernel"
                changed=1
            fi
            
            # Copy initrd from boot/initrd.img (actual EVE-OS location)
            if [ ! -f "$dir/initrd.img" ] && [ -f "$temp_iso_dir/boot/initrd.img" ]; then
                echo "Extracting initrd from boot/initrd.img"
                cp "$temp_iso_dir/boot/initrd.img" "$dir/initrd.img"
                changed=1
            fi
            
            # Copy ucode from boot/ucode.img (actual EVE-OS location)
            if [ ! -f "$dir/ucode.img" ] && [ -f "$temp_iso_dir/boot/ucode.img" ]; then
                echo "Extracting ucode from boot/ucode.img"
                cp "$temp_iso_dir/boot/ucode.img" "$dir/ucode.img"
                changed=1
            fi
            
            # Copy rootfs from root level (actual EVE-OS location)
            if [ ! -f "$dir/rootfs_installer.img" ] && [ -f "$temp_iso_dir/rootfs_installer.img" ]; then
                echo "Extracting rootfs_installer from root level"
                cp "$temp_iso_dir/rootfs_installer.img" "$dir/rootfs_installer.img"
                changed=1
            fi
            
        else
            echo "Warning: Failed to extract installer.iso for ${version}"
        fi
        
        # Clean up temporary extraction directory
        rm -rf "$temp_iso_dir"
        
    else
        echo "Warning: ${dir}/installer.iso not found; cannot extract additional assets"
    fi
    
    # Log extraction results
    if [ "$changed" -eq 1 ]; then
        echo "Successfully extracted additional files from installer.iso"
    else
        echo "No additional files needed to be extracted"
    fi

    # Ensure permissions on any (new) files
    if [ "$changed" -eq 1 ]; then
        chown -R www-data:www-data "$dir"
        find "$dir" -type f -exec chmod 644 {} \;
        find "$dir" -type d -exec chmod 755 {} \;
    fi

    # Final report
    for f in kernel initrd.img ucode.img rootfs_installer.img; do
        if [ -f "$dir/$f" ]; then
            echo "✓ ${version}/$f present"
        else
            echo "✗ WARNING: ${version}/$f missing"
        fi
    done
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

            # After extracting the tar, copy all files we know about into the target dir
            # Some archives already contain kernel/initrd at top-level; copy if present
            for f in kernel initrd.img ucode.img rootfs.img installer.iso EFI; do
                if [ -e "${TEMP_DIR}/$f" ]; then
                    echo "Copying $f from archive..."
                    cp -r "${TEMP_DIR}/$f" "/data/httpboot/${version}/"
                fi
            done

            # Extract kernel assets from installer.iso using known EVE-OS paths
            iso_path="/data/httpboot/${version}/installer.iso"
            extract_dir="/data/httpboot/${version}"
            if [ -f "$iso_path" ]; then
                echo "Extracting kernel components from installer.iso using EVE-OS paths..."
                # Extract specific files using actual EVE-OS structure
                if 7z x "$iso_path" -o"$extract_dir" boot/kernel boot/initrd.img boot/ucode.img rootfs_installer.img -y >/dev/null 2>&1; then
                    # Move files from boot/ to root level
                    [ -f "$extract_dir/boot/kernel" ] && mv "$extract_dir/boot/kernel" "$extract_dir/kernel" || true
                    [ -f "$extract_dir/boot/initrd.img" ] && mv "$extract_dir/boot/initrd.img" "$extract_dir/initrd.img" || true
                    [ -f "$extract_dir/boot/ucode.img" ] && mv "$extract_dir/boot/ucode.img" "$extract_dir/ucode.img" || true
                    # rootfs_installer.img is already at root level
                    rmdir "$extract_dir/boot" 2>/dev/null || true
                    echo "Successfully extracted files using EVE-OS paths"
                else
                    echo "Warning: Unable to extract kernel assets from installer.iso"
                fi
            else
                echo "Warning: installer.iso not found for version ${version}. Cannot extract kernel assets."
            fi

            # Set up directory structure
            mkdir -p "/data/httpboot/${version}/EFI/BOOT/"
            
            # Handle EFI-related files first
            if [ -f "${TEMP_DIR}/EFI/BOOT/BOOTX64.EFI" ]; then
                echo "Copying EFI boot files..."
                cp -r "${TEMP_DIR}/EFI" "/data/httpboot/${version}/"
                
                # Keep official grub.cfg only under HTTP version path; do NOT copy into TFTP
                if [ -f "${TEMP_DIR}/EFI/BOOT/grub.cfg" ]; then
                    echo "Copying official GRUB config for ${version} to HTTP location only..."
                    cp "${TEMP_DIR}/EFI/BOOT/grub.cfg" "/data/httpboot/${version}/EFI/BOOT/grub.cfg"
                    chmod 644 "/data/httpboot/${version}/EFI/BOOT/grub.cfg"
                    chown www-data:www-data "/data/httpboot/${version}/EFI/BOOT/grub.cfg"
                else
                    echo "Warning: Official grub.cfg not found in archive"
                fi
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

            # Ensure installer.iso is present for GRUB loopback
            if [ -f "${TEMP_DIR}/installer.iso" ]; then
                echo "Copying installer.iso..."
                cp "${TEMP_DIR}/installer.iso" "/data/httpboot/${version}/installer.iso"
                chown www-data:www-data "/data/httpboot/${version}/installer.iso"
                chmod 644 "/data/httpboot/${version}/installer.iso"
            else
                echo "Warning: installer.iso not found in extracted archive for ${version}"
            fi

            # Clean up
            rm -rf "${TEMP_DIR}"
            rm "/data/downloads/netboot-${version}.tar"
            
            # Debug - show what files we have before rename
            echo "Initial files for version ${version}:"
            ls -laR "/data/httpboot/${version}/" || echo "Failed to list directory"

            # Rename rootfs.img if it exists
            [ -f "/data/httpboot/${version}/rootfs.img" ] && mv "/data/httpboot/${version}/rootfs.img" "/data/httpboot/${version}/rootfs_installer.img"
            
            # Ensure permissions
            chown -R www-data:www-data "/data/httpboot/${version}"
            find "/data/httpboot/${version}" -type f -exec chmod 644 {} \;
            find "/data/httpboot/${version}" -type d -exec chmod 755 {} \;

            echo "Verifying file structure after permission updates:"
            echo "Files for version ${version}:"
            ls -laR "/data/httpboot/${version}/" || echo "Failed to list directory"

            # Check for BOOTX64.EFI and handle ISO if needed
            if [ ! -f "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI" ] && [ -f "/data/httpboot/${version}/installer.iso" ]; then
                echo "BOOTX64.EFI not found but installer.iso exists. Attempting extraction..."
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
echo "Final file structure verification for ${version}:"
if [ -f "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI" ]; then
    echo "✓ BOOTX64.EFI is present and accessible"
    ls -l "/data/httpboot/${version}/EFI/BOOT/BOOTX64.EFI"
else
    echo "✗ WARNING: BOOTX64.EFI is missing!"
fi

# Verify installer.iso presence
if [ -f "/data/httpboot/${version}/installer.iso" ]; then
    echo "✓ installer.iso is present"
    ls -l "/data/httpboot/${version}/installer.iso"
else
    echo "✗ WARNING: installer.iso is missing — GRUB will drop to CLI"
fi
    
# Ensure all files are readable
find "/data/httpboot/${version}" -type f -exec sh -c 'if ! su -s /bin/sh www-data -c "test -r {}" ; then echo "Warning: {} not readable by www-data"; fi' \;
    
# Test nginx config
echo "Testing nginx configuration..."
nginx -t
    
# Verify that nginx can access files
if ! su -s /bin/sh www-data -c "cat /data/httpboot/${version}/ipxe.efi.cfg" > /dev/null 2>&1; then
    echo "Warning: www-data cannot read ipxe.efi.cfg"
else
    echo "✓ www-data can read ipxe.efi.cfg"
fi
            
            # Set proper permissions for extracted files
            chown -R www-data:www-data "/data/httpboot/${version}"
            find "/data/httpboot/${version}" -type f -exec chmod 644 {} \;
            find "/data/httpboot/${version}" -type d -exec chmod 755 {} \;
        else
            echo "Version ${version} found in cache"
        fi

        # Ensure required assets exist even for cached versions
        ensure_version_assets "${version}"
        
        # Let GRUB use its default/embedded configuration
        echo "Using default GRUB configuration for version ${version}..."

        # Set up first version as default
        if [ -z "$DEFAULT_VERSION" ]; then
            DEFAULT_VERSION=$version
            echo "Setting ${version} as default version"
            
            echo "Setting up TFTP boot files..."
            # Copy and configure TFTP boot files
            if [ -f "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" ]; then
                echo "Setting up UEFI TFTP boot file..."
                cp "/data/httpboot/${DEFAULT_VERSION}/ipxe.efi" /tftpboot/ipxe.efi
chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} /tftpboot/ipxe.efi
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

            fi
            
            # Verify latest directory structure
            echo "Verifying latest directory structure:"
            VERIFY_ERRORS=0
            
            # Check required files and permissions
            for file in \
                "EFI/BOOT/BOOTX64.EFI" \
                "ipxe.efi.cfg" \
                "ipxe.efi" \
                "installer.iso" \
                "kernel" \
                "initrd.img"; do
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
            
            # Check optional files (no errors counted)
            for file in "ucode.img" "rootfs_installer.img"; do
                if [ -f "/data/httpboot/latest/${file}" ]; then
                    echo "✓ ${file} is present"
                    if su -s /bin/sh www-data -c "test -r /data/httpboot/latest/${file}"; then
                        echo "✓ ${file} is readable by www-data"
                    else
                        echo "✗ WARNING: ${file} is not readable by www-data"
                    fi
                else
                    echo "✗ WARNING: ${file} is missing"
                fi
            done
            
            # Check directory permissions
            if [ ! -x "/data/httpboot/latest" ] || [ ! -x "/data/httpboot/latest/EFI" ] || [ ! -x "/data/httpboot/latest/EFI/BOOT" ]; then
                echo "✗ WARNING: One or more directories are not executable"
                VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
            fi
            
            # Report verification results
            if [ "$VERIFY_ERRORS" -eq 0 ]; then
                echo "✓ Latest directory verification completed successfully"
            else
                echo "✗ Latest directory verification completed with ${VERIFY_ERRORS} errors"
            fi


        # Generate iPXE configuration from template
        echo "Configuring ipxe.efi.cfg for version ${version}..."
        
        # Use sed directly for reliable variable substitution
        sed "s/{{SERVER_IP}}/${SERVER_IP}/g; s/{{VERSION}}/${version}/g" \
            "/config/ipxe.efi.cfg.template" > "/data/httpboot/${version}/ipxe.efi.cfg"
        
        # Set permissions
        chmod 644 "/data/httpboot/${version}/ipxe.efi.cfg"
        chown www-data:www-data "/data/httpboot/${version}/ipxe.efi.cfg"

        # Verify template processing
        echo "Verifying URL injection..."
        if grep -q "set url http://${SERVER_IP}/${version}/" "/data/httpboot/${version}/ipxe.efi.cfg"; then
            echo "URL successfully injected for version ${version}"
        else
            echo "WARNING: Boot URL variable injection may have failed"
            echo "Expected: 'set url http://${SERVER_IP}/${version}/'"
        fi

        # Generate per-version GRUB HTTP prelude that sets env and chains into official config
        echo "Generating GRUB HTTP prelude for version ${version}..."
        mkdir -p "/data/httpboot/${version}/EFI/BOOT"
        sed -e "s/{{VERSION}}/${version}/g" -e "s/{{SERVER_IP}}/${SERVER_IP}/g" \
            "/config/grub_commands.cfg.template" > "/data/httpboot/${version}/EFI/BOOT/grub_pre.cfg"
        chmod 644 "/data/httpboot/${version}/EFI/BOOT/grub_pre.cfg"
        chown www-data:www-data "/data/httpboot/${version}/EFI/BOOT/grub_pre.cfg"

        # Build a standalone GRUB EFI with embedded HTTP prelude to avoid PXE next-server in proxy mode
        if command -v grub-mkstandalone >/dev/null 2>&1; then
            echo "Building embedded GRUB HTTP EFI for ${version}..."
            EMBED_CFG="/tmp/grub-embedded-${version}.cfg"
            cat > "$EMBED_CFG" <<EOF
insmod http
insmod test
set url=http://${SERVER_IP}/${version}/
export url
set isnetboot=true
export isnetboot
unset pxe_default_server
unset net_default_server
set cmddevice=http,${SERVER_IP}
set cmdpath=(http,${SERVER_IP})/${version}/
export cmddevice
export cmdpath
if configfile (http,${SERVER_IP})/${version}/EFI/BOOT/grub.cfg; then
    true
elif configfile (http,${SERVER_IP})/${version}/EFI/BOOT/grub_include.cfg; then
    true
else
    echo 'ERROR: HTTP GRUB config not found'
    sleep 5
fi
EOF
            if grub-mkstandalone -O x86_64-efi \
                -d /usr/lib/grub/x86_64-efi \
                -o "/data/httpboot/${version}/EFI/BOOT/GRUBX64_HTTP.EFI" \
                --modules="http efinet normal linux linuxefi tftp configfile search search_label search_fs_uuid test" \
                "boot/grub/grub.cfg=$EMBED_CFG" >/dev/null 2>&1; then
                if [ -s "/data/httpboot/${version}/EFI/BOOT/GRUBX64_HTTP.EFI" ]; then
                    chown www-data:www-data "/data/httpboot/${version}/EFI/BOOT/GRUBX64_HTTP.EFI"
                    chmod 644 "/data/httpboot/${version}/EFI/BOOT/GRUBX64_HTTP.EFI"
                    echo "✓ Built GRUBX64_HTTP.EFI for ${version}"
                else
                    echo "Warning: Built GRUBX64_HTTP.EFI for ${version} is empty/invalid; removing"
                    rm -f "/data/httpboot/${version}/EFI/BOOT/GRUBX64_HTTP.EFI"
                fi
            else
                echo "Warning: grub-mkstandalone failed; continuing without embedded GRUB for ${version}"
            fi
            rm -f "$EMBED_CFG" || true
        else
            echo "Warning: grub-mkstandalone not available; skipping embedded GRUB build for ${version}"
        fi

    done
    IFS=$OLD_IFS

    # Create TFTP GRUB bootstrap menu that switches to per-version HTTP configs
    echo "Creating TFTP GRUB bootstrap menu..."
    mkdir -p "/tftpboot/EFI/BOOT"

    # Determine default version (first in list)
    DEFAULT_VERSION=$(echo "${EVE_VERSIONS}" | awk -F',' '{print $1}')

    # Build an embedded TFTP GRUB image with HTTP menu across versions
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        echo "Building embedded TFTP GRUB (BOOTX64.EFI) with HTTP menu..."
        EMBED_TFTP="/tmp/grub-embedded-tftp.cfg"
        {
            echo "insmod http"
            echo "insmod test"
            echo "set default=0"
            echo "set timeout=${BOOT_MENU_TIMEOUT}"
        } > "$EMBED_TFTP"

        OLD_IFS2=$IFS
        IFS=','
        for v in ${EVE_VERSIONS}; do
            cat >> "$EMBED_TFTP" <<EOF
menuentry 'EVE-OS ${v}' {
    echo 'Chainloading vendor GRUB over HTTP for ${v}...'
    insmod chain
    chainloader (http,${SERVER_IP})/${v}/EFI/BOOT/BOOTX64.EFI
    boot
}
EOF
        done
        IFS=$OLD_IFS2

        if grub-mkstandalone -O x86_64-efi \
            -o "/tftpboot/EFI/BOOT/BOOTX64.EFI" \
            --modules="http efinet normal linux linuxefi tftp configfile search search_label search_fs_uuid test" \
            "boot/grub/grub.cfg=$EMBED_TFTP" >/dev/null 2>&1; then
chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} "/tftpboot/EFI/BOOT/BOOTX64.EFI"
            chmod 644 "/tftpboot/EFI/BOOT/BOOTX64.EFI"
            echo "✓ Embedded TFTP GRUB built successfully"
        else
            echo "Warning: grub-mkstandalone failed for TFTP GRUB; falling back to vendor BOOTX64.EFI + TFTP grub.cfg"
            # Fallback to copying vendor BOOTX64.EFI
            if [ -f "/data/httpboot/${DEFAULT_VERSION}/EFI/BOOT/BOOTX64.EFI" ]; then
                echo "Copying GRUB EFI from ${DEFAULT_VERSION} to TFTP (fallback)..."
                cp "/data/httpboot/${DEFAULT_VERSION}/EFI/BOOT/BOOTX64.EFI" "/tftpboot/EFI/BOOT/BOOTX64.EFI"
chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} "/tftpboot/EFI/BOOT/BOOTX64.EFI"
                chmod 644 "/tftpboot/EFI/BOOT/BOOTX64.EFI"
            else
                echo "WARNING: BOOTX64.EFI not found under ${DEFAULT_VERSION}; GRUB handoff may fail"
            fi
        fi
        rm -f "$EMBED_TFTP" || true
    else
        echo "Warning: grub-mkstandalone not available; copying vendor BOOTX64.EFI and generating TFTP grub.cfg"
        if [ -f "/data/httpboot/${DEFAULT_VERSION}/EFI/BOOT/BOOTX64.EFI" ]; then
            echo "Copying GRUB EFI from ${DEFAULT_VERSION} to TFTP..."
            cp "/data/httpboot/${DEFAULT_VERSION}/EFI/BOOT/BOOTX64.EFI" "/tftpboot/EFI/BOOT/BOOTX64.EFI"
chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} "/tftpboot/EFI/BOOT/BOOTX64.EFI"
            chmod 644 "/tftpboot/EFI/BOOT/BOOTX64.EFI"
        else
            echo "WARNING: BOOTX64.EFI not found under ${DEFAULT_VERSION}; GRUB handoff may fail"
        fi
    fi

    # Always generate a TFTP grub.cfg as a backup (used if vendor BOOTX64.EFI searches for it)
    GRUB_TFTP_CFG="/tftpboot/EFI/BOOT/grub.cfg"
    echo "Generating ${GRUB_TFTP_CFG}..."
    {
        echo "# Generated by ipxe-server entrypoint"
        echo "set timeout=${BOOT_MENU_TIMEOUT}"
        echo "set default=0"
        echo "insmod http"
        echo "insmod test"
    } > "${GRUB_TFTP_CFG}"

    OLD_IFS2=$IFS
    IFS=','
    for v in ${EVE_VERSIONS}; do
        cat >> "${GRUB_TFTP_CFG}" <<EOF
menuentry 'EVE-OS ${v}' {
    echo 'Chainloading vendor GRUB over HTTP for ${v}...'
    insmod chain
    chainloader (http,${SERVER_IP})/${v}/EFI/BOOT/BOOTX64.EFI
    boot
}
EOF
    done
    IFS=$OLD_IFS2

chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} "${GRUB_TFTP_CFG}"
    chmod 644 "${GRUB_TFTP_CFG}"
    echo "✓ TFTP GRUB bootstrap menu generated"

    # Also build a single embedded GRUB HTTP menu covering all versions
    if command -v grub-mkstandalone >/dev/null 2>&1; then
        echo "Building embedded GRUB HTTP menu for all versions..."
        mkdir -p "/data/httpboot/EFI/BOOT"
        EMBED_ALL="/tmp/grub-embedded-all.cfg"
        {
            echo "insmod http"
            echo "insmod test"
            echo "set default=0"
            echo "set timeout=${BOOT_MENU_TIMEOUT}"
        } > "$EMBED_ALL"

        OLD_IFS3=$IFS
        IFS=','
        for v in ${EVE_VERSIONS}; do
            cat >> "$EMBED_ALL" <<EOF
menuentry 'EVE-OS ${v}' {
    echo 'Switching to HTTP configuration for ${v}...'
    set url=http://${SERVER_IP}/${v}/
    export url
    set isnetboot=true
    export isnetboot
    unset pxe_default_server
    unset net_default_server
    set cmddevice=http,${SERVER_IP}
    set cmdpath=(http,${SERVER_IP})/${v}/
    export cmddevice
    export cmdpath
    if configfile (http,${SERVER_IP})/${v}/EFI/BOOT/grub.cfg; then
        true
    elif configfile (http,${SERVER_IP})/${v}/EFI/BOOT/grub_include.cfg; then
        true
    else
        echo 'ERROR: HTTP GRUB config not found for ${v}'
        sleep 5
    fi
}
EOF
        done
        IFS=$OLD_IFS3

        if grub-mkstandalone -O x86_64-efi \
            -d /usr/lib/grub/x86_64-efi \
            -o "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI" \
            --modules="http efinet normal linux linuxefi tftp configfile search search_label search_fs_uuid test" \
            "boot/grub/grub.cfg=$EMBED_ALL" >/dev/null 2>&1; then
            if [ -s "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI" ]; then
                chown www-data:www-data "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI"
                chmod 644 "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI"
                echo "✓ Built GRUBX64_HTTP.EFI (HTTP menu across versions)"
            else
                echo "Warning: HTTP GRUB output invalid; removing to avoid iPXE Exec format errors"
                rm -f "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI"
            fi
        else
            echo "Warning: grub-mkstandalone failed; continuing without embedded GRUB menu"
        fi
        rm -f "$EMBED_ALL" || true
    else
        echo "Warning: grub-mkstandalone not available; skipping embedded GRUB menu build"
    fi
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
find /tftpboot -type f -exec chown ${DNSMASQ_USER}:${DNSMASQ_GROUP} {} \;
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

# === Main Script ===
echo "Starting EVE-OS iPXE Server..."

# 1. Validate environment
validate_environment

# 2. Resolve dnsmasq ownership and set up EVE-OS versions and assets
# Determine a safe owner:group for TFTP files in Debian-based image
DNSMASQ_USER=${DNSMASQ_USER:-dnsmasq}
if ! id -u "$DNSMASQ_USER" >/dev/null 2>&1; then
    DNSMASQ_USER=nobody
fi
DNSMASQ_GROUP=${DNSMASQ_GROUP:-dnsmasq}
if command -v getent >/dev/null 2>&1; then
    if ! getent group "$DNSMASQ_GROUP" >/dev/null 2>&1; then
        if getent group nogroup >/dev/null 2>&1; then DNSMASQ_GROUP=nogroup; else DNSMASQ_GROUP=$DNSMASQ_USER; fi
    fi
else
    if ! grep -q "^${DNSMASQ_GROUP}:" /etc/group 2>/dev/null; then
        if grep -q "^nogroup:" /etc/group 2>/dev/null; then DNSMASQ_GROUP=nogroup; else DNSMASQ_GROUP=$DNSMASQ_USER; fi
    fi
fi
echo "Using dnsmasq file owner: ${DNSMASQ_USER}:${DNSMASQ_GROUP}"

setup_eve_versions

# Function to generate minimal iPXE stub (no menu)
generate_boot_menu() {
    echo "Generating minimal iPXE stub..."

    cat > /data/httpboot/boot.ipxe <<'EOF'
#!ipxe

:retry_dhcp
echo Configuring network...
dhcp || goto retry_dhcp

# Directly chain to TFTP GRUB for reliable proxy-mode operation
chain tftp://{{SERVER_IP}}/EFI/BOOT/BOOTX64.EFI || goto fail
boot || goto fail

:fail
echo Boot failed (errno=${errno}). Dropping to iPXE shell.
shell
EOF

    chmod 644 /data/httpboot/boot.ipxe
    chown www-data:www-data /data/httpboot/boot.ipxe

    # Inject SERVER_IP into the stub (preserve iPXE variables)
    sed -i "s|{{SERVER_IP}}|${SERVER_IP}|g" /data/httpboot/boot.ipxe
}

# Generate iPXE boot menu
generate_boot_menu

# 4. Configure services and boot files
# Generate nginx configuration first so HTTP serves /data/httpboot
generate_nginx_conf
generate_autoexec
generate_dnsmasq_conf

# 5. Download bootloaders
echo "Checking bootloaders..."
if [ ! -f "/tftpboot/undionly.kpxe" ]; then
    echo "Downloading undionly.kpxe..."
    curl -L -o /tftpboot/undionly.kpxe "https://boot.ipxe.org/undionly.kpxe"
fi

# Ensure a small UEFI NBP is available to avoid PXE-E05 on some firmware
if [ ! -f "/tftpboot/snponly.efi" ]; then
    echo "Downloading snponly.efi..."
    curl -L -o /tftpboot/snponly.efi "https://boot.ipxe.org/snponly.efi"
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

# Ensure we have at least one GRUB path available
if [ -f "/data/httpboot/EFI/BOOT/GRUBX64_HTTP.EFI" ]; then
    echo "✓ HTTP GRUB image present"
else
    echo "HTTP GRUB image not found; verifying TFTP fallback..."
    if [ ! -f "/tftpboot/EFI/BOOT/BOOTX64.EFI" ] || [ ! -f "/tftpboot/EFI/BOOT/grub.cfg" ]; then
        echo "ERROR: Neither HTTP GRUB nor TFTP GRUB fallback is available"
        exit 1
    fi
fi

# Verify boot.ipxe content (minimal stub)
echo "Verifying boot.ipxe content..."
if ! grep -q "^#!ipxe" /data/httpboot/boot.ipxe; then
    echo "ERROR: boot.ipxe missing #!ipxe header"
    cat /data/httpboot/boot.ipxe
    exit 1
fi
if ! grep -q "imgfetch --name grubx64_http\.efi" /data/httpboot/boot.ipxe && \
   ! grep -q "chain tftp://" /data/httpboot/boot.ipxe; then
    echo "ERROR: boot.ipxe missing expected GRUB boot commands"
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
