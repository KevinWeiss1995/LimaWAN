#!/bin/bash
set -euo pipefail

# LimaWAN PF Port Forwarding Setup
# Safely configures macOS PF to forward WAN ports to Lima VM services

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
readonly ANCHOR_PATH="/etc/pf.anchors/limawan"
readonly MAIN_CONF_PATH="/etc/pf.conf"
readonly PF_CONF_BACKUP_PATH="/etc/pf.conf.bak"
readonly ANCHOR_NAME="limawan"
readonly DEFAULT_VM_IP="192.168.105.10"
readonly DEFAULT_HOST_INTERFACE="en0"
readonly EXTERNAL_PORT_RANGE="1024-65535"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
VM_IP="${VM_IP:-${DEFAULT_VM_IP}}"
HOST_INTERFACE="${HOST_INTERFACE:-${DEFAULT_HOST_INTERFACE}}"
INTERNAL_PORT=""
EXTERNAL_PORT=""
DRY_RUN=false
VERBOSE=false

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1" >&2
    fi
}

# Check if running as root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root"
        log_info "Usage: sudo $0 [OPTIONS]"
        exit 1
    fi
}

# Validate IP address format
validate_ip() {
    local ip="$1"
    if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: ${ip}"
        return 1
    fi
    
    # Check each octet is 0-255
    IFS='.' read -ra octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        if [[ "${octet}" -lt 0 || "${octet}" -gt 255 ]]; then
            log_error "Invalid IP address octet: ${octet}"
            return 1
        fi
    done
    
    return 0
}

# Validate port number
validate_port() {
    local port="$1"
    local port_type="$2"
    
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        log_error "Invalid ${port_type} port: ${port} (must be numeric)"
        return 1
    fi
    
    if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
        log_error "Invalid ${port_type} port: ${port} (must be 1-65535)"
        return 1
    fi
    
    # Check external port range restrictions
    if [[ "${port_type}" == "external" ]]; then
        local range_start range_end
        IFS='-' read -ra range_parts <<< "${EXTERNAL_PORT_RANGE}"
        range_start="${range_parts[0]}"
        range_end="${range_parts[1]}"
        
        if [[ "${port}" -lt "${range_start}" || "${port}" -gt "${range_end}" ]]; then
            log_error "External port ${port} outside allowed range ${EXTERNAL_PORT_RANGE}"
            return 1
        fi
    fi
    
    return 0
}

# Validate network interface exists
validate_interface() {
    local interface="$1"
    
    if ! ifconfig "${interface}" >/dev/null 2>&1; then
        log_error "Network interface ${interface} does not exist"
        return 1
    fi
    
    log_verbose "Network interface ${interface} validated"
    return 0
}

# Check if VM is reachable
check_vm_connectivity() {
    local vm_ip="$1"
    local internal_port="$2"
    
    log_info "Checking VM connectivity to ${vm_ip}:${internal_port}..."
    
    # Test ping connectivity
    if ! ping -c 1 -W 1000 "${vm_ip}" >/dev/null 2>&1; then
        log_warning "VM ${vm_ip} is not reachable via ping"
        return 1
    fi
    
    # Test port connectivity
    if ! nc -z -w 5 "${vm_ip}" "${internal_port}" 2>/dev/null; then
        log_warning "Port ${internal_port} is not open on VM ${vm_ip}"
        return 1
    fi
    
    log_success "VM ${vm_ip}:${internal_port} is reachable"
    return 0
}

# Backup existing PF configuration
backup_pf_config() {
    log_info "Backing up PF configuration..."
    
    if [[ -f "${MAIN_CONF_PATH}" ]]; then
        cp "${MAIN_CONF_PATH}" "${PF_CONF_BACKUP_PATH}"
        log_success "PF configuration backed up to ${PF_CONF_BACKUP_PATH}"
    else
        log_info "No existing PF configuration found"
        touch "${MAIN_CONF_PATH}"
    fi
}

# Create PF anchor directory
create_anchor_directory() {
    local anchor_dir
    anchor_dir="$(dirname "${ANCHOR_PATH}")"
    
    if [[ ! -d "${anchor_dir}" ]]; then
        mkdir -p "${anchor_dir}"
        log_verbose "Created anchor directory: ${anchor_dir}"
    fi
}

# Generate PF anchor rules
generate_anchor_rules() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    
    log_info "Generating PF anchor rules..."
    
    cat > "${ANCHOR_PATH}" << EOF
# LimaWAN PF Anchor Rules
# Generated on $(date)
# VM: ${vm_ip}:${internal_port} -> External: ${external_port}

# Port forwarding rule
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} rdr-to ${vm_ip} port ${internal_port}
pass out on ${host_interface} inet proto tcp from any to ${vm_ip} port ${internal_port}

# Allow established connections
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state
pass out on ${host_interface} inet proto tcp from ${vm_ip} to any nat-to (${host_interface})

# Additional security rules
# Block if no established connection
block in on ${host_interface} inet proto tcp from any to any port ${external_port} flags FPU/FPU

EOF
    
    log_success "PF anchor rules generated at ${ANCHOR_PATH}"
}

# Update main PF configuration
update_main_pf_config() {
    log_info "Updating main PF configuration..."
    
    # Check if anchor is already included
    if grep -q "anchor \"${ANCHOR_NAME}\"" "${MAIN_CONF_PATH}" 2>/dev/null; then
        log_info "LimaWAN anchor already exists in PF configuration"
        return 0
    fi
    
    # Add anchor to main config
    cat >> "${MAIN_CONF_PATH}" << EOF

# LimaWAN Port Forwarding Anchor
anchor "${ANCHOR_NAME}" {
    load anchor "${ANCHOR_NAME}" from "${ANCHOR_PATH}"
}

EOF
    
    log_success "LimaWAN anchor added to PF configuration"
}

# Validate PF configuration syntax
validate_pf_config() {
    log_info "Validating PF configuration syntax..."
    
    if ! pfctl -n -f "${MAIN_CONF_PATH}" 2>/dev/null; then
        log_error "PF configuration syntax validation failed"
        return 1
    fi
    
    log_success "PF configuration syntax is valid"
    return 0
}

# Reload PF configuration safely
reload_pf_config() {
    log_info "Reloading PF configuration..."
    
    # Enable PF if not already enabled
    if ! pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        log_info "Enabling PF..."
        pfctl -e
    fi
    
    # Load the configuration
    if ! pfctl -f "${MAIN_CONF_PATH}"; then
        log_error "Failed to reload PF configuration"
        return 1
    fi
    
    log_success "PF configuration reloaded successfully"
    return 0
}

# Show current PF status
show_pf_status() {
    log_info "Current PF Status:"
    echo "----------------------------------------"
    
    # PF general status
    pfctl -s info 2>/dev/null || echo "PF status unavailable"
    
    echo
    log_info "LimaWAN Anchor Rules:"
    pfctl -a "${ANCHOR_NAME}" -s rules 2>/dev/null || echo "No LimaWAN rules loaded"
    
    echo
    log_info "NAT Rules:"
    pfctl -a "${ANCHOR_NAME}" -s nat 2>/dev/null || echo "No NAT rules loaded"
    
    echo "----------------------------------------"
}

# Test port forwarding
test_port_forwarding() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    
    log_info "Testing port forwarding..."
    
    # Test VM connectivity first
    if ! check_vm_connectivity "${vm_ip}" "${internal_port}"; then
        log_error "VM connectivity test failed"
        return 1
    fi
    
    # Test external port is listening
    if ! netstat -an | grep -q "tcp.*\.${external_port}.*LISTEN"; then
        log_warning "External port ${external_port} may not be listening"
    fi
    
    # Test local forwarding
    if nc -z -w 5 localhost "${external_port}" 2>/dev/null; then
        log_success "Local port forwarding test passed"
    else
        log_warning "Local port forwarding test failed"
    fi
    
    log_info "Port forwarding test completed"
}

# Main setup function
setup_port_forwarding() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    
    log_info "Setting up port forwarding: ${vm_ip}:${internal_port} -> *:${external_port}"
    
    # Validate inputs
    validate_ip "${vm_ip}" || exit 1
    validate_port "${internal_port}" "internal" || exit 1
    validate_port "${external_port}" "external" || exit 1
    validate_interface "${host_interface}" || exit 1
    
    # Security warning for insecure ports
    if [[ "${external_port}" -eq 22 || "${external_port}" -eq 80 ]]; then
        log_warning "Exposing port ${external_port} to WAN - ensure proper security measures"
    fi
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN: Would configure port forwarding"
        return 0
    fi
    
    # Check VM connectivity
    check_vm_connectivity "${vm_ip}" "${internal_port}" || {
        log_error "VM connectivity check failed - proceeding anyway"
    }
    
    # Setup PF configuration
    backup_pf_config
    create_anchor_directory
    generate_anchor_rules "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}"
    update_main_pf_config
    
    # Validate and reload
    validate_pf_config || exit 1
    reload_pf_config || exit 1
    
    # Test the setup
    test_port_forwarding "${vm_ip}" "${internal_port}" "${external_port}"
    
    log_success "Port forwarding setup completed successfully"
    log_info "External port ${external_port} -> VM ${vm_ip}:${internal_port}"
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 -v VM_IP -i INTERNAL_PORT -e EXTERNAL_PORT [OPTIONS]

Configure PF port forwarding for Lima VM services.

Required Arguments:
    -v, --vm-ip IP          Lima VM IP address
    -i, --internal-port N   Internal port on VM
    -e, --external-port N   External port to expose (${EXTERNAL_PORT_RANGE})

Optional Arguments:
    -I, --interface IFACE   Host network interface (default: ${DEFAULT_HOST_INTERFACE})
    -n, --dry-run           Show what would be done without executing
    -V, --verbose           Enable verbose output
    -s, --status            Show current PF status
    -h, --help              Show this help message

Examples:
    $0 -v 192.168.105.10 -i 22 -e 2222    # Forward SSH
    $0 -v 192.168.105.10 -i 80 -e 8080    # Forward HTTP
    $0 --status                            # Show PF status
    $0 --dry-run -v 192.168.105.10 -i 22 -e 2222  # Test configuration

Security Notes:
    - Exposing ports 22 and 80 to WAN requires extra security measures
    - External ports are restricted to range ${EXTERNAL_PORT_RANGE}
    - Ensure VM has proper firewall and authentication configured
    - Consider using fail2ban or similar intrusion detection

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--vm-ip)
                VM_IP="$2"
                shift 2
                ;;
            -i|--internal-port)
                INTERNAL_PORT="$2"
                shift 2
                ;;
            -e|--external-port)
                EXTERNAL_PORT="$2"
                shift 2
                ;;
            -I|--interface)
                HOST_INTERFACE="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -V|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--status)
                show_pf_status
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    parse_arguments "$@"
    
    # Show status if requested
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi
    
    # Check required arguments
    if [[ -z "${INTERNAL_PORT}" || -z "${EXTERNAL_PORT}" ]]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi
    
    # Check root privileges
    check_root
    
    # Setup port forwarding
    setup_port_forwarding "${VM_IP}" "${INTERNAL_PORT}" "${EXTERNAL_PORT}" "${HOST_INTERFACE}"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 