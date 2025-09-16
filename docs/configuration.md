# Configuration Management

This document describes how configuration is managed in the iPXE server.

## Template-based Configuration

All service configurations are managed using templates in the `config/` directory. These templates are processed at runtime to generate the actual configuration files.

### Template Variables

Configuration templates use the following variable syntax:
```
{{VARIABLE_NAME}}
```

For example:
```conf
interface={{LISTEN_INTERFACE}}
```

### Configuration Flow

1. Templates are stored in `config/` directory
2. Environment variables provide runtime values
3. Templates are processed during container startup
4. Generated configurations are validated before use

## Service-specific Configuration

### DNSMASQ Configuration

The DNSMASQ configuration is managed through `config/dnsmasq.conf.template`.

#### Template Variables
- `{{LISTEN_INTERFACE}}`: Network interface to listen on
- `{{SERVER_IP}}`: Server IP address
- `{{DHCP_SUBNET_MASK}}`: Subnet mask for DHCP
- `{{NETWORK_ADDRESS}}`: Computed network address for proxy mode
- `{{STANDALONE_MODE}}`: Flag for standalone vs proxy mode (1 or 0)
- `{{DHCP_RANGE_START}}`: Start of DHCP range (standalone mode)
- `{{DHCP_RANGE_END}}`: End of DHCP range (standalone mode)
- `{{DHCP_ROUTER}}`: Gateway address (standalone mode)
- `{{DHCP_DOMAIN_NAME}}`: Optional domain name
- `{{DHCP_BROADCAST_ADDRESS}}`: Optional broadcast address
- `{{DEBUG}}`: Debug mode flag (1 or 0)

Note: In proxy mode, dnsmasq uses `dhcp-range=<network>,proxy,<mask>` and must not include `dhcp-relay`. The `PRIMARY_DHCP_IP` environment variable is used only by the startup script to validate connectivity to the primary DHCP server and is not injected into `dnsmasq.conf`.

#### Validation
Configuration is validated in two steps:
1. Template existence check
2. DNSMASQ configuration validation using `dnsmasq --test`

### NGINX Configuration

The NGINX configuration is managed through `config/nginx.conf`.

#### Template Variables:
(Document other service configurations as they are templated)

## Implementation Details

### Directory Structure:
```
config/
  ├── dnsmasq.conf.template    # DNSMASQ configuration template
  ├── nginx.conf.template      # NGINX configuration template
  ├── autoexec.ipxe.template  # iPXE autoexec template
  ├── boot.ipxe.template      # iPXE boot menu template
  ├── ipxe.efi.cfg.template   # iPXE EFI configuration template
  └── grub.cfg.template       # GRUB configuration template
```

### Processing Functions:

The `entrypoint.sh` script contains the following template processing functions:

#### Core Processing:
- `process_template()`: Common template processing function
  * Handles variable substitution
  * Validates template existence
  * Verifies output generation

#### Service-specific Generators:
- `generate_dnsmasq_conf()`: Process DNSMASQ configuration
- `generate_nginx_conf()`: Process NGINX configuration
- `generate_autoexec()`: Generate iPXE autoexec script
- `generate_version_config()`: Generate version-specific iPXE config

### Error Handling:
- Missing templates are treated as fatal errors
- Invalid configurations are reported with details
- Service-specific validation is performed where possible

## Best Practices

1. Configuration Changes:
   - Always modify templates, not generated files
   - Keep templates in version control
   - Document all configuration variables

2. Testing:
   - Validate templates before deployment
   - Test with different configuration combinations
   - Verify service-specific validation

3. Maintenance:
   - Keep templates synchronized with documentation
   - Update validation when adding new variables
   - Monitor template processing performance
