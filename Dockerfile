FROM alpine:latest

# 1. Install dependencies
RUN apk add --no-cache \
    dnsmasq \
    nginx \
    curl \
    tar \
    dos2unix \
    shadow \
    bash \
    mount

# 2. Create users and groups
RUN adduser -S -u 82 -D -H -h /var/www -s /sbin/nologin -G www-data -g www-data www-data

# 3. Create necessary directories with proper permissions
RUN mkdir -p /tftpboot /data/httpboot /data/downloads /run/nginx && \
    chown -R dnsmasq:dnsmasq /tftpboot && \
    chmod 755 /tftpboot && \
    chown -R www-data:www-data /data/httpboot && \
    chmod 755 /data/httpboot && \
    chown -R www-data:www-data /data/downloads && \
    chmod 755 /data/downloads

# 4. Copy configuration and scripts
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/*.template /config/
COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && \
    dos2unix /config/*.template && \
    chmod +x /entrypoint.sh

# 5. Expose ports and declare data volume
EXPOSE 80 69/udp 67/udp
VOLUME /data

# 6. Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
