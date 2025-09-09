# Dnsmasq Documentation Analysis for PXE Boot

## Overview of Relevant Documentation Sections

From analyzing dnsmasq.conf.example and man pages, these are the critical sections for our PXE boot setup:

1. TFTP Server Configuration
2. DHCP Proxy Mode
3. PXE Boot Options
4. Network Interface Configuration
5. DHCP Options and Tags

## Critical Configuration Components

### 1. TFTP Server Setup
From man page section 'TFTP configuration':
```conf
# Basic TFTP configuration
enable-tftp
tftp-root=/tftpboot

# TFTP performance options
tftp-block-size=8192         # Correct option name, larger size for iPXE
tftp-mtu=1500              # Maximum transmission unit
tftp-max-failures=100      # Retry limit for failed blocks
```

Important notes:
- TFTP blocksize must be configurable for iPXE
- Default blocksize (512) is too small for modern boot images
- MTU setting affects reliability of large file transfers

### 2. Proxy DHCP Mode
From man page section 'DHCP, proxy on subnet':
```conf
# Proxy DHCP configuration
dhcp-range=192.168.0.0,proxy
dhcp-no-override             # Don't reuse filename field
bind-interfaces             # Important for proxy mode

# Interface configuration
interface=eth0              # Listen interface
bind-dynamic               # Handle dynamic interfaces
```

Key points:
- Proxy mode MUST NOT provide IP addresses
- Uses special "proxy" keyword in dhcp-range
- Requires proper interface binding

### 3. PXE Boot Options
From dnsmasq.conf.example:
```conf
# PXE boot detection
dhcp-match=set:ipxe,175                    # iPXE binary detection
dhcp-match=set:ipxe-ok,option:user-class,iPXE  # iPXE client detection

# Boot file selection
dhcp-boot=tag:!ipxe,undionly.kpxe          # Initial PXE boot
dhcp-boot=tag:ipxe,http://${next-server}/boot.ipxe  # iPXE script

# Server options
dhcp-option=66,${next-server}              # TFTP server
dhcp-option=67,undionly.kpxe               # Boot filename
```

Important notes:
- Different boot paths for PXE vs iPXE clients
- Tag system for client identification
- Option 66 (next-server) required for TFTP

### 4. Network Interface Settings
```conf
# Interface configuration
interface=eth0                  # Specify interface
bind-interfaces                # Strict binding
listen-address=192.168.0.4     # Server IP

# Advanced interface options
bind-dynamic                  # For dynamic interfaces
bogus-priv                   # Block private reverse lookups
domain-needed                # Don't forward plain names
```

Critical for proxy DHCP:
- Must bind to correct interface
- Server IP must be properly set
- Dynamic binding if needed

### 5. DHCP Options Management
```conf
# DHCP option configuration
dhcp-option=vendor:PXEClient,1,0.0.0.0
dhcp-option=vendor:PXEClient,6,1
dhcp-option=vendor:PXEClient,8,1
dhcp-option=vendor:PXEClient,9,1
dhcp-option=vendor:PXEClient,15,1

# Tag-based options
dhcp-option=tag:ipxe,option:bootfile-name,http://${next-server}/boot.ipxe
dhcp-option=tag:!ipxe,option:bootfile-name,undionly.kpxe
```

Important details:
- Vendor class options for PXE clients
- Tag system for conditional options
- Option syntax and formatting

## Performance and Reliability Settings

### 1. TFTP Optimization
```conf
# TFTP transfer optimization
tftp-blocksize=8192         # Larger block size
tftp-no-blocksize=no       # Enable negotiation
tftp-mtu=1500             # Network MTU

# Retry handling
tftp-max-failures=100     # More retries
tftp-timeout=5           # Longer timeout
```

### 2. Network Settings
```conf
# Network performance
bind-interfaces           # Better control
bind-dynamic             # Handle changes
log-dhcp                # Debug info
```

## Debug and Logging Options
```conf
# Logging configuration
log-queries              # Show DNS queries
log-dhcp                # Show DHCP activity
log-facility=/var/log/dnsmasq.log  # Log file

# Debug options
no-daemon               # Run in foreground
log-debug              # Verbose logging
```

## Implementation Recommendations

Based on the documentation analysis, our configuration should:

1. TFTP Setup:
   - Use larger block sizes (8192 recommended)
   - Enable blocksize negotiation
   - Configure proper timeouts and retries

2. Proxy DHCP:
   - Use correct dhcp-range syntax for proxy mode
   - Properly set up interface binding
   - Configure next-server and filename options

3. PXE Boot:
   - Implement proper client detection
   - Use tag system for boot selection
   - Configure vendor options correctly

4. Network Settings:
   - Use correct interface binding
   - Configure server IP properly
   - Enable appropriate logging

## Troubleshooting Tools

The documentation provides several debugging methods:

1. Logging:
   ```conf
   log-queries
   log-dhcp
   log-debug
   ```

2. Testing:
   ```bash
   dnsmasq --test
   dnsmasq --no-daemon --log-debug
   ```

3. Runtime Checks:
   - SIGHUP for configuration reload
   - SIGUSR1 for cache dump
   - Status checks in syslog

## Configuration Order

For our PXE boot setup, implement in this order:

1. Basic TFTP configuration
2. Network interface setup
3. Proxy DHCP configuration
4. PXE boot options
5. Performance optimization
6. Logging and debugging
