#!/bin/bash
set -e

# Default values
NETWORK_NAME="ipxe-test"
SERVER_IP="192.168.53.2"
NETWORK_CIDR="192.168.53.0/24"
EVE_VERSION="14.5.1-lts"

# Stop any existing containers and remove network
echo "Cleaning up existing resources..."
docker stop ipxe-server 2>/dev/null || true
docker rm ipxe-server 2>/dev/null || true
docker network rm $NETWORK_NAME 2>/dev/null || true

# Create Docker network with custom subnet and gateway
echo "Creating Docker network: $NETWORK_NAME"
docker network create \
    --subnet=$NETWORK_CIDR \
$NETWORK_NAME

# Start iPXE server
echo "Starting iPXE server..."
docker run -d --name ipxe-server \
    --network $NETWORK_NAME --ip $SERVER_IP \
    --cap-add=NET_ADMIN \
    -v "$(pwd)/ipxe_data:/data" \
    -e EVE_VERSIONS="$EVE_VERSION" \
    -e SERVER_IP="$SERVER_IP" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="standalone" \
    -e DHCP_RANGE_START="192.168.53.10" \
    -e DHCP_RANGE_END="192.168.53.50" \
    -e DHCP_ROUTER="$SERVER_IP" \
    -e LOG_LEVEL="debug" \
    ipxe-server:latest

# Wait for server to initialize
echo "Waiting for iPXE server to initialize..."
sleep 10

# Set up QEMU networking
echo "Setting up QEMU networking..."
QEMU_NET_OPTS="-netdev user,id=net0,net=192.168.53.0/24,dhcpstart=192.168.53.10,host=192.168.53.2,ipv6=off \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56"

# Run QEMU with UEFI firmware and PXE boot
echo "Starting QEMU test client..."
qemu-system-x86_64 \
    -name ipxe-test-client \
    -machine type=q35,accel=hvf \
    -cpu host \
    -m 2048 \
    -nographic \
-bios /opt/homebrew/share/qemu/edk2-x86_64-secure-code.fd \
    $QEMU_NET_OPTS

# Cleanup
echo "Cleaning up..."
docker stop ipxe-server
docker rm ipxe-server
docker network rm $NETWORK_NAME
