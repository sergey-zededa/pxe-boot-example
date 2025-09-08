#!/bin/bash
set -e

# Configuration
TEST_NETWORK="ipxe-test"
TEST_SUBNET="192.168.53.0/24"
SERVER_IP="192.168.53.2"
TEST_EVE_VERSION="14.5.1-lts"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper Functions
log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

test_http_endpoint() {
    local endpoint=$1
    local expected_status=${2:-200}
    local status
    
    log_info "Testing HTTP endpoint: $endpoint"
    status=$(docker run --rm --network $TEST_NETWORK appropriate/curl -s -o /dev/null -w "%{http_code}" http://${SERVER_IP}${endpoint})
    
    if [ "$status" -eq "$expected_status" ]; then
        log_success "Endpoint $endpoint returned $status as expected"
        return 0
    else
        log_error "Endpoint $endpoint returned $status, expected $expected_status"
        return 1
    fi
}

test_file_exists() {
    local file=$1
    local container=$2
    
    log_info "Testing file existence: $file"
    if docker exec $container test -f "$file"; then
        log_success "File $file exists"
        return 0
    else
        log_error "File $file not found"
        return 1
    fi
}

test_file_permission() {
    local file=$1
    local container=$2
    local expected_perm=$3
    local expected_owner=$4
    local actual_perm
    local actual_owner
    
    log_info "Testing file permissions: $file"
    actual_perm=$(docker exec $container stat -c "%a" "$file")
    actual_owner=$(docker exec $container stat -c "%U:%G" "$file")
    
    if [ "$actual_perm" = "$expected_perm" ] && [ "$actual_owner" = "$expected_owner" ]; then
        log_success "File $file has correct permissions ($actual_perm) and ownership ($actual_owner)"
        return 0
    else
        log_error "File $file has incorrect permissions or ownership (got: $actual_perm $actual_owner, expected: $expected_perm $expected_owner)"
        return 1
    fi
}

# Setup Test Environment
log_info "Setting up test environment..."

# Clean up any existing resources
docker stop ipxe-server 2>/dev/null || true
docker rm ipxe-server 2>/dev/null || true
docker network rm $TEST_NETWORK 2>/dev/null || true

# Create test network
log_info "Creating test network: $TEST_NETWORK"
docker network create --subnet=$TEST_SUBNET $TEST_NETWORK

# Start server in test mode
log_info "Starting iPXE server in test mode..."
docker run -d --name ipxe-server \
    --network $TEST_NETWORK --ip $SERVER_IP \
    -v "$(pwd)/ipxe_data:/data" \
    -e EVE_VERSIONS="$TEST_EVE_VERSION" \
    -e SERVER_IP="$SERVER_IP" \
    -e LISTEN_INTERFACE="eth0" \
    -e DHCP_MODE="standalone" \
    -e DHCP_RANGE_START="192.168.53.10" \
    -e DHCP_RANGE_END="192.168.53.50" \
    -e DHCP_ROUTER="$SERVER_IP" \
    -e LOG_LEVEL="debug" \
    ipxe-server:latest

# Wait for server to initialize
log_info "Waiting for server initialization..."
sleep 5

# Test HTTP Service
log_info "Testing HTTP service..."
test_http_endpoint "/boot.ipxe"
test_http_endpoint "/${TEST_EVE_VERSION}/ipxe.efi.cfg"

# Test File Structure
log_info "Testing file structure and permissions..."

# Test /data/httpboot structure
test_file_exists "/data/httpboot/boot.ipxe" "ipxe-server"
test_file_exists "/data/httpboot/${TEST_EVE_VERSION}/ipxe.efi.cfg" "ipxe-server"
test_file_exists "/tftpboot/ipxe.efi" "ipxe-server"

# Test file permissions
test_file_permission "/data/httpboot/boot.ipxe" "ipxe-server" "644" "www-data:www-data"
test_file_permission "/data/httpboot/${TEST_EVE_VERSION}/ipxe.efi.cfg" "ipxe-server" "644" "www-data:www-data"
test_file_permission "/tftpboot/ipxe.efi" "ipxe-server" "644" "dnsmasq:dnsmasq"

# Test dnsmasq Configuration
log_info "Testing dnsmasq configuration..."
docker exec ipxe-server grep -q "dhcp-range=192.168.53.10,192.168.53.50" /etc/dnsmasq.conf || \
    log_error "Invalid DHCP range configuration"

docker exec ipxe-server grep -q "enable-tftp" /etc/dnsmasq.conf || \
    log_error "TFTP not enabled in dnsmasq configuration"

# Test iPXE Boot Menu
log_info "Testing iPXE boot menu..."
if ! docker exec ipxe-server grep -q "EVE-OS ${TEST_EVE_VERSION}" /data/httpboot/boot.ipxe; then
    log_error "EVE-OS version not found in boot menu"
fi

# Clean up
log_info "Cleaning up test environment..."
docker stop ipxe-server
docker rm ipxe-server
docker network rm $TEST_NETWORK

log_success "All tests completed successfully!"
