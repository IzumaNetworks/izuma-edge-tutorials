#!/bin/bash

# Debug script for Izuma Edge connectivity and edge-core logs
# Tests connectivity to Device Management servers and captures edge-core logs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
LOG_DIR="/tmp/edge-debug-$(date +%Y%m%d-%H%M%S)"
EDGE_CORE_CONTAINER="edge-core"
# Cap docker logs (recent, timestamped, stopped) so bundles stay bounded
DOCKER_LOG_TAIL=4000
TIMEOUT=10

# Endpoints to test
TCP_BOOTSTRAP_HOST="tcp-bootstrap.us-east-1.mbedcloud.com"
TCP_LWM2M_HOST="tcp-lwm2m.us-east-1.mbedcloud.com"
UDP_BOOTSTRAP_HOST="udp-bootstrap.us-east-1.mbedcloud.com"
UDP_LWM2M_HOST="udp-lwm2m.us-east-1.mbedcloud.com"
TCP_PORT=443
UDP_PORT=5684

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Izuma Edge Connectivity Debug Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Timestamp: $(date)"
echo "Log directory: $LOG_DIR"
echo ""

# Create log directory
mkdir -p "$LOG_DIR"

# Function to print status
print_status() {
    local status=$1
    local message=$2
    if [ "$status" = "SUCCESS" ]; then
        echo -e "${GREEN}✓${NC} $message"
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}✗${NC} $message"
    elif [ "$status" = "INFO" ]; then
        echo -e "${BLUE}ℹ${NC} $message"
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
    fi
}

# Function to test TCP connectivity
test_tcp_connectivity() {
    local host=$1
    local port=$2
    local service_name=$3
    
    echo -e "\n${BLUE}Testing TCP connectivity to $service_name${NC}"
    echo "Host: $host"
    echo "Port: $port"
    
    # Test with netcat
    if timeout $TIMEOUT nc -vz "$host" "$port" 2>&1 | tee "$LOG_DIR/tcp-${service_name}-nc.log"; then
        print_status "SUCCESS" "TCP connection to $service_name successful"
    else
        print_status "FAIL" "TCP connection to $service_name failed"
    fi
    
    # Test with telnet
    echo "Testing with telnet..."
    timeout $TIMEOUT telnet "$host" "$port" 2>&1 | tee "$LOG_DIR/tcp-${service_name}-telnet.log" || true
    
    # DNS resolution test
    echo "Testing DNS resolution..."
    nslookup "$host" 2>&1 | tee "$LOG_DIR/tcp-${service_name}-dns.log"
}

# Function to test UDP connectivity
test_udp_connectivity() {
    local host=$1
    local port=$2
    local service_name=$3
    
    echo -e "\n${BLUE}Testing UDP connectivity to $service_name${NC}"
    echo "Host: $host"
    echo "Port: $port"
    
    # Test with netcat UDP
    if timeout $TIMEOUT nc -u -vz "$host" "$port" 2>&1 | tee "$LOG_DIR/udp-${service_name}-nc.log"; then
        print_status "SUCCESS" "UDP connection to $service_name successful"
    else
        print_status "FAIL" "UDP connection to $service_name failed"
    fi
    
    # DNS resolution test
    echo "Testing DNS resolution..."
    nslookup "$host" 2>&1 | tee "$LOG_DIR/udp-${service_name}-dns.log"
}

# Function to test SSL/TLS connectivity
test_ssl_connectivity() {
    local host=$1
    local port=$2
    local service_name=$3
    
    echo -e "\n${BLUE}Testing SSL/TLS connectivity to $service_name${NC}"
    echo "Host: $host"
    echo "Port: $port"
    
    # Test basic SSL connection
    echo "Testing basic SSL connection..."
    timeout $TIMEOUT openssl s_client -connect "$host:$port" -servername "$host" 2>&1 | tee "$LOG_DIR/ssl-${service_name}-basic.log" || true
    
    # Test with device certificates if they exist
    local bootstrap_cert="/var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/bootstrap_dev.cert.pem"
    local bootstrap_key="/var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/bootstrap_dev.key.pem"
    local lwm2m_cert="/var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDeviceCert.pem"
    local lwm2m_key="/var/lib/pelion/mbed/ec-kcm-conf/runtime/device-certs/LwM2MDevicePrivateKey.pem"
    
    if [ "$service_name" = "bootstrap" ] && [ -f "$bootstrap_cert" ] && [ -f "$bootstrap_key" ]; then
        echo "Testing SSL connection with bootstrap device certificate..."
        timeout $TIMEOUT openssl s_client \
            -connect "$host:$port" \
            -cert "$bootstrap_cert" \
            -key "$bootstrap_key" \
            -servername "$host" 2>&1 | tee "$LOG_DIR/ssl-${service_name}-device-cert.log" || true
    elif [ "$service_name" = "lwm2m" ] && [ -f "$lwm2m_cert" ] && [ -f "$lwm2m_key" ]; then
        echo "Testing SSL connection with LwM2M device certificate..."
        timeout $TIMEOUT openssl s_client \
            -connect "$host:$port" \
            -cert "$lwm2m_cert" \
            -key "$lwm2m_key" \
            -servername "$host" 2>&1 | tee "$LOG_DIR/ssl-${service_name}-device-cert.log" || true
    else
        print_status "INFO" "Device certificates not found for $service_name, skipping device cert test"
    fi
}

# Resolve edge container: prefer exact EDGE_CORE_CONTAINER name, else first name matching -i edge
resolve_edge_container() {
    if docker ps -a --format '{{.Names}}' | grep -qxF "$EDGE_CORE_CONTAINER"; then
        echo "$EDGE_CORE_CONTAINER"
        return 0
    fi
    docker ps -a --format '{{.Names}}' | grep -i edge | head -n 1 || true
}

# Function to capture edge-core logs
capture_edge_core_logs() {
    echo -e "\n${BLUE}Capturing edge-core logs${NC}"

    local edge_container
    edge_container=$(resolve_edge_container)

    if [ -z "$edge_container" ]; then
        print_status "FAIL" "No edge container found (tried exact name '${EDGE_CORE_CONTAINER}' and names matching 'edge')"
        echo "No edge-core container found via name match. Verify container name." | tee "$LOG_DIR/edge-core-resolve.log"
        return 0
    fi

    print_status "INFO" "Using container: $edge_container"
    echo "Detected edge container: $edge_container" | tee "$LOG_DIR/edge-core-resolve.log"

    # Container start time and env (same probes as standalone debug scripts)
    echo "Container started at:"
    docker inspect -f '{{.State.StartedAt}}' "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-started-at.log"
    echo "Container environment:"
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-env.log"

    # Check if edge container is running
    if docker ps --format '{{.Names}}' | grep -qxF "$edge_container"; then
        print_status "SUCCESS" "Edge container is running"
        
        # Capture recent logs (capped)
        echo "Capturing recent edge-core logs (last $DOCKER_LOG_TAIL lines)..."
        docker logs --tail "$DOCKER_LOG_TAIL" "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-recent.log"
        
        # Capture logs with timestamps (capped)
        echo "Capturing edge-core logs with timestamps (last $DOCKER_LOG_TAIL lines)..."
        docker logs --tail "$DOCKER_LOG_TAIL" --timestamps "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-timestamped.log"
        
        # Get container status
        echo "Getting edge-core container status..."
        docker inspect "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-inspect.log"
        
        # Get container stats
        echo "Getting edge-core container stats..."
        docker stats --no-stream "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-stats.log"
        
    else
        print_status "WARN" "Edge container is not running"
        
        # Stopped container: still capture capped logs and inspect
        print_status "INFO" "Edge container exists but is stopped"
        docker logs --tail "$DOCKER_LOG_TAIL" "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-stopped.log"
        docker inspect "$edge_container" 2>&1 | tee "$LOG_DIR/edge-core-inspect.log"
    fi
}

# Function to capture system information
capture_system_info() {
    echo -e "\n${BLUE}Capturing system information${NC}"
    
    # System info
    echo "System information:"
    date 2>&1 | tee "$LOG_DIR/system-date.log"
    uname -a 2>&1 | tee "$LOG_DIR/system-uname.log"
    lsb_release -a 2>&1 | tee "$LOG_DIR/system-lsb.log"
    uptime 2>&1 | tee "$LOG_DIR/system-uptime.log"
    free -h 2>&1 | tee "$LOG_DIR/system-memory.log"
    df -hT / 2>&1 | tee "$LOG_DIR/system-disk.log"
    
    # Network info
    echo "Network information:"
    ip addr show 2>&1 | tee "$LOG_DIR/network-interfaces.log"
    ip route show 2>&1 | tee "$LOG_DIR/network-routes.log"
    
    # Docker info
    echo "Docker information:"
    docker version 2>&1 | tee "$LOG_DIR/docker-version.log"
    docker info 2>&1 | tee "$LOG_DIR/docker-info.log"
    docker ps -a 2>&1 | tee "$LOG_DIR/docker-containers.log"

    # Kubernetes (optional)
    if command -v kubectl >/dev/null 2>&1; then
        echo "Kubernetes nodes:"
        kubectl get nodes -o wide 2>&1 | tee "$LOG_DIR/kubernetes-nodes.log" || true
    fi
    
    # Edge services status
    echo "Edge services status:"
    systemctl --no-pager status edge-proxy 2>&1 | tee "$LOG_DIR/service-edge-proxy.log" || true
    systemctl --no-pager status kubelet 2>&1 | tee "$LOG_DIR/service-kubelet.log" || true
    systemctl --no-pager status kube-router 2>&1 | tee "$LOG_DIR/service-kube-router.log" || true
    systemctl --no-pager status coredns 2>&1 | tee "$LOG_DIR/service-coredns.log" || true
    
    # Edge info
    if command -v edge-info >/dev/null 2>&1; then
        echo "Edge info:"
        sudo edge-info -m 2>&1 | tee "$LOG_DIR/edge-info.log" || true
    fi
}

# Function to test edge-core HTTP endpoint
test_edge_core_endpoint() {
    echo -e "\n${BLUE}Testing edge-core HTTP endpoint${NC}"
    
    # Test localhost:9101/status
    if curl -s --connect-timeout $TIMEOUT localhost:9101/status 2>&1 | tee "$LOG_DIR/edge-core-status.log"; then
        print_status "SUCCESS" "Edge-core HTTP endpoint accessible"
        
        # Try to parse JSON if jq is available
        if command -v jq >/dev/null 2>&1; then
            echo "Parsed status:"
            curl -s localhost:9101/status | jq . 2>&1 | tee "$LOG_DIR/edge-core-status-parsed.log"
        fi
    else
        print_status "FAIL" "Edge-core HTTP endpoint not accessible"
    fi
}

# Main execution
main() {
    echo "Starting Izuma Edge connectivity debug..."
    
    # Capture system information first
    capture_system_info
    
    # Test edge-core endpoint
    test_edge_core_endpoint
    
    # Capture edge-core logs
    capture_edge_core_logs
    
    # Test TCP connectivity
    test_tcp_connectivity "$TCP_BOOTSTRAP_HOST" "$TCP_PORT" "bootstrap"
    test_tcp_connectivity "$TCP_LWM2M_HOST" "$TCP_PORT" "lwm2m"
    
    # Test UDP connectivity
    test_udp_connectivity "$UDP_BOOTSTRAP_HOST" "$UDP_PORT" "bootstrap"
    test_udp_connectivity "$UDP_LWM2M_HOST" "$UDP_PORT" "lwm2m"
    
    # Test SSL/TLS connectivity
    test_ssl_connectivity "$TCP_BOOTSTRAP_HOST" "$TCP_PORT" "bootstrap"
    test_ssl_connectivity "$TCP_LWM2M_HOST" "$TCP_PORT" "lwm2m"
    
    # Create tar archive of log directory
    echo -e "\n${BLUE}Creating tar archive of log directory${NC}"
    local tar_file="${LOG_DIR}.tar.gz"
    if tar -czf "$tar_file" -C "$(dirname "$LOG_DIR")" "$(basename "$LOG_DIR")" 2>&1 | tee "$LOG_DIR/tar-creation.log"; then
        print_status "SUCCESS" "Tar archive created: $tar_file"
        echo "Archive size: $(du -h "$tar_file" | cut -f1)"
    else
        print_status "FAIL" "Failed to create tar archive"
    fi
    
    # Create summary
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Debug Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "All logs have been captured in: $LOG_DIR"
    echo "Tar archive created: $tar_file"
    echo ""
    echo "Log files created:"
    ls -la "$LOG_DIR" | grep -v "^total"
    echo ""
    echo "To view specific logs:"
    echo "  cat $LOG_DIR/edge-core-recent.log"
    echo "  cat $LOG_DIR/tcp-bootstrap-nc.log"
    echo "  cat $LOG_DIR/udp-lwm2m-nc.log"
    echo ""
    echo "To view all connectivity test results:"
    echo "  grep -E '(SUCCESS|FAIL)' $LOG_DIR/*.log"
    echo ""
    echo "To extract the tar archive:"
    echo "  tar -xzf $tar_file"
    echo ""
    print_status "INFO" "Debug session completed. Check logs in $LOG_DIR for detailed results."
    print_status "INFO" "Tar archive available at: $tar_file"
}

# Run main function
main "$@"
