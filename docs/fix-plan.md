# Comprehensive Fix Plan for iPXE Boot Server

## Current State Analysis

### Working Components
1. Basic container structure
2. Initial DHCP proxy response
3. Initial TFTP service

### Identified Issues
1. TFTP transfer failures (buffer size)
2. Exec format errors in iPXE
3. HTTP content length issues
4. Network stack initialization problems

## Fix Plan

### Phase 1: TFTP Configuration

#### 1.1 Update dnsmasq.conf.template
**File**: `/config/dnsmasq.conf.template`
**Changes**:
- Add TFTP optimization settings:
  ```diff
  # TFTP configuration
  enable-tftp
  tftp-root=/tftpboot
  + tftp-blocksize=8192
  + tftp-no-blocksize=no
  + tftp-mtu=1500
  + tftp-max-failures=100
  ```
**Rationale**: Match working configuration and dnsmasq docs for large file transfers

#### 1.2 Update entrypoint.sh TFTP Setup
**File**: `/entrypoint.sh`
**Changes**:
- Modify TFTP initialization:
  ```diff
  # TFTP setup section
  + echo "Configuring TFTP optimizations..."
  + chmod 644 /tftpboot/*
  + chown -R dnsmasq:dnsmasq /tftpboot
  ```
**Rationale**: Ensure proper permissions and ownership for TFTP files

### Phase 2: DHCP Configuration

#### 2.1 Common DHCP Settings
**File**: `/config/dnsmasq.conf.template`
**Changes**:
- Add core DHCP configuration:
  ```diff
  # Base configuration
  + port=0
  + interface={{LISTEN_INTERFACE}}
  + bind-interfaces
  + log-dhcp
  
  # Client detection
  + dhcp-match=set:ipxe,175                   # iPXE ROM
  + dhcp-match=set:efi64,option:client-arch,7  # EFI x64
  + dhcp-match=set:efi64,option:client-arch,9  # EFI x64
  + dhcp-match=set:ipxe-ok,option:user-class,iPXE
  
  # Server options
  + dhcp-option=66,{{SERVER_IP}}              # TFTP server
  ```
**Rationale**: Common settings needed for both modes

#### 2.2 Mode-Specific Configuration
**File**: `/config/dnsmasq.conf.template`
**Changes**:
- Add mode-specific sections:
  ```diff
  {{#if STANDALONE_MODE}}
  # Standalone DHCP Configuration
  + dhcp-range={{DHCP_RANGE_START}},{{DHCP_RANGE_END}},{{DHCP_SUBNET_MASK}},12h
  + dhcp-option=option:router,{{DHCP_ROUTER}}
  {{else}}
  # Proxy DHCP Configuration
  + dhcp-range={{NETWORK_ADDRESS}},proxy,{{DHCP_SUBNET_MASK}}
  + {{#if PRIMARY_DHCP_IP}}
  + dhcp-relay={{PRIMARY_DHCP_IP}}
  + {{/if}}
  {{/if}}
  ```
**Rationale**: Support both standalone and proxy modes properly

#### 2.3 Boot Option Configuration
**File**: `/config/dnsmasq.conf.template`
**Changes**:
- Configure boot options for different clients:
  ```diff
  # Boot configuration for BIOS clients
  + dhcp-boot=tag:!ipxe,tag:!efi64,undionly.kpxe
  
  # Boot configuration for UEFI clients
  + dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi
  
  # Boot configuration for iPXE clients
  + dhcp-boot=tag:ipxe,http://{{SERVER_IP}}/boot.ipxe
  ```
**Rationale**: Support both BIOS and UEFI clients

#### 2.4 entrypoint.sh Updates
**File**: `/entrypoint.sh`
**Changes**:
- Update DHCP mode handling:
  ```diff
  # DHCP mode validation
  + case "$DHCP_MODE" in
  +     standalone)
  +         # Validate standalone mode requirements
  +         if [ -z "$DHCP_RANGE_START" ] || [ -z "$DHCP_RANGE_END" ] || [ -z "$DHCP_ROUTER" ]; then
  +             echo "Error: standalone mode requires DHCP_RANGE_START, DHCP_RANGE_END, and DHCP_ROUTER"
  +             exit 1
  +         fi
  +         ;;
  +     proxy)
  +         # Validate proxy mode requirements
  +         NETWORK_ADDRESS=$(echo ${SERVER_IP} | awk -F. '{print $1"."$2"."$3".0"}')
  +         ;;
  +     *)
  +         echo "Error: DHCP_MODE must be either 'proxy' or 'standalone'"
  +         exit 1
  +         ;;
  + esac
  ```
**Rationale**: Proper mode validation and configuration

#### 2.5 Testing Requirements

1. Standalone Mode Testing:
   ```bash
   # Test DHCP offer
   tcpdump -i eth0 '(port 67 or port 68)' -n
   
   # Verify address assignment
   dhclient -d eth0
   ```

2. Proxy Mode Testing:
   ```bash
   # Test ProxyDHCP response
   tcpdump -i eth0 '(port 67 or port 68) and src host 192.168.0.4' -n
   
   # Verify no IP assignment
   dhclient -d eth0
   ```

3. Boot Option Testing:
   ```bash
   # Test BIOS client
   nc -u 192.168.0.4 67
   
   # Test UEFI client
   nc -u 192.168.0.4 67 # with proper UEFI options
   ```

**Rationale**: Ensure both modes work correctly and independently

### Phase 3: HTTP Server Configuration

#### 3.1 Update nginx.conf
**File**: `/config/nginx.conf`
**Changes**:
- Add proper MIME types:
  ```diff
  types {
  +   application/x-ipxe      ipxe;
  +   application/x-pxeboot   efi;
  }
  ```
- Update location blocks:
  ```diff
  location ~ \.ipxe$ {
  +   default_type application/x-ipxe;
  +   add_header Content-Type application/x-ipxe;
  +   add_header Content-Length $content_length always;
  +   expires -1;
  }

  location ~ \.efi$ {
  +   default_type application/x-pxeboot;
  +   add_header Content-Type application/x-pxeboot;
  +   add_header Content-Length $content_length always;
  +   tcp_nopush on;
  +   tcp_nodelay on;
  }
  ```
**Rationale**: Ensure correct content types and headers as per iPXE docs

### Phase 4: Boot Script Structure

#### 4.1 Update iPXE Script Template
**File**: `/config/ipxe.efi.cfg.template`
**Changes**:
- Modify script structure:
  ```diff
  #!ipxe
  
  + # Enable debugging
  + set debug all
  + set debug dhcp,net
  
  + # Force our server address
  + set next-server {{SERVER_IP}}
  + set boot-url http://${next-server}/{{VERSION}}
  
  # Set boot parameters
  - set url http://{{SERVER_IP}}/{{VERSION}}/
  + echo iPXE boot starting...
  + echo Server: ${next-server}
  + echo Boot URL: ${boot-url}
  ```
**Rationale**: Match working configuration and ensure proper network stack initialization

#### 4.2 Update Boot Menu Generation
**File**: `/entrypoint.sh`
**Changes**:
- Modify boot menu generation:
  ```diff
  # Boot menu generation
  + echo "Generating version-specific iPXE configs..."
  + for version in $EVE_VERSIONS; do
  +   echo "Configuring $version boot files..."
  +   sed -e "s/{{SERVER_IP}}/${SERVER_IP}/g" \
  +       -e "s/{{VERSION}}/${version}/g" \
  +       /config/ipxe.efi.cfg.template > "/data/httpboot/${version}/ipxe.efi.cfg"
  + done
  ```
**Rationale**: Ensure proper variable substitution and file structure

### Phase 5: File Organization

#### 5.1 Update Directory Structure
**Changes**:
- Modify directory layout:
  ```diff
  /data/
  ├── httpboot/
  │   ├── latest/           # chmod 755, www-data:www-data
  │   │   ├── EFI/
  │   │   │   └── BOOT/
  │   │   │       └── BOOTX64.EFI
  │   │   ├── ipxe.efi
  │   │   └── ipxe.efi.cfg
  │   └── ${version}/      # For each version
  └── tftpboot/
      ├── undionly.kpxe    # For BIOS clients
      └── ipxe.efi         # For UEFI clients
  ```
**Rationale**: Match proven directory structure from CONFIGURATION.md

## Implementation Order

1. **TFTP Configuration**
   - Highest priority
   - Addresses immediate transfer failures
   - Quick to implement and test

2. **ProxyDHCP Settings**
   - Critical for boot process
   - Builds on TFTP changes
   - Required for client detection

3. **HTTP Server Configuration**
   - Addresses content type issues
   - Fixes transfer problems
   - Important for iPXE chain loading

4. **Boot Scripts**
   - Updates script structure
   - Ensures proper initialization
   - Final component in chain

5. **Directory Organization**
   - Ensures proper file locations
   - Sets correct permissions
   - Supports all other changes

## Testing Strategy

### 1. Component Testing
```bash
# TFTP test
tftp ${SERVER_IP} -c get undionly.kpxe

# HTTP test
curl -I http://${SERVER_IP}/boot.ipxe
curl -I http://${SERVER_IP}/ipxe.efi.cfg

# DHCP test
tcpdump -i eth0 port 67 or port 68
```

### 2. Integration Testing
- Monitor logs during boot:
  ```bash
  docker logs -f ipxe-server
  ```
- Check file transfers:
  ```bash
  tcpdump -i eth0 port 69 or port 80
  ```

### 3. End-to-End Testing
1. Boot test client
2. Verify each stage:
   - TFTP transfer
   - iPXE loading
   - HTTP boot
   - Final boot

## Rollback Plan

1. Keep backup of all modified files
2. Version all configuration changes
3. Document reversion steps
4. Test rollback procedure
