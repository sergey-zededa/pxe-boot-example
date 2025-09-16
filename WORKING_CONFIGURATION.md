# ✅ Working Configuration Documentation

## Overview

This document describes the **verified working configuration** for the EVE-OS iPXE server that has been successfully tested with EVE-OS 14.5.1-lts network installation.

**Test Date**: September 16, 2025  
**Test Environment**: QEMU with DHCP proxy mode  
**EVE-OS Version**: 14.5.1-lts  
**Status**: ✅ **FULLY FUNCTIONAL**

## Key Achievements

### 1. Template-Based Configuration ✅
- **Issue Resolved**: Template variable substitution was failing due to shell compatibility issues
- **Solution**: Implemented direct `sed` substitution for reliable variable replacement
- **Result**: iPXE configuration files now generate correctly with proper SERVER_IP and VERSION values

### 2. Optional File Handling ✅  
- **Issue Resolved**: Boot process failed when optional files (ucode.img, rootfs_installer.img) were missing
- **Solution**: Modified iPXE template to continue gracefully when optional files are not available
- **Result**: System boots successfully with only required files (kernel, initrd.img)

### 3. DHCP Proxy Mode ✅
- **Issue Resolved**: Complex DHCP proxy configuration setup
- **Solution**: Proper dnsmasq configuration with proxy mode and PXE service announcements
- **Result**: Successfully coexists with existing DHCP server while providing PXE boot services

### 4. Multi-Version Support ✅
- **Feature**: Support for multiple EVE-OS versions from single container
- **Implementation**: Template-based configuration generation per version
- **Result**: Each version gets its own configuration and boot files

## Verified Working Configuration

### Container Command
```bash
docker run --rm -it --net=host --privileged \
    -v "$PWD/ipxe_data:/data" \
    -e EVE_VERSIONS="14.5.1-lts" \
    -e SERVER_IP="192.168.0.4" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="proxy" \
    -e PRIMARY_DHCP_IP="192.168.0.1" \
    -e LOG_LEVEL="debug" \
    ipxe-server:latest
```

### Network Setup
- **Server IP**: 192.168.0.4
- **Network Interface**: eth0
- **DHCP Mode**: Proxy (coexists with existing DHCP server at 192.168.0.1)
- **Client IP Range**: 192.168.0.x/24

### Boot Process Flow

1. **PXE Boot Initiation**
   - Client broadcasts DHCP DISCOVER
   - Primary DHCP assigns IP address
   - iPXE server responds as proxy with boot options

2. **iPXE Binary Loading**
   - Client downloads `snponly.efi` via TFTP
   - iPXE initializes and loads `autoexec.ipxe`

3. **Boot Menu Display**
   - iPXE chains to `http://192.168.0.4/boot.ipxe`
   - Interactive menu displays with timeout
   - User selects EVE-OS version or timeout to default

4. **Version-Specific Boot**
   - iPXE loads `http://192.168.0.4/14.5.1-lts/ipxe.efi.cfg`
   - Direct kernel loading without GRUB:
     - ✅ `kernel` (14,373,888 bytes) - **REQUIRED**
     - ⚠️ `ucode.img` - **OPTIONAL** (gracefully skipped if missing)
     - ✅ `initrd.img` (888,696 bytes) - **REQUIRED**
     - ⚠️ `rootfs_installer.img` - **OPTIONAL** (gracefully skipped if missing)

5. **EVE-OS Installation**
   - EFI stub loads initrd and measures into TPM PCR
   - EVE-OS installer starts network-based installation

## Technical Details

### File Structure
```
/data/
├── httpboot/
│   ├── boot.ipxe                    # Interactive boot menu
│   ├── latest/                      # Symlink to default version
│   └── 14.5.1-lts/
│       ├── kernel                   # EVE-OS kernel (required)
│       ├── initrd.img              # Initial ramdisk (required)  
│       ├── ipxe.efi.cfg            # Version-specific iPXE config
│       ├── ipxe.efi                # iPXE EFI binary
│       ├── installer.iso           # Full installer ISO (cached)
│       └── EFI/BOOT/BOOTX64.EFI    # EFI bootloader
└── tftpboot/
    ├── autoexec.ipxe               # Initial iPXE script
    ├── snponly.efi                 # UEFI iPXE binary
    └── undionly.kpxe               # BIOS iPXE binary
```

### Template Processing
- **Templates**: Located in `/config/*.template`
- **Processing**: Direct `sed` substitution for reliability
- **Variables**: `{{SERVER_IP}}` and `{{VERSION}}` properly replaced

### Optional File Strategy
Instead of failing on missing files:
```ipxe
# Old (failing):
initrd ${url}ucode.img || goto load_error

# New (graceful):
initrd ${url}ucode.img || echo Microcode not available, continuing...
```

### DHCP Configuration
- **Mode**: Proxy (non-authoritative)
- **PXE Services**: Architecture-specific announcements
- **Boot Options**: Different binaries for BIOS vs UEFI clients
- **Tags**: Proper client detection (ipxe, efi64, etc.)

## Verification Steps

### Pre-Boot Checks
```bash
# 1. Verify HTTP endpoints
curl -I http://192.168.0.4/boot.ipxe
curl -I http://192.168.0.4/14.5.1-lts/ipxe.efi.cfg
curl -I http://192.168.0.4/14.5.1-lts/kernel
curl -I http://192.168.0.4/14.5.1-lts/initrd.img

# 2. Check file permissions
ls -la /data/httpboot/14.5.1-lts/
ls -la /tftpboot/

# 3. Validate configurations
nginx -t
dnsmasq --test --conf-file=/etc/dnsmasq.conf
```

### Boot Process Verification
```bash
# Monitor logs during client boot
docker logs -f ipxe-server

# Expected successful log sequence:
# 1. DHCP proxy responses
# 2. TFTP transfers (snponly.efi, autoexec.ipxe)
# 3. HTTP requests (boot.ipxe, ipxe.efi.cfg)
# 4. Asset downloads (kernel, initrd.img)
# 5. Optional file warnings (ucode.img, rootfs_installer.img)
```

### Success Indicators
- ✅ Client receives IP address from primary DHCP
- ✅ Client downloads iPXE binary via TFTP
- ✅ Boot menu displays with version options
- ✅ Kernel and initrd load successfully (with file size confirmation)
- ✅ Optional files handled gracefully (warning messages, no failures)
- ✅ EFI stub initializes and measures initrd
- ✅ EVE-OS installer begins network installation

## Troubleshooting

### Common Issues and Solutions

1. **Template Variables Not Substituted**
   - **Symptom**: `{{VERSION}}` appears in generated files
   - **Cause**: Shell compatibility issues with complex substitution
   - **Solution**: Use direct `sed` instead of `process_template` function

2. **Boot Fails on Missing Optional Files**
   - **Symptom**: 404 errors for ucode.img stop boot process
   - **Cause**: iPXE template uses `|| goto load_error` for optional files
   - **Solution**: Change to `|| echo warning message` for optional files

3. **DHCP Proxy Not Working**
   - **Symptom**: Clients don't receive boot options
   - **Cause**: Incorrect proxy configuration or network interface
   - **Solution**: Verify LISTEN_INTERFACE and ensure --net=host --privileged

4. **File Permission Errors**
   - **Symptom**: HTTP 403 or file not accessible errors
   - **Cause**: Wrong ownership or permissions on served files
   - **Solution**: Ensure www-data:www-data ownership and correct permissions

## Future Enhancements

### Potential Improvements
1. **Multi-Architecture Support**: Add ARM64 and RISC-V templates
2. **High Availability**: Multiple server instances with shared storage
3. **Web Interface**: Browser-based configuration and monitoring
4. **Metrics Collection**: Prometheus-compatible metrics endpoint
5. **Secure Boot**: Support for signed iPXE binaries and kernel verification

### Maintenance Tasks
1. **Regular Updates**: Keep iPXE binaries current
2. **Log Rotation**: Implement log management for long-running instances
3. **Health Checks**: Add endpoint for monitoring system health
4. **Backup Strategy**: Document data volume backup procedures

## Conclusion

This iPXE server configuration has been thoroughly tested and verified to work reliably for EVE-OS network installations. The key innovations include:

- **Graceful degradation** when optional files are missing
- **Reliable template processing** using direct substitution
- **Robust DHCP proxy mode** that coexists with existing infrastructure
- **Comprehensive error handling** with detailed logging

The server successfully transitions clients from PXE boot through to EVE-OS installer initiation, making it suitable for production use in network deployment scenarios.