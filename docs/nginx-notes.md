# Nginx Configuration Notes

## Content Type Handling

The nginx configuration uses specific location blocks to handle different file types:

1. iPXE Scripts (`.ipxe`):
   ```nginx
   location ~ \.ipxe$ {
       default_type application/x-ipxe;
       add_header Content-Type application/x-ipxe always;
   }
   ```

2. EFI Binaries (`.efi`):
   ```nginx
   location ~ \.efi$ {
       default_type application/x-pxeboot;
       add_header Content-Type application/x-pxeboot always;
   }
   ```

3. Configuration Files (`.cfg`):
   ```nginx
   location ~ \.cfg$ {
       default_type application/octet-stream;
       add_header Content-Type application/octet-stream always;
   }
   ```

4. Boot Images (`.img`, `.iso`):
   ```nginx
   location ~ \.(img|iso)$ {
       default_type application/octet-stream;
       add_header Content-Type application/octet-stream always;
   }
   ```

## Important Notes

1. Content Type Configuration:
   - Each file type must have its own location block
   - Never use `default_type` inside an `if` block
   - Always use `always` parameter with `add_header`
   - Keep content type definitions consistent

2. Performance Settings:
   - `sendfile on` for efficient file serving
   - `tcp_nopush` and `tcp_nodelay` for network optimization
   - Appropriate timeouts for large file transfers

3. Headers:
   - `Content-Length` must be set for all files
   - Cache control headers to prevent caching
   - CORS headers for cross-origin requests

4. Directory Structure:
   - `/data/httpboot/` as the root directory
   - Special handling for `/latest/` using alias
   - Autoindex enabled for directory listing

## Common Issues

1. Invalid `default_type` Usage:
   ```nginx
   # INCORRECT - will cause startup error
   if ($uri ~* \.efi$) {
       default_type application/x-pxeboot;
   }

   # CORRECT - in location block
   location ~ \.efi$ {
       default_type application/x-pxeboot;
   }
   ```

2. Missing Headers:
   - Always set Content-Length for iPXE compatibility
   - Set proper MIME types for file types
   - Include CORS headers if needed

3. Performance Issues:
   - Use appropriate buffer sizes
   - Enable TCP optimizations
   - Set proper timeouts for large files
