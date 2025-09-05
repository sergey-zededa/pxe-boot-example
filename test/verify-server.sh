#!/bin/bash

echo "Verifying iPXE server setup..."

# Check if container is running
if ! docker ps | grep -q ipxe-server; then
    echo "Error: iPXE server container is not running"
    exit 1
fi

# Check if HTTP server is responding
echo -n "Testing HTTP server... "
if docker run --rm --network ipxe-test appropriate/curl -s -f http://192.168.53.2/boot.ipxe > /dev/null; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi

# Check if required files exist
echo "Checking required files:"
for file in boot.ipxe ipxe.efi.cfg; do
    echo -n "  $file... "
    if docker exec ipxe-server test -f "/data/httpboot/$file"; then
        echo "OK"
    else
        echo "MISSING"
        exit 1
    fi
done

# Check dnsmasq configuration
echo -n "Checking dnsmasq configuration... "
if docker exec ipxe-server cat /etc/dnsmasq.conf | grep -q "dhcp-range=192.168.53.10,192.168.53.50"; then
    echo "OK"
else
    echo "INVALID"
    exit 1
fi

echo "Server verification completed successfully"
