#!/bin/bash
set -euo pipefail

# LimaWAN Quick Start Script
# Fast VM startup with optional security hardening

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DEFAULT_VM_NAME="limawan-vm"

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Quick start script for LimaWAN with two-phase security approach:
1. Fast VM startup with minimal configuration (2-3 minutes)
2. Optional comprehensive security hardening

OPTIONS:
    -h, --help           Show this help message
    -v, --verbose        Verbose output
    --secure             Apply security hardening after startup
    --ssh-only           Only configure SSH hardening
    --no-start           Don't start VM (useful for testing)
    --clean              Clean up and restart VM

WORKFLOW:
    Phase 1: Fast startup (always)
    - Start Lima VM with minimal config
    - Basic nginx setup for testing
    - Ready for port forwarding in ~2-3 minutes

    Phase 2: Security hardening (optional)
    - SSH key authentication only
    - UFW firewall configuration
    - Fail2ban protection
    - System updates and hardening

EXAMPLES:
    $0                              # Quick start only
    $0 --secure                     # Quick start + full security
    $0 --ssh-only                   # Quick start + SSH hardening only
    $0 --clean --secure             # Clean restart + security

EOF
}

log() {
    echo -e "${BLUE}[LIMAWAN]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_verbose() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*"
    fi
}

cleanup_vm() {
    local vm_name="$1"
    
    log "Cleaning up existing VM..."
    
    if limactl list -f '{{.Name}}' | grep -q "^${vm_name}$"; then
        limactl delete "$vm_name" --force
        log_success "Removed existing VM"
    else
        log_verbose "No existing VM to remove"
    fi
}

start_vm() {
    local vm_name="$1"
    
    log "Starting Lima VM with minimal configuration..."
    log_warn "This will take 2-3 minutes (much faster than full security setup)"
    
    # Start VM with socket_vmnet config for direct host access
    limactl start --name="$vm_name" "$PROJECT_DIR/samples/lima-socket-vmnet.yaml"
    
    # Wait for VM to be fully ready
    local max_wait=180
    local count=0
    
    while [[ $count -lt $max_wait ]]; do
        if "$PROJECT_DIR/tools/get_vm_ip.sh" -q "$vm_name" >/dev/null 2>&1; then
            log_success "VM started successfully"
            return 0
        fi
        sleep 2
        ((count+=2))
        log_verbose "Waiting for VM to be ready... ($count/$max_wait)s"
    done
    
    log_error "VM failed to start within ${max_wait}s"
    return 1
}

show_vm_info() {
    local vm_name="$1"
    
    log "VM Information:"
    echo
    
    # Get VM IP
    local vm_ip
    if vm_ip=$("$PROJECT_DIR/tools/get_vm_ip.sh" -q "$vm_name"); then
        log_success "VM IP: $vm_ip"
    else
        log_error "Could not get VM IP"
        return 1
    fi
    
    # Show VM status
    echo -e "${GREEN}VM Status:${NC}"
    limactl list | grep "$vm_name"
    echo
    
    # Test nginx
    if limactl shell "$vm_name" systemctl is-active nginx >/dev/null 2>&1; then
        log_success "Nginx is running"
    else
        log_warn "Nginx is not running"
    fi
    
    echo
    log "Next steps:"
    log "1. Set up port forwarding:"
    log "   VM_IP=$vm_ip"
    log "   sudo scripts/setup_pf_forwarding.sh -v \$VM_IP -i 22 -e 2222"
    log "   sudo scripts/setup_pf_forwarding.sh -v \$VM_IP -i 80 -e 8080"
    log
    log "2. Test access:"
    log "   ssh -p 2222 \$USER@localhost"
    log "   curl http://localhost:8080"
    log
    log "3. Optional: Run security hardening:"
    log "   scripts/security_hardening.sh $vm_name"
    echo
}

apply_security_hardening() {
    local vm_name="$1"
    local security_type="$2"
    
    log "Applying security hardening..."
    log_warn "This will take 5-10 minutes and requires internet access"
    
    case "$security_type" in
        "ssh")
            "$PROJECT_DIR/scripts/security_hardening.sh" --ssh-only "$vm_name"
            ;;
        "full")
            "$PROJECT_DIR/scripts/security_hardening.sh" --verbose "$vm_name"
            ;;
        *)
            log_error "Unknown security type: $security_type"
            return 1
            ;;
    esac
    
    log_success "Security hardening complete"
}

main() {
    local vm_name="$DEFAULT_VM_NAME"
    local apply_security=false
    local security_type="full"
    local clean=false
    local no_start=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --secure)
                apply_security=true
                security_type="full"
                shift
                ;;
            --ssh-only)
                apply_security=true
                security_type="ssh"
                shift
                ;;
            --clean)
                clean=true
                shift
                ;;
            --no-start)
                no_start=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
            *)
                vm_name="$1"
                shift
                ;;
        esac
    done
    
    log "LimaWAN Quick Start"
    log "VM Name: $vm_name"
    log "Security: ${apply_security:-false} (${security_type:-none})"
    echo
    
    # Clean up if requested
    if [[ "$clean" == "true" ]]; then
        cleanup_vm "$vm_name"
    fi
    
    # Start VM unless --no-start
    if [[ "$no_start" != "true" ]]; then
        # Check if VM exists and is running
        if limactl list -f '{{.Name}}\t{{.Status}}' | awk -v vm="$vm_name" '$1 == vm && $2 == "Running" {exit 0} END {exit 1}'; then
            log_success "VM is already running"
        elif limactl list -f '{{.Name}}' | grep -q "^${vm_name}$"; then
            log "VM exists but is not running, starting..."
            limactl start "$vm_name"
        else
            start_vm "$vm_name"
        fi
        
        # Show VM info
        show_vm_info "$vm_name"
    fi
    
    # Apply security hardening if requested
    if [[ "$apply_security" == "true" ]]; then
        apply_security_hardening "$vm_name" "$security_type"
    fi
    
    log_success "Quick start complete!"
}

main "$@" 