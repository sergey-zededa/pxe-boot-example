# Nginx Configuration Examples for iPXE Boot Server

## Official Documentation Sources

1. iPXE Webserver Configuration: https://ipxe.org/howto/webserver
   - Basic HTTP server requirements
   - MIME types and headers
   - Transfer encoding requirements

2. Netboot.xyz Example: https://netboot.xyz/docs/booting/ipxe/
   - Production-grade iPXE configuration
   - Multiple boot options
   - Chained boot configurations

3. CoreOS iPXE Setup: https://docs.fedoraproject.org/en-US/fedora-coreos/bare-metal/
   - Specific to CoreOS but has good nginx examples
   - Handles large file transfers
   - Caching configurations

## Essential Configuration Examples

### 1. Basic iPXE Configuration
```nginx
http {
    # Required MIME Types
    types {
        application/x-ipxe              ipxe;
        application/x-ipxe-script       ipxe;
        application/x-pxeboot           efi;
        application/octet-stream        iso img;
    }

    # Basic iPXE server
    server {
        listen 80;
        server_name boot.example.com;
        root /var/www/ipxe;

        location / {
            autoindex on;
            autoindex_exact_size off;
        }
    }
}
```

### 2. Advanced iPXE Configuration
```nginx
server {
    listen 80;
    server_name boot.example.com;
    root /var/www/ipxe;

    # iPXE script handling
    location ~ \.ipxe$ {
        default_type application/x-ipxe;
        add_header Content-Type application/x-ipxe;
        add_header Content-Length $content_length;
        
        # Critical: proper headers for iPXE
        add_header X-IPE-Error-Handling "true";
        expires -1;
        add_header Cache-Control "private, no-cache, no-store";
    }

    # EFI binary handling
    location ~ \.efi$ {
        default_type application/x-pxeboot;
        add_header Content-Type application/x-pxeboot;
        add_header Content-Length $content_length;
        
        # Large file optimizations
        tcp_nopush on;
        tcp_nodelay on;
        sendfile on;
        keepalive_timeout 300;
    }

    # Boot images and ISOs
    location ~ \.(iso|img)$ {
        default_type application/octet-stream;
        add_header Content-Type application/octet-stream;
        add_header Content-Length $content_length;
        
        # Large file handling
        client_max_body_size 0;
        client_body_buffer_size 128k;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
```

### 3. Performance Optimizations
```nginx
http {
    # Global settings for large files
    client_max_body_size 0;
    client_body_timeout 300s;
    keepalive_timeout 300s;
    send_timeout 300s;

    # Buffering settings
    proxy_buffering on;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;
    proxy_temp_file_write_size 256k;

    # Compression for iPXE scripts (not binaries)
    location ~ \.ipxe$ {
        gzip on;
        gzip_min_length 1000;
        gzip_types application/x-ipxe;
    }
}
```

### 4. Caching Configuration
```nginx
http {
    # Cache settings
    proxy_cache_path /var/cache/nginx levels=1:2 
                     keys_zone=ipxe_cache:10m
                     max_size=10g 
                     inactive=60m;

    # Cache configuration
    location ~ \.(iso|img|efi)$ {
        proxy_cache ipxe_cache;
        proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
        proxy_cache_valid 200 60m;
        proxy_cache_valid any 1m;
        expires 30d;
    }

    # No cache for iPXE scripts
    location ~ \.ipxe$ {
        expires -1;
        add_header Cache-Control "private, no-cache, no-store";
    }
}
```

## Critical Configuration Points

1. Content Types and Headers:
   - Correct MIME types are essential
   - Content-Length must be accurate
   - Cache-Control for dynamic content

2. Performance Settings:
   - Enable TCP optimizations
   - Configure proper timeouts
   - Buffer sizes for large files

3. Error Handling:
   - Proper error responses
   - Timeout configurations
   - Logging for debugging

## Testing Configuration

1. Validate Configuration:
```bash
nginx -t
```

2. Test MIME Types:
```bash
curl -I http://server/boot.ipxe
curl -I http://server/bootx64.efi
```

3. Test Headers:
```bash
curl -v http://server/boot.ipxe
```

## Common Issues and Solutions

1. Missing Content-Length:
   ```nginx
   location / {
       add_header Content-Length $content_length always;
   }
   ```

2. Wrong MIME Type:
   ```nginx
   location ~ \.ipxe$ {
       default_type application/x-ipxe;
       add_header Content-Type application/x-ipxe always;
   }
   ```

3. Timeout Issues:
   ```nginx
   location ~ \.(iso|img)$ {
       client_body_timeout 300s;
       keepalive_timeout 300s;
       send_timeout 300s;
   }
   ```

## Recommended Implementation Order

1. Basic Configuration:
   - Set up MIME types
   - Configure basic locations
   - Enable autoindex

2. Headers and Content Types:
   - Add correct Content-Type headers
   - Configure Content-Length
   - Set up Cache-Control

3. Performance Optimization:
   - Enable TCP optimizations
   - Configure buffering
   - Set up timeouts

4. Advanced Features:
   - Configure caching
   - Set up compression
   - Add error handling
