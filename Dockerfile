FROM alpine:latest

# 1. Install dependencies
RUN apk add --no-cache dnsmasq nginx curl tar

# 2. Create necessary directories
# /tftpboot is for dnsmasq to serve iPXE files
# /data is the persistent volume for cached downloads
# /run/nginx is for the nginx pid file
RUN mkdir -p /tftpboot /data /run/nginx

# 3. Copy configuration and scripts
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 4. Expose ports and declare data volume
EXPOSE 80 69/udp 67/udp
VOLUME /data

# 5. Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
