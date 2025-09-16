# EVE-OS iPXE Server

A minimalistic, easily deployable, self-contained Docker-based iPXE server for network booting and installing multiple versions of EVE-OS.

## Features

- **Multi-Version Support**: Serve multiple EVE-OS versions from a single container
- **iPXE Boot Menu**: Interactive menu with automatic timeout and version selection
- **Persistent Caching**: Cache EVE-OS images using Docker volumes
- **Flexible DHCP**: Support for both standalone DHCP server and DHCP proxy modes
- **Hardware Detection**: Automatic console and platform-specific configuration
- **Comprehensive Error Handling**: Detailed error messages and automatic recovery
- **Robust HTTP Handling**: Case-insensitive handling for .EFI/.IPXE/.CFG to satisfy UEFI HTTP Boot requirements

## Quick Start

1. Build the container:
```sh
docker build -t ipxe-server:latest .
```

2. Create a data directory:
```sh
mkdir -p ipxe_data
```

3. Run in standalone DHCP mode:
```sh
docker run -d --net=host --privileged \
    -v "$PWD/ipxe_data:/data" \
    -e EVE_VERSIONS="14.5.1-lts,13.10.0" \
    -e SERVER_IP="192.168.1.50" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="standalone" \
    -e DHCP_RANGE_START="192.168.1.100" \
    -e DHCP_RANGE_END="192.168.1.150" \
    -e DHCP_ROUTER="192.168.1.1" \
    ipxe-server:latest
```

## Configuration

### Required Environment Variables

| Variable | Description | Example |
|----------|-------------|----------|
| `EVE_VERSIONS` | Comma-separated list of EVE-OS versions | `"14.5.1-lts,13.10.0"` |
| `SERVER_IP` | IP address of the server | `"192.168.1.50"` |
| `LISTEN_INTERFACE` | Network interface to listen on | `"eth0"` |

### DHCP Mode Configuration

| Variable | Description | Default | Example |
|----------|-------------|---------|----------|
| `DHCP_MODE` | Either `proxy` or `standalone` | `proxy` | `standalone` |

#### Standalone Mode Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|----------|
| `DHCP_RANGE_START` | Start of IP range | Required | `192.168.1.100` |
| `DHCP_RANGE_END` | End of IP range | Required | `192.168.1.150` |
| `DHCP_ROUTER` | Gateway IP address | Required | `192.168.1.1` |
| `DHCP_SUBNET_MASK` | Subnet mask | `255.255.255.0` | `255.255.255.0` |

#### Proxy Mode Variables

| Variable | Description | Example |
|----------|-------------|----------|
| `PRIMARY_DHCP_IP` | IP of primary DHCP server | `192.168.1.1` |

### Optional Configuration

| Variable | Description | Default | Example |
|----------|-------------|---------|----------|
| `BOOT_MENU_TIMEOUT` | Menu timeout in seconds | `15` | `30` |
| `LOG_LEVEL` | Logging verbosity | `info` | `debug` |
| `DHCP_DOMAIN_NAME` | Domain for DHCP clients | | `pxeboot.local` |
| `DHCP_BROADCAST_ADDRESS` | Network broadcast address | | `192.168.1.255` |

## Volume Configuration

The container requires a persistent volume for caching EVE-OS images:

```sh
-v ./ipxe_data:/data
```

Directory structure:
```
/data/
├── httpboot/              # HTTP-served files (www-data:www-data, 755)
│   ├── latest/           # Symlink to default version
│   ├── [version]/       # Version-specific files (755)
│   │   ├── kernel       # EVE-OS kernel (644)
│   │   ├── initrd.img   # Initial ramdisk (644)
│   │   └── ipxe.efi.cfg # Boot configuration (644)
│   └── boot.ipxe        # Boot menu (644)
└── tftpboot/            # TFTP-served files (dnsmasq:dnsmasq, 755)
    └── ipxe.efi         # iPXE bootloader (644)
```

## Testing

### Full Test Suite
```sh
./test/test-suite.sh
```

### Component Testing
```sh
# Verify server setup
./test/verify-server.sh

# Test HTTP endpoints
curl http://localhost/boot.ipxe
curl http://localhost/[version]/ipxe.efi.cfg
```

### Debug Commands
```sh
# Check server logs
docker logs ipxe-server

# Inspect configurations
docker exec ipxe-server cat /data/httpboot/boot.ipxe
docker exec ipxe-server cat /etc/dnsmasq.conf
```

## Troubleshooting

### Common Issues

1. **DHCP Conflicts**
   - In standalone mode, ensure no other DHCP servers are active on the network
   - In proxy mode, verify PRIMARY_DHCP_IP is correct
   - If the client chains to the wrong host, force SERVER_IP in iPXE scripts (already the default)

2. **Network Access**
   - Container needs --net=host and --privileged for network access
   - Verify SERVER_IP matches the host's IP address
   - Check LISTEN_INTERFACE is correct

3. **Boot Issues**
   - Enable debug logging with LOG_LEVEL=debug
   - Check dnsmasq logs for DHCP/TFTP issues
   - Verify file permissions in /data/httpboot and /tftpboot

### Error Messages

- `Invalid IP address format`: Check IP address variables follow correct format
- `DHCP configuration failed`: Verify network settings and DHCP mode
- `EVE-OS version not found`: Ensure EVE_VERSIONS contains valid versions
- `Permission denied`: Check volume mount and file permissions

