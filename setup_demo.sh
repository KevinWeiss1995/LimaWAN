#!/bin/bash
set -euo pipefail

# LimaWAN Complete Setup Demo
# This script demonstrates the complete workflow for setting up LimaWAN

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VM_NAME="limawan-demo"
readonly SSH_PORT=2222
readonly HTTP_PORT=8080

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v limactl >/dev/null 2>&1; then
        log_error "Lima is not installed. Please install with: brew install lima"
        exit 1
    fi
    
    if ! command -v pfctl >/dev/null 2>&1; then
        log_error "pfctl is not available. Are you running on macOS?"
        exit 1
    fi
    
    if [[ ! -f "/opt/socket_vmnet/bin/socket_vmnet" ]]; then
        log_error "socket_vmnet is not installed correctly."
        log_error "Please follow the installation instructions in README.md"
        exit 1
    fi
    
    if [[ ! -f "/etc/sudoers.d/lima" ]]; then
        log_error "Lima sudoers file is missing."
        log_error "Please run: limactl sudoers | sudo tee /etc/sudoers.d/lima"
        exit 1
    fi
    
    log_info "Prerequisites check passed!"
}

cleanup_existing() {
    log_info "Cleaning up any existing demo setup..."
    
    # Stop VM if running
    if limactl list | grep -q "^${VM_NAME}.*Running"; then
        log_info "Stopping existing VM: ${VM_NAME}"
        limactl stop "$VM_NAME"
    fi
    
    # Delete VM if exists
    if limactl list | grep -q "^${VM_NAME}"; then
        log_info "Deleting existing VM: ${VM_NAME}"
        limactl delete "$VM_NAME"
    fi
    
    # Remove PF rules
    if sudo pfctl -a limawan -s rules 2>/dev/null | grep -q .; then
        log_info "Removing existing PF rules..."
        sudo "${SCRIPT_DIR}/scripts/teardown_pf_forwarding.sh" -v || true
    fi
}

start_vm() {
    log_info "Starting Lima VM: ${VM_NAME}"
    
    # Start the VM
    limactl start --name "$VM_NAME" "${SCRIPT_DIR}/samples/lima.yaml"
    
    # Wait for VM to be ready
    log_info "Waiting for VM to be ready..."
    "${SCRIPT_DIR}/tools/get_vm_ip.sh" -w "$VM_NAME" >/dev/null
    
    # Get VM IP
    VM_IP=$("${SCRIPT_DIR}/tools/get_vm_ip.sh" -q "$VM_NAME")
    log_info "VM IP: ${VM_IP}"
}

setup_port_forwarding() {
    log_info "Setting up port forwarding..."
    
    # Setup SSH forwarding
    log_info "Setting up SSH forwarding (VM:22 -> Host:${SSH_PORT})"
    sudo "${SCRIPT_DIR}/scripts/setup_pf_forwarding.sh" -v "$VM_IP" -i 22 -e "$SSH_PORT"
    
    # Setup HTTP forwarding
    log_info "Setting up HTTP forwarding (VM:80 -> Host:${HTTP_PORT})"
    sudo "${SCRIPT_DIR}/scripts/setup_pf_forwarding.sh" -v "$VM_IP" -i 80 -e "$HTTP_PORT"
}

run_diagnostics() {
    log_info "Running diagnostics..."
    
    # Run diagnostic tests
    "${SCRIPT_DIR}/scripts/diagnostics.sh" -v "$VM_IP" -i 22 -e "$SSH_PORT"
    
    # Show configuration
    log_info "Current configuration:"
    "${SCRIPT_DIR}/tools/show_config.sh" --compact
}

test_connectivity() {
    log_info "Testing connectivity..."
    
    # Test SSH connectivity
    log_info "Testing SSH connectivity..."
    if "${SCRIPT_DIR}/test/test_ssh_access.sh" -e "$SSH_PORT"; then
        log_info "SSH test passed!"
    else
        log_warn "SSH test failed - this is expected if SSH keys are not set up"
    fi
    
    # Test HTTP connectivity
    log_info "Testing HTTP connectivity..."
    if timeout 5 curl -s "http://localhost:${HTTP_PORT}" >/dev/null; then
        log_info "HTTP test passed!"
    else
        log_warn "HTTP test failed - nginx may not be running yet"
    fi
}

print_summary() {
    echo ""
    echo "======================================================================"
    echo -e "${GREEN}🎉 LimaWAN Demo Setup Complete!${NC}"
    echo "======================================================================"
    echo ""
    echo "VM Information:"
    echo "  Name: ${VM_NAME}"
    echo "  IP: ${VM_IP}"
    echo "  Status: $(limactl list | grep "^${VM_NAME}" | awk '{print $2}')"
    echo ""
    echo "Port Forwarding:"
    echo "  SSH:  localhost:${SSH_PORT} -> ${VM_IP}:22"
    echo "  HTTP: localhost:${HTTP_PORT} -> ${VM_IP}:80"
    echo ""
    echo "Test Commands:"
    echo "  # SSH into VM (requires SSH keys)"
    echo "  ssh -p ${SSH_PORT} user@localhost"
    echo ""
    echo "  # Test HTTP service"
    echo "  curl http://localhost:${HTTP_PORT}"
    echo ""
    echo "  # Check VM status"
    echo "  limactl list"
    echo ""
    echo "  # Get VM IP"
    echo "  tools/get_vm_ip.sh ${VM_NAME}"
    echo ""
    echo "  # View configuration"
    echo "  tools/show_config.sh"
    echo ""
    echo "Cleanup:"
    echo "  # Stop and remove demo VM"
    echo "  limactl stop ${VM_NAME} && limactl delete ${VM_NAME}"
    echo ""
    echo "  # Remove PF rules"
    echo "  sudo scripts/teardown_pf_forwarding.sh -v"
    echo ""
    echo "======================================================================"
}

main() {
    log "Starting LimaWAN Demo Setup"
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root (sudo will be used when needed)"
        exit 1
    fi
    
    # Perform setup steps
    check_prerequisites
    cleanup_existing
    start_vm
    setup_port_forwarding
    run_diagnostics
    test_connectivity
    print_summary
    
    log "Demo setup complete!"
}

# Handle script interruption
trap 'log_error "Demo setup interrupted"; exit 1' INT TERM

main "$@" 