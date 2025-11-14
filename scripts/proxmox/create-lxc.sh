#!/bin/bash
###############################################################################
# Proxmox LXC Container Creation Script
# Creates privileged LXC containers for Pterodactyl Panel and Wings
###############################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Create LXC containers for Pterodactyl deployment

OPTIONS:
    -t, --type TYPE         Container type: panel or wings (required)
    -i, --id ID            Container ID (required)
    -h, --hostname NAME    Container hostname (required)
    -ip, --ip-address IP   IP address with CIDR (e.g., 10.0.0.2/24)
    -g, --gateway IP       Gateway IP address
    -c, --cores NUM        CPU cores (default: 2 for panel, 4 for wings)
    -m, --memory MB        Memory in MB (default: 4096 for panel, 8192 for wings)
    -s, --swap MB          Swap in MB (default: 512 for panel, 1024 for wings)
    -d, --disk GB          Disk size in GB (default: 20 for panel, 50 for wings)
    --storage STORAGE      Storage location (default: local-lvm)
    --template TEMPLATE    OS template (default: local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst)
    --bridge BRIDGE        Network bridge (default: vmbr1)
    --start                Start container after creation
    --help                 Show this help message

EXAMPLES:
    # Create Panel container
    $0 -t panel -i 200 -h pterodactyl-panel -ip 10.0.0.2/24 -g 10.0.0.1 --start

    # Create Wings container with custom resources
    $0 -t wings -i 201 -h pterodactyl-wings -ip 10.0.0.3/24 -g 10.0.0.1 -c 8 -m 16384 --start

EOF
    exit 1
}

# Default values
CONTAINER_TYPE=""
CONTAINER_ID=""
HOSTNAME=""
IP_ADDRESS=""
GATEWAY=""
CORES=""
MEMORY=""
SWAP=""
DISK_SIZE=""
STORAGE="local-lvm"
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
BRIDGE="vmbr1"
START_CONTAINER=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            CONTAINER_TYPE="$2"
            shift 2
            ;;
        -i|--id)
            CONTAINER_ID="$2"
            shift 2
            ;;
        -h|--hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        -ip|--ip-address)
            IP_ADDRESS="$2"
            shift 2
            ;;
        -g|--gateway)
            GATEWAY="$2"
            shift 2
            ;;
        -c|--cores)
            CORES="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -s|--swap)
            SWAP="$2"
            shift 2
            ;;
        -d|--disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        --storage)
            STORAGE="$2"
            shift 2
            ;;
        --template)
            TEMPLATE="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --start)
            START_CONTAINER=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$CONTAINER_TYPE" ]] || [[ -z "$CONTAINER_ID" ]] || [[ -z "$HOSTNAME" ]]; then
    log_error "Missing required parameters"
    usage
fi

# Set defaults based on container type
if [[ "$CONTAINER_TYPE" == "panel" ]]; then
    CORES="${CORES:-2}"
    MEMORY="${MEMORY:-4096}"
    SWAP="${SWAP:-512}"
    DISK_SIZE="${DISK_SIZE:-20}"
    FEATURES="nesting=0"
elif [[ "$CONTAINER_TYPE" == "wings" ]]; then
    CORES="${CORES:-4}"
    MEMORY="${MEMORY:-8192}"
    SWAP="${SWAP:-1024}"
    DISK_SIZE="${DISK_SIZE:-50}"
    FEATURES="nesting=1,keyctl=1"  # Required for Docker
else
    log_error "Invalid container type: $CONTAINER_TYPE (must be 'panel' or 'wings')"
    exit 1
fi

# Check if container already exists
if pct status "$CONTAINER_ID" &>/dev/null; then
    log_error "Container $CONTAINER_ID already exists"
    log_info "Use 'pct destroy $CONTAINER_ID' to remove it first"
    exit 1
fi

# Verify template exists
if ! pveam list local | grep -q "$(basename $TEMPLATE)"; then
    log_warn "Template not found locally. Available templates:"
    pveam available | grep ubuntu
    log_info "Download template with: pveam download local $(basename $TEMPLATE)"
    exit 1
fi

log_info "Creating $CONTAINER_TYPE container with ID $CONTAINER_ID..."
log_info "Hostname: $HOSTNAME"
log_info "Resources: ${CORES} cores, ${MEMORY}MB RAM, ${SWAP}MB swap, ${DISK_SIZE}GB disk"

# Create container
pct create "$CONTAINER_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --ostype ubuntu \
    --arch amd64 \
    --features "$FEATURES" \
    --unprivileged 0 \
    --onboot 1 \
    --description "Pterodactyl ${CONTAINER_TYPE^} - Managed by GitHub Actions"

log_info "Container created successfully"

# Configure network if IP provided
if [[ -n "$IP_ADDRESS" ]]; then
    log_info "Configuring network: $IP_ADDRESS on $BRIDGE"
    
    if [[ -n "$GATEWAY" ]]; then
        pct set "$CONTAINER_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_ADDRESS},gw=${GATEWAY}"
    else
        pct set "$CONTAINER_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_ADDRESS}"
    fi
    
    log_info "Network configured successfully"
fi

# Set DNS nameservers
log_info "Configuring DNS servers..."
pct set "$CONTAINER_ID" --nameserver "8.8.8.8 8.8.4.4"

# Start container if requested
if [[ "$START_CONTAINER" == true ]]; then
    log_info "Starting container..."
    pct start "$CONTAINER_ID"
    
    # Wait for container to be ready
    log_info "Waiting for container to start..."
    sleep 5
    
    # Check if container is running
    if pct status "$CONTAINER_ID" | grep -q "running"; then
        log_info "Container started successfully"
        
        # Run initial setup
        log_info "Running initial container setup..."
        pct exec "$CONTAINER_ID" -- bash -c "apt-get update && apt-get upgrade -y"
        pct exec "$CONTAINER_ID" -- bash -c "apt-get install -y curl wget sudo systemd"
        
        log_info "Initial setup complete"
    else
        log_error "Container failed to start"
        exit 1
    fi
fi

log_info "Container creation completed successfully!"
log_info "Container ID: $CONTAINER_ID"
log_info "Hostname: $HOSTNAME"
log_info "Type: $CONTAINER_TYPE"
[[ -n "$IP_ADDRESS" ]] && log_info "IP Address: $IP_ADDRESS"
log_info ""
log_info "Useful commands:"
log_info "  Start:   pct start $CONTAINER_ID"
log_info "  Stop:    pct stop $CONTAINER_ID"
log_info "  Enter:   pct enter $CONTAINER_ID"
log_info "  Status:  pct status $CONTAINER_ID"
log_info "  Destroy: pct destroy $CONTAINER_ID"
