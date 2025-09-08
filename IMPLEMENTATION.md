# Implementation Plan: Configuration Alignment

This document outlines the implementation plan for aligning the iPXE server configuration with the verified working configuration.

## Phase 1: Core Infrastructure

### Dockerfile Updates
- [ ] Add www-data and dnsmasq users/groups
- [ ] Install additional required packages
- [ ] Set up proper directory permissions
- [ ] Configure volume permissions

### Directory Structure
- [ ] Update /data/httpboot/ structure and permissions (755, www-data:www-data)
- [ ] Update /tftpboot/ structure and permissions (755, dnsmasq:nogroup)
- [ ] Set up file permissions:
  - [ ] kernel, initrd.img, ucode.img (644, www-data:www-data)
  - [ ] ipxe.efi.cfg (644, www-data:www-data)
  - [ ] boot.ipxe (644, www-data:www-data)
- [ ] Implement 'latest' symlink management

### Service Configurations
- [ ] Update nginx.conf:
  - [ ] Add MIME type handling for .ipxe and .efi files
  - [ ] Configure default_server and IPv6 support
  - [ ] Set up proper root directory and index settings
  - [ ] Add specific location blocks
  - [ ] Configure error handling and logging
- [ ] Update dnsmasq configuration:
  - [ ] Implement proxy and standalone mode handling
  - [ ] Set up TFTP configuration
  - [ ] Configure PXE/iPXE detection
  - [ ] Set up DHCP options for boot stages

## Phase 2: Boot Configuration

### iPXE Script Templates
- [ ] Create autoexec.ipxe template:
  - [ ] Add proper error handling
  - [ ] Implement retry logic
  - [ ] Add debugging support
  - [ ] Configure network setup

### Version-specific Configuration
- [ ] Create ipxe.efi.cfg template:
  - [ ] Implement hardware detection
  - [ ] Set up console configuration
  - [ ] Configure boot parameters
  - [ ] Add error handling

### Boot Menu Generation
- [ ] Update boot menu generation:
  - [ ] Add timeout configuration
  - [ ] Implement version selection
  - [ ] Add error handling
  - [ ] Configure default boot options

## Phase 3: Environment and Testing

### Environment Variable Handling
- [ ] Update environment variable validation:
  - [ ] Add support for all documented variables
  - [ ] Implement mode-specific validation
  - [ ] Add console and platform parameters
  - [ ] Set up proper default values

### Testing Implementation
- [ ] Update verification scripts:
  - [ ] Add TFTP service testing
  - [ ] Implement HTTP service verification
  - [ ] Add DHCP service testing
  - [ ] Test file permissions and ownership
- [ ] Create comprehensive test suite:
  - [ ] Add boot process testing
  - [ ] Implement configuration verification
  - [ ] Add error handling tests

### Documentation
- [ ] Update README.md with new features
- [ ] Document environment variables
- [ ] Add troubleshooting guide
- [ ] Update testing procedures

## Status Tracking

### Phase 1 Status
- Not Started

### Phase 2 Status
- Not Started

### Phase 3 Status
- Not Started

## Notes
- Each phase will be implemented sequentially
- Testing will be performed after each phase
- Documentation will be updated continuously
- Changes will be committed atomically with descriptive messages
