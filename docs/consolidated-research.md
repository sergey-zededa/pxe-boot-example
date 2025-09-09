# Comprehensive iPXE Boot Server Configuration Analysis

## Table of Contents
1. [Boot Process Overview](#boot-process-overview)
2. [Component Configuration](#component-configuration)
   - [DHCP/ProxyDHCP (dnsmasq)](#dhcpproxydhcp-dnsmasq)
   - [TFTP Server (dnsmasq)](#tftp-server-dnsmasq)
   - [HTTP Server (nginx)](#http-server-nginx)
3. [Error Analysis and Solutions](#error-analysis-and-solutions)
4. [Implementation Guide](#implementation-guide)
5. [Testing and Verification](#testing-and-verification)

## Boot Process Overview

### Complete Boot Sequence
1. **Initial PXE Boot**
   - Client sends DHCP discover
   - ProxyDHCP provides boot information
   - Client downloads iPXE binary via TFTP

2. **iPXE Chain Loading**
   - iPXE binary executes
   - Requests configuration via HTTP
   - Downloads boot script

3. **Final Boot Stage**
   - Executes boot script
   - Downloads required components
   - Initializes system

### Network Protocol Requirements
1. **DHCP/ProxyDHCP**
   - Must not interfere with existing DHCP
   - Must provide next-server and filename
   - Must handle client detection

2. **TFTP**
   - Must support large block sizes
   - Must handle retransmission
   - Must support binary transfers

3. **HTTP**
   - Must provide correct headers
   - Must handle large file transfers
   - Must serve correct MIME types

## Component Configuration

### DHCP/ProxyDHCP (dnsmasq)

#### Basic Configuration
```conf
# ProxyDHCP setup
dhcp-range=192.168.0.0,proxy
bind-interfaces
interface=eth0

# Client detection
dhcp-match=set:ipxe,175
dhcp-match=set:ipxe-ok,option:user-class,iPXE

# Boot options
dhcp-boot=tag:!ipxe,undionly.kpxe
dhcp-boot=tag:ipxe,http://${next-server}/boot.ipxe

# Server options
dhcp-option=66,${next-server}
```

#### Critical Settings
1. **ProxyDHCP Mode**
   - Must use 'proxy' keyword
   - Must not offer IP addresses
   - Must bind to correct interface

2. **Client Detection**
   - Option 175 for iPXE
   - User class checking
   - Tag-based boot selection

3. **Boot Options**
   - Different paths for PXE vs iPXE
   - Proper next-server setting
   - Correct filename options

### TFTP Server (dnsmasq)

#### Basic Configuration
```conf
# TFTP setup
enable-tftp
tftp-root=/tftpboot

# Performance options
tftp-block-size=8192       # Correct hyphenated option name
tftp-mtu=1500             # Maximum transmission unit
tftp-max-failures=100     # Retry limit for failed blocks
```

#### Critical Settings
1. **Block Size**
   - Default (512) too small
   - Use 8192 for large files
   - Enable negotiation

2. **Reliability**
   - More retries for large files
   - Proper MTU setting
   - Timeout configuration

### HTTP Server (nginx)

#### Basic Configuration
```nginx
# MIME types
types {
    application/x-ipxe              ipxe;
    application/x-ipxe-script       ipxe;
    application/x-pxeboot           efi;
    application/octet-stream        iso img;
}

# iPXE script handling
location ~ \.ipxe$ {
    default_type application/x-ipxe;
    add_header Content-Type application/x-ipxe;
    add_header Content-Length $content_length;
    expires -1;
}

# Binary file handling
location ~ \.(efi|iso|img)$ {
    default_type application/octet-stream;
    add_header Content-Length $content_length;
    tcp_nopush on;
    tcp_nodelay on;
    sendfile on;
    keepalive_timeout 300;
}
```

#### Critical Settings
1. **Headers**
   - Correct Content-Type
   - Accurate Content-Length
   - Proper Cache-Control

2. **Performance**
   - TCP optimizations
   - Buffer configuration
   - Timeout settings

## Error Analysis and Solutions

### Common Errors

1. **0x2e008001 (Exec Format Error)**
   - Cause: iPXE cannot parse downloaded file
   - Check: MIME types and file integrity
   - Fix: Ensure correct Content-Type headers

2. **Buffer Size Errors**
   - Cause: TFTP block size too small
   - Check: dnsmasq TFTP configuration
   - Fix: Increase block size and enable negotiation

3. **Network Stack Issues**
   - Cause: Incomplete initialization
   - Check: Boot script sequence
   - Fix: Ensure proper network configuration

### Solution Matrix

| Error | Component | Check | Fix |
|-------|-----------|-------|-----|
| Exec Format | nginx | MIME types | Set correct Content-Type |
| Buffer Size | dnsmasq | TFTP config | Increase block size |
| Network | iPXE | Boot script | Initialize network |
| Timeout | All | Timeouts | Increase timeout values |

## Implementation Guide

### Phase 1: TFTP Configuration
1. Configure block size and negotiation
2. Set proper timeouts
3. Enable reliability options

### Phase 2: ProxyDHCP Setup
1. Configure proxy mode
2. Set up client detection
3. Configure boot options

### Phase 3: HTTP Server
1. Set up MIME types
2. Configure headers
3. Enable performance options

### Phase 4: Boot Scripts
1. Verify script format
2. Ensure network initialization
3. Configure error handling

## Testing and Verification

### Component Tests

1. **TFTP Test**
```bash
tftp ${next-server} -c get undionly.kpxe
```

2. **HTTP Test**
```bash
curl -I http://${next-server}/boot.ipxe
curl -I http://${next-server}/bootx64.efi
```

3. **ProxyDHCP Test**
```bash
tcpdump -i eth0 port 67 or port 68 or port 69
```

### End-to-End Test
1. Boot client with network boot enabled
2. Monitor server logs:
   ```bash
   tail -f /var/log/dnsmasq.log
   tail -f /var/log/nginx/access.log
   ```
3. Verify successful boot sequence

## Configuration Files

### dnsmasq.conf
```conf
# Basic configuration
port=0
interface=eth0
bind-interfaces

# TFTP configuration
enable-tftp
tftp-root=/tftpboot
tftp-blocksize=8192
tftp-no-blocksize=no

# ProxyDHCP configuration
dhcp-range=192.168.0.0,proxy
dhcp-match=set:ipxe,175
dhcp-boot=tag:!ipxe,undionly.kpxe
dhcp-boot=tag:ipxe,http://${next-server}/boot.ipxe
```

### nginx.conf
```nginx
http {
    types {
        application/x-ipxe              ipxe;
        application/x-pxeboot           efi;
    }

    server {
        listen 80;
        root /data/httpboot;

        location ~ \.ipxe$ {
            default_type application/x-ipxe;
            add_header Content-Length $content_length;
        }

        location ~ \.efi$ {
            default_type application/x-pxeboot;
            add_header Content-Length $content_length;
            tcp_nopush on;
            tcp_nodelay on;
        }
    }
}
```

### boot.ipxe
```ipxe
#!ipxe

# Initialize network
dhcp || goto retry_dhcp

:retry_dhcp
echo Retrying DHCP...
sleep 2
dhcp && goto boot || goto retry_dhcp

:boot
chain --autofree http://${next-server}/next-stage.ipxe
```
