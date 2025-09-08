#!/bin/bash

# Enhanced server validation script
set -e

echo "Starting server validation..."

# 1. Verify network configuration
echo "Checking network configuration..."
if ! ip addr show "$LISTEN_INTERFACE" &>/dev/null; then
    echo "ERROR: Interface $LISTEN_INTERFACE not found"
    exit 1
fi

if ! ip addr show "$LISTEN_INTERFACE" | grep -q "$SERVER_IP"; then
    echo "ERROR: IP $SERVER_IP not configured on $LISTEN_INTERFACE"
    exit 1
fi

# 2. Check HTTP port availability
if netstat -ln | grep -q ':80.*LISTEN'; then
    echo "ERROR: Port 80 is already in use"
    exit 1
fi

# 3. Verify critical files and permissions
echo "Checking file structure..."
CRITICAL_FILES=(
    "/data/httpboot/boot.ipxe"
    "/data/httpboot/latest/ipxe.efi"
    "/data/httpboot/latest/ipxe.efi.cfg"
    "/data/httpboot/latest/EFI/BOOT/BOOTX64.EFI"
)

for file in "${CRITICAL_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Critical file missing: $file"
        exit 1
    fi

    if ! sudo -u www-data test -r "$file"; then
        echo "ERROR: www-data cannot read: $file"
        exit 1
    fi
done

# 4. Verify boot.ipxe content
echo "Verifying boot.ipxe content..."
if ! grep -q "chain --autofree" /data/httpboot/boot.ipxe; then
    echo "ERROR: boot.ipxe appears to be invalid"
    echo "Content:"
    cat /data/httpboot/boot.ipxe
    exit 1
fi

# 5. Test nginx configuration
echo "Testing nginx configuration..."
if ! nginx -t; then
    echo "ERROR: Invalid nginx configuration"
    exit 1
fi

# 6. Verify dnsmasq configuration
echo "Verifying dnsmasq configuration..."
if ! dnsmasq --test; then
    echo "ERROR: Invalid dnsmasq configuration"
    exit 1
fi

# 7. Print server state
echo -e "\nServer State Summary:"
echo "======================="
echo "Interface: $LISTEN_INTERFACE"
echo "Server IP: $SERVER_IP"
echo "DHCP Mode: $DHCP_MODE"
echo "EVE Versions: $EVE_VERSIONS"
echo "Document Root Content:"
ls -la /data/httpboot/
echo -e "\nLatest Version Content:"
ls -la /data/httpboot/latest/
echo -e "\nboot.ipxe content:"
cat /data/httpboot/boot.ipxe
echo -e "\nipxe.efi.cfg content:"
cat /data/httpboot/latest/ipxe.efi.cfg

echo -e "\nAll validation checks passed!"
