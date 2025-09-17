# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

This project implements a minimalistic, easily deployable, self-contained Docker-based iPXE server for network booting and installing multiple versions of EVE-OS. The server supports multi-version EVE-OS deployments with features like an interactive boot menu, timed default boot, and persistent caching.

## Implementation Status

The project has completed the core implementation and is now working correctly. Recent critical fixes have resolved PXE boot flow issues:

### Completed Fixes:
1. **GRUB Configuration Issue (Fixed)**: Fixed entrypoint.sh copy order to ensure official EVE-OS grub.cfg is served instead of diagnostic version
2. **Proxy DHCP Server IP Override (Fixed)**: Added critical DHCP options to force GRUB to use correct PXE server IP instead of primary DHCP server IP
3. **EFI Boot Chain**: iPXE → GRUB → EVE-OS installer flow is now working properly

### Critical Technical Details:
- **Primary Issue**: GRUB was receiving wrong server IP (192.168.0.1 from primary DHCP) instead of PXE server IP (192.168.0.4)
- **Root Cause**: Proxy DHCP configuration wasn't aggressive enough to override primary DHCP server settings
- **Solution**: Added `dhcp-option=tag:efi64,option:next-server,{{SERVER_IP}}` to force correct server IP

### Testing Status:
- **Local QEMU Testing**: Disabled due to macOS virtualization limitations
- **Remote Testing Required**: All validation must be done on actual network hardware
- **Verification Method**: Monitor dnsmasq/nginx logs to confirm GRUB loads grub.cfg from correct server

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

### Testing and Debugging

**CRITICAL**: Local QEMU testing is disabled due to macOS virtualization limitations. All testing must be performed remotely on actual network hardware.

1. Production Deployment Testing:
```bash
# Deploy to remote server and monitor logs
docker run --rm -it --net=host --privileged \
   -v ./ipxe_data:/data \
   -e EVE_VERSIONS="14.5.1-lts,13.10.0" \
   -e SERVER_IP="192.168.0.4" \
   -e DHCP_MODE="proxy" \
   -e PRIMARY_DHCP_IP="192.168.0.1" \
   -e LOG_LEVEL="debug" \
   ipxe-server:latest
```

2. Critical Debug Commands:
```bash
# Monitor PXE boot flow in real-time
docker logs -f ipxe-server

# Verify GRUB configuration is correct
docker exec ipxe-server cat /data/httpboot/14.5.1-lts/EFI/BOOT/grub.cfg

# Check dnsmasq proxy DHCP configuration
docker exec ipxe-server cat /etc/dnsmasq.conf | grep -A5 -B5 "next-server"

# Verify HTTP endpoints serve correct content
curl http://[SERVER_IP]/boot.ipxe
curl http://[SERVER_IP]/14.5.1-lts/ipxe.efi.cfg
curl -I http://[SERVER_IP]/14.5.1-lts/EFI/BOOT/grub.cfg

# Monitor network traffic during PXE boot
docker exec ipxe-server tcpdump -i any -n port 67 or port 68 or port 69
```

3. PXE Boot Flow Validation:
```bash
# Expected log sequence for successful boot:
# 1. DHCP discover/offer from primary DHCP (192.168.0.1)
# 2. Proxy DHCP offer from our server (192.168.0.4) with next-server override
# 3. TFTP request for snponly.efi from our server
# 4. HTTP request for boot.ipxe from our server
# 5. HTTP request for grub.cfg from our server (NOT from 192.168.0.1)
# 6. HTTP requests for installer ISO chunks from our server
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

### Critical Environment Variables:
- `EVE_VERSIONS`: **Required**. Comma-separated list of EVE-OS versions (e.g., "14.5.1-lts,13.10.0")
- `SERVER_IP`: **Required**. PXE server IP address (e.g., "192.168.0.4")
- `DHCP_MODE`: Either "proxy" or "standalone" (use "proxy" for existing DHCP networks)
- `LOG_LEVEL`: Set to "debug" for verbose logging during troubleshooting
- `BOOT_MENU_TIMEOUT`: Boot menu timeout in seconds (default: 15)

### Proxy DHCP Configuration (Most Common):
- `PRIMARY_DHCP_IP`: IP of existing DHCP server (e.g., "192.168.0.1")
- **Critical**: Server must override primary DHCP next-server to ensure GRUB uses correct IP

### Standalone DHCP Configuration:
- `DHCP_RANGE_START`: Start of DHCP IP range
- `DHCP_RANGE_END`: End of DHCP IP range  
- `DHCP_SUBNET_MASK`: Network subnet mask

### Production Example Configuration:
```bash
EVE_VERSIONS="14.5.1-lts,13.10.0"
SERVER_IP="192.168.0.4"          # Your PXE server IP
DHCP_MODE="proxy"
PRIMARY_DHCP_IP="192.168.0.1"     # Existing router/DHCP server
LOG_LEVEL="debug"
BOOT_MENU_TIMEOUT="15"
```

## Network Prerequisites

The server requires:
1. Network access with appropriate permissions (--net=host)
2. Elevated privileges for network services (--privileged)
3. Persistent storage for caching (-v ./ipxe_data:/data)

## Troubleshooting Common Issues

### GRUB Rescue Shell ("grub rescue>") 
**Symptoms**: GRUB loads but drops to rescue shell instead of booting EVE-OS
**Root Cause**: GRUB can't find its configuration file (grub.cfg)
**Debugging**:
1. Check if GRUB is requesting grub.cfg from wrong server:
   ```bash
   docker logs ipxe-server | grep grub.cfg
   # Should see requests to YOUR server IP, not primary DHCP IP
   ```
2. Verify grub.cfg exists and has correct content:
   ```bash
   docker exec ipxe-server cat /data/httpboot/14.5.1-lts/EFI/BOOT/grub.cfg
   # Should contain EVE-OS boot configuration, not diagnostic content
   ```

### Wrong Server IP in GRUB
**Symptoms**: GRUB tries to load files from primary DHCP server instead of PXE server
**Solution**: Ensure proxy DHCP configuration includes next-server override
**Verification**:
```bash
# Check dnsmasq config has the critical override
docker exec ipxe-server cat /etc/dnsmasq.conf | grep "option:next-server"
# Should show: dhcp-option=tag:efi64,option:next-server,[YOUR_SERVER_IP]
```

### iPXE Works But GRUB Fails
**Common Cause**: Proxy DHCP settings work for iPXE but GRUB inherits wrong server IP
**Fix**: The next-server override in dnsmasq.conf.template forces GRUB to use correct server
**Key Config**: `dhcp-option=tag:efi64,option:next-server,{{SERVER_IP}}`
