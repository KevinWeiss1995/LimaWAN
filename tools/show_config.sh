#!/bin/bash
set -euo pipefail

# LimaWAN Configuration Viewer
# Debug view of current forwarding rules

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
readonly ANCHOR_PATH="/etc/pf.anchors/limawan"
readonly MAIN_CONF_PATH="/etc/pf.conf"
readonly ANCHOR_NAME="limawan"
readonly DEFAULT_VM_IP="192.168.105.10"
readonly DEFAULT_HOST_INTERFACE="en0"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Global variables
VERBOSE=false
COMPACT=false
RAW_OUTPUT=false
OUTPUT_FILE=""
SHOW_STATS=false

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

log_section() {
    echo -e "${PURPLE}[SECTION]${NC} $1" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "${CYAN}[VERBOSE]${NC} $1" >&2
    fi
}

# Header function
print_header() {
    local title="$1"
    local width=70
    local padding=$(( (width - ${#title}) / 2 ))
    
    if [[ "${RAW_OUTPUT}" == "true" ]]; then
        echo "=== ${title} ==="
        return
    fi
    
    echo -e "${CYAN}$(printf '%*s' $width | tr ' ' '=')${NC}"
    echo -e "${CYAN}$(printf '%*s%s%*s' $padding '' "$title" $padding '')${NC}"
    echo -e "${CYAN}$(printf '%*s' $width | tr ' ' '=')${NC}"
}

# Section separator
print_section() {
    local title="$1"
    
    if [[ "${RAW_OUTPUT}" == "true" ]]; then
        echo "--- ${title} ---"
        return
    fi
    
    echo
    echo -e "${BLUE}$(printf '%*s' 50 | tr ' ' '-')${NC}"
    echo -e "${BLUE}${title}${NC}"
    echo -e "${BLUE}$(printf '%*s' 50 | tr ' ' '-')${NC}"
}

# Check if running as root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_warning "Not running as root - some information may be unavailable"
    fi
}

# Show system information
show_system_info() {
    print_section "System Information"
    
    echo "Hostname: $(hostname)"
    echo "OS: $(uname -s) $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Current User: $(whoami)"
    echo "Current Time: $(date)"
    
    # Network interface information
    echo
    echo "Network Interface (${DEFAULT_HOST_INTERFACE}):"
    if ifconfig "${DEFAULT_HOST_INTERFACE}" >/dev/null 2>&1; then
        ifconfig "${DEFAULT_HOST_INTERFACE}" | grep -E "(inet |status:|media:|flags=)" || echo "Interface info unavailable"
    else
        echo "Interface ${DEFAULT_HOST_INTERFACE} not found"
    fi
}

# Show PF status
show_pf_status() {
    print_section "PF Status"
    
    # Check if PF is available
    if ! pfctl -s info >/dev/null 2>&1; then
        log_error "PF is not available on this system"
        return
    fi
    
    # General PF status
    echo "PF General Status:"
    pfctl -s info 2>/dev/null || echo "PF info unavailable"
    
    echo
    echo "PF Statistics:"
    pfctl -s info 2>/dev/null | grep -E "(State Table|Source Tracking|Counters)" || echo "Stats unavailable"
}

# Show configuration files
show_config_files() {
    print_section "Configuration Files"
    
    # Main PF configuration
    echo "Main PF Configuration (${MAIN_CONF_PATH}):"
    if [[ -f "${MAIN_CONF_PATH}" ]]; then
        echo "  Status: EXISTS"
        echo "  Size: $(wc -l < "${MAIN_CONF_PATH}" 2>/dev/null || echo "unknown") lines"
        echo "  Modified: $(stat -f "%Sm" "${MAIN_CONF_PATH}" 2>/dev/null || date -r "${MAIN_CONF_PATH}" 2>/dev/null || echo "unknown")"
        
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "  Content:"
            cat "${MAIN_CONF_PATH}" 2>/dev/null | sed 's/^/    /'
        fi
    else
        echo "  Status: NOT FOUND"
    fi
    
    echo
    # LimaWAN anchor file
    echo "LimaWAN Anchor File (${ANCHOR_PATH}):"
    if [[ -f "${ANCHOR_PATH}" ]]; then
        echo "  Status: EXISTS"
        echo "  Size: $(wc -l < "${ANCHOR_PATH}" 2>/dev/null || echo "unknown") lines"
        echo "  Modified: $(stat -f "%Sm" "${ANCHOR_PATH}" 2>/dev/null || date -r "${ANCHOR_PATH}" 2>/dev/null || echo "unknown")"
        
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "  Content:"
            cat "${ANCHOR_PATH}" 2>/dev/null | sed 's/^/    /'
        fi
    else
        echo "  Status: NOT FOUND"
    fi
    
    # Check anchor directory
    echo
    local anchor_dir
    anchor_dir="$(dirname "${ANCHOR_PATH}")"
    echo "Anchor Directory (${anchor_dir}):"
    if [[ -d "${anchor_dir}" ]]; then
        echo "  Status: EXISTS"
        echo "  Files:"
        ls -la "${anchor_dir}" 2>/dev/null | sed 's/^/    /' || echo "    Unable to list files"
    else
        echo "  Status: NOT FOUND"
    fi
}

# Show loaded anchors
show_loaded_anchors() {
    print_section "Loaded Anchors"
    
    echo "All Anchors:"
    pfctl -s Anchors 2>/dev/null || echo "No anchors found or PF not available"
    
    echo
    echo "LimaWAN Anchor Rules:"
    if pfctl -a "${ANCHOR_NAME}" -s rules 2>/dev/null; then
        echo "  Status: LOADED"
    else
        echo "  Status: NOT LOADED"
    fi
    
    echo
    echo "LimaWAN NAT Rules:"
    if pfctl -a "${ANCHOR_NAME}" -s nat 2>/dev/null; then
        echo "  Status: LOADED"
    else
        echo "  Status: NOT LOADED"
    fi
}

# Show active rules
show_active_rules() {
    print_section "Active Rules"
    
    echo "All Active Rules:"
    pfctl -s rules 2>/dev/null || echo "No rules found or PF not available"
    
    echo
    echo "All NAT Rules:"
    pfctl -s nat 2>/dev/null || echo "No NAT rules found or PF not available"
    
    echo
    echo "All RDR Rules:"
    pfctl -s rdr 2>/dev/null || echo "No RDR rules found or PF not available"
}

# Show state information
show_state_info() {
    print_section "State Information"
    
    echo "State Table Summary:"
    pfctl -s info 2>/dev/null | grep -A 10 "State Table" || echo "State info unavailable"
    
    echo
    echo "Active States (first 20):"
    pfctl -s states 2>/dev/null | head -20 || echo "State info unavailable"
    
    if [[ "${VERBOSE}" == "true" ]]; then
        echo
        echo "All States:"
        pfctl -s states 2>/dev/null || echo "State info unavailable"
    fi
}

# Show statistics
show_statistics() {
    print_section "Statistics"
    
    echo "Interface Statistics:"
    pfctl -s info 2>/dev/null | grep -A 20 "Counters" || echo "Stats unavailable"
    
    echo
    echo "Memory Usage:"
    pfctl -s memory 2>/dev/null || echo "Memory info unavailable"
    
    echo
    echo "Time Statistics:"
    pfctl -s timeouts 2>/dev/null || echo "Timeout info unavailable"
}

# Show network connectivity
show_network_connectivity() {
    print_section "Network Connectivity"
    
    echo "VM Connectivity Test (${DEFAULT_VM_IP}):"
    if ping -c 3 -W 1000 "${DEFAULT_VM_IP}" >/dev/null 2>&1; then
        echo "  Status: REACHABLE"
        echo "  Latency: $(ping -c 3 -W 1000 "${DEFAULT_VM_IP}" 2>/dev/null | tail -1 | cut -d' ' -f4 | cut -d'/' -f2 || echo "unknown")ms"
    else
        echo "  Status: UNREACHABLE"
    fi
    
    echo
    echo "Active Network Connections:"
    netstat -an 2>/dev/null | grep -E "(tcp|udp)" | head -10 || echo "Connection info unavailable"
}

# Show process information
show_process_info() {
    print_section "Process Information"
    
    echo "PF-related Processes:"
    ps aux | grep -E "(pf|pfctl)" | grep -v grep || echo "No PF processes found"
    
    echo
    echo "Lima Processes:"
    ps aux | grep -E "(lima|qemu)" | grep -v grep || echo "No Lima processes found"
}

# Show configuration summary
show_config_summary() {
    print_section "Configuration Summary"
    
    # Extract configuration info
    local vm_ip="${DEFAULT_VM_IP}"
    local host_interface="${DEFAULT_HOST_INTERFACE}"
    local anchor_exists="NO"
    local pf_enabled="NO"
    local rules_loaded="NO"
    
    # Check if anchor file exists
    if [[ -f "${ANCHOR_PATH}" ]]; then
        anchor_exists="YES"
    fi
    
    # Check if PF is enabled
    if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        pf_enabled="YES"
    fi
    
    # Check if rules are loaded
    if pfctl -a "${ANCHOR_NAME}" -s rules >/dev/null 2>&1; then
        rules_loaded="YES"
    fi
    
    # Extract port forwarding info
    local port_forwards=""
    if [[ -f "${ANCHOR_PATH}" ]]; then
        port_forwards=$(grep -E "rdr-to.*port" "${ANCHOR_PATH}" 2>/dev/null | sed 's/^/    /' || echo "    None found")
    else
        port_forwards="    Anchor file not found"
    fi
    
    cat << EOF
Configuration Overview:
  VM IP: ${vm_ip}
  Host Interface: ${host_interface}
  Anchor File: ${anchor_exists}
  PF Enabled: ${pf_enabled}
  Rules Loaded: ${rules_loaded}

Port Forwarding Rules:
${port_forwards}

File Locations:
  Main PF Config: ${MAIN_CONF_PATH}
  LimaWAN Anchor: ${ANCHOR_PATH}
  Anchor Directory: $(dirname "${ANCHOR_PATH}")

EOF
}

# Generate complete report
generate_report() {
    local output=""
    
    if [[ "${COMPACT}" == "true" ]]; then
        output="$(show_config_summary)"
    else
        output="$(
            print_header "LimaWAN Configuration Report"
            show_system_info
            show_config_summary
            show_pf_status
            show_config_files
            show_loaded_anchors
            show_active_rules
            show_network_connectivity
            
            if [[ "${SHOW_STATS}" == "true" ]]; then
                show_state_info
                show_statistics
                show_process_info
            fi
            
            echo
            print_section "Report Generated"
            echo "Timestamp: $(date)"
            echo "Generated by: $(whoami)@$(hostname)"
        )"
    fi
    
    if [[ -n "${OUTPUT_FILE}" ]]; then
        echo "${output}" > "${OUTPUT_FILE}"
        log_success "Report saved to: ${OUTPUT_FILE}"
    else
        echo "${output}"
    fi
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Show debug view of current LimaWAN forwarding rules.

Options:
    -c, --compact           Show compact summary only
    -s, --stats             Include detailed statistics
    -v, --verbose           Show verbose output
    -r, --raw               Raw output without colors
    -o, --output FILE       Save output to file
    -h, --help              Show this help message

Examples:
    $0                      # Show full configuration report
    $0 --compact            # Show compact summary
    $0 --stats              # Include detailed statistics
    $0 --verbose            # Show verbose output with file contents
    $0 --raw                # Raw output suitable for logging
    $0 -o /tmp/config.txt   # Save report to file

Information Shown:
    - System Information
    - PF Status and Statistics
    - Configuration Files
    - Loaded Anchors
    - Active Rules
    - Network Connectivity
    - Process Information (with --stats)

Files Examined:
    ${MAIN_CONF_PATH}        # Main PF configuration
    ${ANCHOR_PATH}           # LimaWAN anchor rules
    $(dirname "${ANCHOR_PATH}")              # Anchor directory

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--compact)
                COMPACT=true
                shift
                ;;
            -s|--stats)
                SHOW_STATS=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -r|--raw)
                RAW_OUTPUT=true
                shift
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
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
    
    # Check root privileges
    check_root
    
    # Generate report
    generate_report
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 