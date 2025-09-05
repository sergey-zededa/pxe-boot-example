# Testing EVE-OS iPXE Server

This guide explains how to test the iPXE server in different environments, including local development on macOS.

## Testing on macOS with Docker Desktop

While the iPXE server is designed to run on Linux with direct network access, you can test most functionality locally on macOS using the following approaches:

### 1. QEMU-based Full Testing

This approach allows testing the complete boot sequence using QEMU:

```bash
# Install prerequisites
brew install qemu ovmf

# Create test network and run server
docker network create --subnet=192.168.53.0/24 ipxe-test
docker run -d --name ipxe-server \
    --network ipxe-test --ip 192.168.53.2 \
    -v "$(pwd)/ipxe_data:/data" \
    -e EVE_VERSIONS="14.5.1-lts" \
    -e SERVER_IP="192.168.53.2" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="standalone" \
    -e DHCP_RANGE_START="192.168.53.10" \
    -e DHCP_RANGE_END="192.168.53.50" \
    -e DHCP_ROUTER="192.168.53.2" \
    -e LOG_LEVEL="debug" \
    ipxe-server:latest

# Run test client
qemu-system-x86_64 \
    -m 2048 \
    -nographic \
    -net nic,model=virtio,macaddr=52:54:00:12:34:56 \
    -net bridge,br=ipxe-test \
    -bios /usr/local/share/qemu/OVMF.fd
```

### 2. Component Testing

You can test individual components without full PXE boot:

#### Test HTTP Server
```bash
# Run server with port forwarding
docker run -d --name ipxe-server \
    -p 80:80 \
    -v "$(pwd)/ipxe_data:/data" \
    -e EVE_VERSIONS="14.5.1-lts" \
    -e SERVER_IP="192.168.53.2" \
    -e LISTEN_INTERFACE="eth0" \
    ipxe-server:latest

# Test HTTP endpoints
curl http://localhost/boot.ipxe
curl http://localhost/14.5.1-lts/ipxe.efi.cfg
```

#### Test Configuration Generation
```bash
# Verify dnsmasq configuration
docker run --rm \
    -e EVE_VERSIONS="14.5.1-lts" \
    -e SERVER_IP="192.168.53.2" \
    -e LISTEN_INTERFACE="eth0" \
    ipxe-server:latest cat /etc/dnsmasq.conf

# Check file structure
docker run --rm \
    -e EVE_VERSIONS="14.5.1-lts" \
    -e SERVER_IP="192.168.53.2" \
    -e LISTEN_INTERFACE="eth0" \
    ipxe-server:latest ls -R /data/httpboot /tftpboot
```

### 3. Debugging Tips

1. Check server logs:
```bash
docker logs ipxe-server
```

2. Inspect generated files:
```bash
# Check boot menu
docker exec ipxe-server cat /data/httpboot/boot.ipxe

# Check version configuration
docker exec ipxe-server cat /data/httpboot/14.5.1-lts/ipxe.efi.cfg
```

3. Verify network settings:
```bash
# Check dnsmasq configuration
docker exec ipxe-server cat /etc/dnsmasq.conf

# Check network interfaces
docker exec ipxe-server ip addr
```

## Testing on Linux

For full functionality testing on Linux:

1. Use the standard docker run command from the main README
2. Monitor DHCP/TFTP traffic:
```bash
tcpdump -i eth0 'port 67 or port 68 or port 69'
```
3. Test with real PXE clients on the network

## Automated Testing

For automated testing in CI/CD:

1. Component tests:
   - Configuration generation
   - File structure verification
   - HTTP endpoint testing

2. Integration tests:
   - QEMU-based boot testing
   - Network protocol verification

See the `test/` directory for test scripts and utilities.
