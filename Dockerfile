FROM debian:stable-slim

# 1. Install dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      dnsmasq \
      nginx \
      curl \
      tar \
      dos2unix \
      bash \
      p7zip-full \
      rsync \
      tcpdump \
      file \
      binutils \
      grub-efi-amd64-bin \
      grub-common && \
    rm -rf /var/lib/apt/lists/*

# 2. Create necessary directories with proper permissions
RUN mkdir -p /tftpboot /data/httpboot /data/downloads /run/nginx && \
    chown -R root:root /tftpboot && \
    chmod 755 /tftpboot && \
    chown -R www-data:www-data /data/httpboot && \
    chmod 755 /data/httpboot && \
    chown -R www-data:www-data /data/downloads && \
    chmod 755 /data/downloads

# 3. Copy configuration and scripts
COPY config/*.template /config/
COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && \
    dos2unix /config/*.template && \
    chmod +x /entrypoint.sh

# 4. Expose ports and declare data volume
EXPOSE 80 69/udp 67/udp
VOLUME /data

# 5. Set entrypoint (force bash to avoid /bin/sh running the script)
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
