# EVE-OS iPXE Server

This project provides a self-contained, Docker-based iPXE server for network booting and installing multiple versions of EVE-OS.

## Features

- **Multi-Version Support**: Serve multiple EVE-OS versions from a single container.
- **iPXE Boot Menu**: An interactive menu on the client allows for manual selection of the desired EVE-OS version.
- **Timed Default Boot**: The menu automatically boots the default version after a configurable timeout.
- **Persistent Caching**: Avoids re-downloading EVE-OS images on every container start by using a Docker volume to cache files.
- **Flexible DHCP**: Can operate as a full standalone DHCP server or as a DHCP proxy in an existing network.

## Build

To build the Docker container, navigate to the project directory and run:

```sh
docker build -t ipxe-server:latest .
```

To force a rebuild without using Docker's cache, use the `--no-cache` flag.

## Usage

To run the container, you must provide a persistent volume for caching and several environment variables to configure the server. The container is best run on a Linux host where it can correctly bind to network services.

### Example `docker run` command:

```sh
docker run --rm -it --net=host --privileged \
   -v ./ipxe_data:/data \
   -e EVE_VERSIONS="14.5.1-lts,13.10.0" \
   -e SERVER_IP="192.168.1.50" \
   -e DHCP_MODE="proxy" \
   -e LOG_LEVEL="debug" \
   -e BOOT_MENU_TIMEOUT="20" \
   ipxe-server:latest
```

### Volume Configuration

- `-v ./ipxe_data:/data`: This is **required** for caching. It maps a directory named `ipxe_data` from your current location on the host to the `/data` directory inside the container. All downloaded EVE-OS images will be stored here.

### Environment Variables

| Variable | Description | Default | Example |
|---|---|---|---|
| `EVE_VERSIONS` | **(Required)** Comma-separated list of EVE-OS versions. The first version is the default for the boot menu. | | `"14.5.1-lts,13.10.0"` |
| `SERVER_IP` | **(Required)** The IP address of the host running the container. | | `192.168.1.50` |
| `BOOT_MENU_TIMEOUT` | Timeout in seconds for the boot menu before the default is chosen. | `15` | `30` |
| `LOG_LEVEL` | Set to `debug` for verbose logging. | `info` | `debug` |
| `DHCP_MODE` | `proxy` or `standalone`. | `proxy` | `standalone` |
| `PRIMARY_DHCP_IP` | In `proxy` mode, the IP of the primary DHCP server. (Optional) | (none) | `192.168.1.1` |
| `DHCP_RANGE_START`| In `standalone` mode, the start of the IP range to lease. | | `192.168.1.100` |
| `DHCP_RANGE_END`| In `standalone` mode, the end of the IP range to lease. | | `192.168.1.150` |
| `DHCP_SUBNET_MASK`| In `standalone` mode, the subnet mask for the lease. | `255.255.255.0` | `255.255.255.0` |
| `DHCP_ROUTER`| In `standalone` mode, the default gateway for clients. | | `192.168.1.1` |

