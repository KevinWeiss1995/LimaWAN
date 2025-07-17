#!/bin/bash
set -euo pipefail

# LimaWAN VM IP Address Helper
# Gets the current IP address of a Lima VM

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_VM_NAME="limawan-vm"

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [VM_NAME]

Get the IP address of a Lima VM.

OPTIONS:
    -h, --help           Show this help message
    -v, --verbose        Verbose output
    -q, --quiet          Quiet output (IP only)
    -c, --check          Check if VM is running
    -w, --wait           Wait for VM to be ready

ARGUMENTS:
    VM_NAME             Name of the Lima VM (default: limawan-vm)

EXAMPLES:
    $0                              # Get IP of limawan-vm
    $0 web-server                   # Get IP of web-server VM
    $0 -q limawan-vm                # Get IP only (for scripting)
    $0 -w -v limawan-vm             # Wait and show verbose output

EXIT CODES:
    0    Success
    1    VM not found or not running
    2    Invalid arguments
    3    VM not ready
EOF
}

log() {
    if [[ "${QUIET:-false}" != "true" ]]; then
        echo -e "$@"
    fi
}

log_verbose() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        log "$@"
    fi
}

check_vm_running() {
    local vm_name="$1"
    
    if ! limactl list -f '{{.Name}}\t{{.Status}}' | grep -q "^${vm_name}[[:space:]]*Running$"; then
        log "${RED}ERROR: VM '${vm_name}' is not running${NC}"
        log "Available VMs:"
        limactl list
        return 1
    fi
    
    log_verbose "${GREEN}VM '${vm_name}' is running${NC}"
    return 0
}

wait_for_vm() {
    local vm_name="$1"
    local max_wait=30
    local count=0
    
    log_verbose "${YELLOW}Waiting for VM '${vm_name}' to be ready...${NC}"
    
    while [[ $count -lt $max_wait ]]; do
        if check_vm_running "$vm_name" >/dev/null 2>&1; then
            # Check if we can get IP
            if get_vm_ip "$vm_name" >/dev/null 2>&1; then
                log_verbose "${GREEN}VM '${vm_name}' is ready${NC}"
                return 0
            fi
        fi
        
        sleep 1
        ((count++))
        log_verbose "Waiting... ($count/$max_wait)"
    done
    
    log "${RED}ERROR: VM '${vm_name}' not ready after ${max_wait}s${NC}"
    return 3
}

get_vm_ip() {
    local vm_name="$1"
    local ip
    
    log_verbose "Getting IP address for VM: ${vm_name}" >&2
    
    # Try to get IP from lima0 interface
    ip=$(limactl shell "$vm_name" ip addr show lima0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
    
    if [[ -z "$ip" ]]; then
        # Fallback: try to get any 192.168.105.x IP
        ip=$(limactl shell "$vm_name" ip addr 2>/dev/null | grep "inet 192.168.105" | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi
    
    if [[ -z "$ip" ]]; then
        log "${RED}ERROR: Could not get IP address for VM '${vm_name}'${NC}" >&2
        return 1
    fi
    
    echo "$ip"
    return 0
}

main() {
    local vm_name="$DEFAULT_VM_NAME"
    local check_running=false
    local wait_for_ready=false
    
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
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -c|--check)
                check_running=true
                shift
                ;;
            -w|--wait)
                wait_for_ready=true
                shift
                ;;
            -*)
                log "${RED}ERROR: Unknown option: $1${NC}"
                usage
                exit 2
                ;;
            *)
                vm_name="$1"
                shift
                ;;
        esac
    done
    
    # Wait for VM if requested
    if [[ "$wait_for_ready" == "true" ]]; then
        wait_for_vm "$vm_name"
    fi
    
    # Check if VM is running
    if [[ "$check_running" == "true" ]] || [[ "$wait_for_ready" == "true" ]]; then
        if ! check_vm_running "$vm_name"; then
            exit 1
        fi
    fi
    
    # Get IP address
    local ip
    if ip=$(get_vm_ip "$vm_name"); then
        if [[ "${QUIET:-false}" == "true" ]]; then
            echo "$ip"
        else
            log "${GREEN}VM '${vm_name}' IP: ${ip}${NC}"
        fi
        exit 0
    else
        exit 1
    fi
}

main "$@" 