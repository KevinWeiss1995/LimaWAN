#!/bin/bash
set -euo pipefail

# LimaWAN Anchor Generator
# CLI tool to generate PF anchor rule snippets

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
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
VM_IP="${DEFAULT_VM_IP}"
HOST_INTERFACE="${DEFAULT_HOST_INTERFACE}"
INTERNAL_PORT=""
EXTERNAL_PORT=""
SERVICE_NAME=""
OUTPUT_FILE=""
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

# Validate IP address
validate_ip() {
    local ip="$1"
    if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: ${ip}"
        return 1
    fi
    
    IFS='.' read -ra octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        if [[ "${octet}" -lt 0 || "${octet}" -gt 255 ]]; then
            log_error "Invalid IP address octet: ${octet}"
            return 1
        fi
    done
    
    return 0
}

# Validate port
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

# Generate basic port forwarding rules
generate_port_forward_rules() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    local service_name="$5"
    
    cat << EOF
# ${service_name} Port Forwarding Rules
# Generated on $(date)
# VM: ${vm_ip}:${internal_port} -> External: ${external_port}

# Port forwarding rule
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} rdr-to ${vm_ip} port ${internal_port}
pass out on ${host_interface} inet proto tcp from any to ${vm_ip} port ${internal_port}

# Allow established connections
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state
pass out on ${host_interface} inet proto tcp from ${vm_ip} to any nat-to (${host_interface})

# Security rules
block in on ${host_interface} inet proto tcp from any to any port ${external_port} flags FPU/FPU

EOF
}

# Generate SSH-specific rules
generate_ssh_rules() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    
    cat << EOF
# SSH Port Forwarding Rules
# Generated on $(date)
# VM: ${vm_ip}:${internal_port} -> External: ${external_port}

# SSH port forwarding
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} rdr-to ${vm_ip} port ${internal_port}
pass out on ${host_interface} inet proto tcp from any to ${vm_ip} port ${internal_port}

# SSH connection tracking
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state
pass out on ${host_interface} inet proto tcp from ${vm_ip} to any nat-to (${host_interface})

# SSH security rules
block in on ${host_interface} inet proto tcp from any to any port ${external_port} flags FPU/FPU
block in on ${host_interface} inet proto tcp from any to any port ${external_port} flags F/F

# Rate limiting for SSH (optional - uncomment if needed)
# pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state (max-src-conn 5, max-src-conn-rate 3/60, overload <ssh_abusers> flush global)

EOF
}

# Generate HTTP/HTTPS rules
generate_web_rules() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    
    local service_type="HTTP"
    if [[ "${internal_port}" == "443" || "${external_port}" == "443" ]]; then
        service_type="HTTPS"
    fi
    
    cat << EOF
# ${service_type} Port Forwarding Rules
# Generated on $(date)
# VM: ${vm_ip}:${internal_port} -> External: ${external_port}

# ${service_type} port forwarding
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} rdr-to ${vm_ip} port ${internal_port}
pass out on ${host_interface} inet proto tcp from any to ${vm_ip} port ${internal_port}

# ${service_type} connection tracking
pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state
pass out on ${host_interface} inet proto tcp from ${vm_ip} to any nat-to (${host_interface})

# ${service_type} security rules
block in on ${host_interface} inet proto tcp from any to any port ${external_port} flags FPU/FPU

# Optional: Rate limiting for web services
# pass in on ${host_interface} inet proto tcp from any to any port ${external_port} flags S/SA keep state (max-src-conn 100, max-src-conn-rate 50/10)

EOF
}

# Generate complete anchor file
generate_complete_anchor() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    local service_name="$5"
    
    cat << EOF
# LimaWAN Complete Anchor Configuration
# Generated on $(date)
# Service: ${service_name}
# VM: ${vm_ip}:${internal_port} -> External: ${external_port}

# Skip loopback
set skip on lo0

# Default policies
set block-policy return
set fingerprints "/etc/pf.os"
set ruleset-optimization basic

# Normalization
scrub in all no-df
scrub out all no-df

# Variables
vm_ip = "${vm_ip}"
host_if = "${host_interface}"
service_port = "${external_port}"
internal_port = "${internal_port}"

# Tables for IP management
table <trusted_ips> persist
table <blocked_ips> persist

EOF

    # Add service-specific rules
    case "${service_name}" in
        "SSH"|"ssh")
            generate_ssh_rules "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}"
            ;;
        "HTTP"|"http"|"HTTPS"|"https"|"Web"|"web")
            generate_web_rules "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}"
            ;;
        *)
            generate_port_forward_rules "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}" "${service_name}"
            ;;
    esac

    cat << EOF
# ICMP rules
pass inet proto icmp all icmp-type echoreq
pass inet proto icmp all icmp-type unreach

# DNS rules
pass out on ${host_interface} inet proto udp from any to any port 53
pass out on ${host_interface} inet proto tcp from any to any port 53

# Anti-spoofing
antispoof for ${host_interface}

# Default allow outbound
pass out on ${host_interface} all keep state

EOF
}

# Get service name from port
get_service_name() {
    local port="$1"
    
    case "${port}" in
        "22") echo "SSH" ;;
        "80") echo "HTTP" ;;
        "443") echo "HTTPS" ;;
        "25") echo "SMTP" ;;
        "53") echo "DNS" ;;
        "110") echo "POP3" ;;
        "143") echo "IMAP" ;;
        "993") echo "IMAPS" ;;
        "995") echo "POP3S" ;;
        "21") echo "FTP" ;;
        "23") echo "Telnet" ;;
        "3389") echo "RDP" ;;
        "5432") echo "PostgreSQL" ;;
        "3306") echo "MySQL" ;;
        "6379") echo "Redis" ;;
        "27017") echo "MongoDB" ;;
        *) echo "Custom Service" ;;
    esac
}

# Generate rules
generate_rules() {
    local vm_ip="$1"
    local internal_port="$2"
    local external_port="$3"
    local host_interface="$4"
    local service_name="$5"
    
    log_info "Generating PF anchor rules for ${service_name}"
    log_verbose "Configuration: ${vm_ip}:${internal_port} -> *:${external_port}"
    
    # Validate inputs
    validate_ip "${vm_ip}" || exit 1
    validate_port "${internal_port}" "internal" || exit 1
    validate_port "${external_port}" "external" || exit 1
    
    # Generate rules
    local rules
    if [[ "${service_name}" == "complete" ]]; then
        # Auto-detect service name
        local detected_service
        detected_service=$(get_service_name "${internal_port}")
        rules=$(generate_complete_anchor "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}" "${detected_service}")
    else
        rules=$(generate_port_forward_rules "${vm_ip}" "${internal_port}" "${external_port}" "${host_interface}" "${service_name}")
    fi
    
    # Output rules
    if [[ -n "${OUTPUT_FILE}" ]]; then
        echo "${rules}" > "${OUTPUT_FILE}"
        log_success "Rules generated and saved to: ${OUTPUT_FILE}"
    else
        echo "${rules}"
    fi
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 -i INTERNAL_PORT -e EXTERNAL_PORT [OPTIONS]

Generate PF anchor rule snippets for LimaWAN port forwarding.

Required Arguments:
    -i, --internal-port N   Internal port on VM
    -e, --external-port N   External port to expose (${EXTERNAL_PORT_RANGE})

Optional Arguments:
    -v, --vm-ip IP          VM IP address (default: ${DEFAULT_VM_IP})
    -I, --interface IFACE   Host interface (default: ${DEFAULT_HOST_INTERFACE})
    -s, --service NAME      Service name (default: auto-detect)
    -o, --output FILE       Output file (default: stdout)
    -c, --complete          Generate complete anchor file
    -V, --verbose           Enable verbose output
    -h, --help              Show this help message

Examples:
    $0 -i 22 -e 2222                       # Generate SSH rules
    $0 -i 80 -e 8080 -s "Web Server"       # Generate HTTP rules
    $0 -i 443 -e 443 --complete            # Generate complete HTTPS anchor
    $0 -i 22 -e 2222 -o /tmp/ssh.rules     # Save to file
    $0 -i 5432 -e 5432 -s "PostgreSQL"     # Generate database rules

Service Templates:
    SSH, HTTP, HTTPS        - Include security optimizations
    Custom Service          - Basic port forwarding rules
    complete               - Full anchor file with all sections

External Port Range: ${EXTERNAL_PORT_RANGE}

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--internal-port)
                INTERNAL_PORT="$2"
                shift 2
                ;;
            -e|--external-port)
                EXTERNAL_PORT="$2"
                shift 2
                ;;
            -v|--vm-ip)
                VM_IP="$2"
                shift 2
                ;;
            -I|--interface)
                HOST_INTERFACE="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -c|--complete)
                SERVICE_NAME="complete"
                shift
                ;;
            -V|--verbose)
                VERBOSE=true
                shift
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
    
    # Check required arguments
    if [[ -z "${INTERNAL_PORT}" || -z "${EXTERNAL_PORT}" ]]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi
    
    # Set default service name if not provided
    if [[ -z "${SERVICE_NAME}" ]]; then
        SERVICE_NAME=$(get_service_name "${INTERNAL_PORT}")
    fi
    
    # Generate rules
    generate_rules "${VM_IP}" "${INTERNAL_PORT}" "${EXTERNAL_PORT}" "${HOST_INTERFACE}" "${SERVICE_NAME}"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 