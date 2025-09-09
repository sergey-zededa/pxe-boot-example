# iPXE Documentation Research

## Relevant Documentation Categories

1. Error Code `0x2e008001`
   From https://ipxe.org/err/2e008001
   - Indicates an exec format error
   - Occurs when iPXE tries to execute a file that it doesn't recognize as a valid executable format
   - Common causes:
     * Attempting to execute a file that is not in a supported format
     * Attempting to execute a script file without the proper `#!ipxe` header
     * Network corruption during file transfer

2. Chain Loading
   From https://ipxe.org/cmd/chain
   - Proper syntax: `chain [--replace] [--autofree] filename`
   - Options:
     * `--replace`: Unload current image after loading new one
     * `--autofree`: Automatically free memory used by unreferenced images
   - Important notes:
     * When chain loading HTTP, Content-Length header must be present
     * Server must provide accurate file size
     * Supports various protocols (tftp, http, etc.)

3. HTTP Boot Process
   From https://ipxe.org/howto/httpboot
   - Steps:
     1. DHCP server provides iPXE binary via TFTP
     2. iPXE loads and requests its configuration
     3. Configuration redirects to HTTP server
     4. HTTP server provides boot files
   - Requirements:
     * HTTP server must provide correct Content-Type headers
     * Files must be accessible via absolute URLs
     * Server must handle large file transfers properly

4. DHCP Configuration
   From https://ipxe.org/howto/dhcpd
   - For Proxy DHCP:
     * Must not offer IP addresses
     * Must provide next-server and filename
     * Should detect iPXE client
   - Required DHCP Options:
     * Option 60 (vendor class) for iPXE detection
     * Option 67 (bootfile name) for directing to HTTP
     * Option 66 (next-server) if needed

5. Boot Protocol Specification
   From https://ipxe.org/specs/pxespec
   - Network Stack Requirements:
     * Must initialize before downloading NBP
     * Must maintain network connection
     * Must support TCP/IP and UDP/IP
   - TFTP Requirements:
     * Must support block sizes up to 1432 bytes
     * Must handle timeouts and retransmissions
   - HTTP Requirements:
     * Must support GET method
     * Must handle Content-Length header
     * Should support chunked transfer encoding

6. PXE Boot Process
   From https://ipxe.org/howto/chainloading
   1. DHCP Discovery (PXE client)
   2. DHCP Offer (Server)
   3. DHCP Request (Client)
   4. DHCP ACK with PXE options (Server)
   5. TFTP Request for NBP (Client)
   6. NBP Download (Server to Client)
   7. NBP Execution (Client)

7. Scripting
   From https://ipxe.org/scripting
   - Script files must:
     * Start with `#!ipxe`
     * Use correct command syntax
     * Handle errors appropriately
   - Common commands:
     * `dhcp` - Configure network interface
     * `chain` - Load and execute another boot program
     * `isset` - Test if a variable exists
     * `goto` - Jump to a label
     * `echo` - Display text

8. HTTP Server Requirements
   From https://ipxe.org/howto/webserver
   - Must set correct MIME types:
     * `.ipxe` -> `application/x-ipxe`
     * `.efi` -> `application/x-pxeboot` or `application/octet-stream`
   - Headers:
     * Must include Content-Length
     * Should include Content-Type
     * Should handle range requests
   - Performance:
     * Should enable keep-alive
     * Should configure for large file transfers
     * Should handle concurrent requests

## Current Issue Analysis

Our current error pattern matches several documented issues:

1. Initial TFTP Error
   - "Buffer size is smaller than the requested file"
   - Documented solution: Configure TFTP for larger block sizes

2. Exec Format Error
   - Error code 0x2e008001
   - Indicates iPXE cannot parse the downloaded file
   - Possible causes:
     * Missing or incorrect `#!ipxe` header
     * File corruption during transfer
     * Wrong file being served

3. HTTP Boot Failure
   - "Could not retrieve NBP file size"
   - Indicates missing Content-Length header
   - Required fix: proper HTTP server configuration

## Resolution Requirements

1. TFTP Configuration
   - Increase block size
   - Enable block size negotiation
   - Configure proper timeouts

2. DHCP/ProxyDHCP
   - Proper iPXE detection
   - Correct bootfile name specification
   - Next-server configuration

3. HTTP Server
   - Correct MIME types
   - Required headers
   - Transfer optimizations

4. Boot Files
   - Proper script headers
   - Correct file formats
   - Network stack initialization
