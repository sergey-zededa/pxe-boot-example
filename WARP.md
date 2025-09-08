# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

This project implements a minimalistic, easily deployable, self-contained Docker-based iPXE server for network booting and installing multiple versions of EVE-OS. The server supports multi-version EVE-OS deployments with features like an interactive boot menu, timed default boot, and persistent caching.

## Implementation Status

The project is currently undergoing configuration alignment with the verified working configuration documented in `/Users/sseper/Desktop/Projects/iPXE/CONFIGURATION.md`. The implementation plan is tracked in `IMPLEMENTATION.md` and consists of three phases:

1. Core Infrastructure (In Progress)
   - Service configurations (nginx, dnsmasq)
   - Directory structure and permissions
   - Container setup and configuration

2. Boot Configuration (Planned)
   - iPXE script templates
   - Version-specific configurations
   - Boot menu generation

3. Environment and Testing (Planned)
   - Environment variable handling
   - Testing implementation
   - Documentation updates

All development work must strictly follow the implementation checklist in `IMPLEMENTATION.md`, which serves as the source of truth for required changes and their status.

## Architecture

The system consists of several key components:

1. Docker Container Service
   - Primary service that runs both HTTP and DHCP/TFTP services
   - Uses persistent volume mapping for caching EVE-OS images
   - Configurable via environment variables

2. Network Services
   - DHCP Server (dnsmasq) - operates in either proxy or standalone mode
   - HTTP Server (nginx) - serves boot configurations and EVE-OS images
   - TFTP Server (dnsmasq) - serves iPXE binaries

3. File Structure
   - `/data/httpboot/` - HTTP-served files including boot menu and EVE-OS images
   - `/tftpboot/` - TFTP-served iPXE binaries
   - `/etc/dnsmasq.conf` - Dynamic DHCP/TFTP configuration

## Development Commands

### Building
```bash
# Build the Docker image
docker build -t ipxe-server:latest .

# Force rebuild without cache
docker build --no-cache -t ipxe-server:latest .
```

### Testing

1. Full QEMU-based Testing (macOS):
```bash
# Run the full QEMU test suite
./test/run-qemu-test.sh
```

2. Component Testing:
```bash
# Verify server configuration and setup
./test/verify-server.sh

# Test HTTP endpoints
curl http://localhost/boot.ipxe
curl http://localhost/[version]/ipxe.efi.cfg
```

3. Debug Commands:
```bash
# Check server logs
docker logs ipxe-server

# Inspect boot menu
docker exec ipxe-server cat /data/httpboot/boot.ipxe

# Verify dnsmasq configuration
docker exec ipxe-server cat /etc/dnsmasq.conf

# Check network interfaces
docker exec ipxe-server ip addr
```

### Running the Server

Basic configuration:
```bash
docker run --rm -it --net=host --privileged \
   -v ./ipxe_data:/data \
   -e EVE_VERSIONS="14.5.1-lts,13.10.0" \
   -e SERVER_IP="192.168.1.50" \
   -e DHCP_MODE="proxy" \
   -e LOG_LEVEL="debug" \
   ipxe-server:latest
```

## Environment Configuration

Critical environment variables:
- `EVE_VERSIONS`: Required. Comma-separated list of EVE-OS versions
- `SERVER_IP`: Required. Host IP address
- `DHCP_MODE`: Either "proxy" or "standalone"
- `LOG_LEVEL`: Set to "debug" for verbose logging
- `BOOT_MENU_TIMEOUT`: Boot menu timeout in seconds (default: 15)

DHCP-specific variables:
- For proxy mode: `PRIMARY_DHCP_IP`
- For standalone mode: `DHCP_RANGE_START`, `DHCP_RANGE_END`, `DHCP_SUBNET_MASK`

## Network Prerequisites

The server requires:
1. Network access with appropriate permissions (--net=host)
2. Elevated privileges for network services (--privileged)
3. Persistent storage for caching (-v ./ipxe_data:/data)
