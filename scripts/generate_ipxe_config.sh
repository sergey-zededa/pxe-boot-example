#!/bin/bash
# Deprecated helper kept for reference; not used in production entrypoint.
# This script is superseded by entrypoint.sh template processing.

# Function to generate version-specific configuration
generate_version_config() {
    local version=$1
    echo "Generating iPXE config for version ${version}..."
    
    cat > "/data/httpboot/${version}/ipxe.efi.cfg" <<EOF
#!ipxe

# Debugging disabled by default

# Force our server address
set next-server ${SERVER_IP}
set boot-url http://\${next-server}/${version}

# Verify network configuration
echo iPXE boot starting...
echo Network Status:
echo IP: \${net0/ip}
echo Netmask: \${net0/netmask}
echo Gateway: \${net0/gateway}
echo DNS: \${net0/dns}
echo Server: \${next-server}
echo Boot URL: \${boot-url}

# Detect architecture and platform
echo Architecture: \${buildarch}
echo Platform: \${platform}
echo Manufacturer: \${smbios/manufacturer}

# Set boot parameters
set console console=ttyS0,115200n8 console=tty0
set eve_args eve_soft_serial=\${mac:hexhyp} eve_reboot_after_install getty
set installer_args root=/initrd.image find_boot=netboot overlaytmpfs fastboot

# Hardware-specific console settings
iseq \${smbios/manufacturer} Huawei && set console console=ttyAMA0,115200n8 ||
iseq \${smbios/manufacturer} Huawei && set platform_tweaks pcie_aspm=off pci=pcie_bus_perf ||
iseq \${smbios/manufacturer} Supermicro && set console console=ttyS1,115200n8 ||
iseq \${smbios/manufacturer} QEMU && set console console=hvc0 console=ttyS0 ||

# Chain to appropriate bootloader
:check_arch
iseq \${buildarch} x86_64 && goto boot_x86_64 ||
iseq \${buildarch} arm64 && goto boot_arm64 ||
iseq \${buildarch} riscv64 && goto boot_riscv64 ||
goto arch_error

:boot_x86_64
echo Booting x86_64 EVE-OS...
chain \${boot-url}/EFI/BOOT/BOOTX64.EFI || goto error

:boot_arm64
echo Booting arm64 EVE-OS...
chain \${boot-url}/EFI/BOOT/BOOTAA64.EFI || goto error

:boot_riscv64
echo Booting RISC-V 64-bit EVE-OS...
chain \${boot-url}/EFI/BOOT/BOOTRISCV64.EFI || goto error

:arch_error
echo Error: Unsupported architecture \${buildarch}
echo Supported architectures: x86_64, arm64, riscv64
prompt Press any key to retry...
goto check_arch

:error
echo Boot failed! Error: \${errno}
echo Message: \${errstr}
echo URL attempted: \${boot-url}/EFI/BOOT/BOOT\${buildarch}.EFI
echo Common error codes:
echo 1 - File not found
echo 2 - Access denied
echo 3 - Disk error
echo 4 - Network error
prompt Press any key to retry...
goto check_arch
EOF

    chmod 644 "/data/httpboot/${version}/ipxe.efi.cfg"
    chown www-data:www-data "/data/httpboot/${version}/ipxe.efi.cfg"
    echo "Generated iPXE config for version ${version}"
}

# Function to generate boot menu
generate_boot_menu() {
    echo "Generating iPXE boot menu..."
    
    # Create initial menu file
    cat > /data/httpboot/boot.ipxe <<EOF
#!ipxe

# Enable debugging
set debug all
set debug dhcp,net

# Configure network settings
:retry_dhcp
echo Configuring network...
dhcp || goto retry_dhcp_fail

echo Network configured successfully:
echo IP: \${net0/ip}
echo Netmask: \${net0/netmask}
echo Gateway: \${net0/gateway}
echo DNS: \${net0/dns}

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
    cat >> /data/httpboot/boot.ipxe <<EOF

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
item --gap Client IP: \${net0/ip}
item --gap Architecture: \${buildarch}

choose --timeout ${BOOT_MENU_TIMEOUT}000 --default eve_1 selected || goto menu_error
goto \${selected}

:retry_dhcp_fail
echo DHCP configuration failed. Retrying in 3 seconds...
sleep 3
goto retry_dhcp

:menu_error
echo Menu selection failed
echo Error: \${errno}
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
goto retry_dhcp
EOF

    # Set permissions
    chmod 644 /data/httpboot/boot.ipxe
    chown www-data:www-data /data/httpboot/boot.ipxe
    
    echo "Boot menu generated successfully"
}
