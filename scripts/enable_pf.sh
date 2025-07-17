#!/bin/bash
set -euo pipefail

# LimaWAN PF Enable Script
# Enables PF, reloads configuration, and checks status

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
readonly ANCHOR_PATH="/etc/pf.anchors/limawan"
readonly MAIN_CONF_PATH="/etc/pf.conf"
readonly ANCHOR_NAME="limawan"
readonly PFCTL_FLAGS="-f /etc/pf.conf"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
VERBOSE=false
VALIDATE_ONLY=false
FORCE_RELOAD=false

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

# Check if PF is available
check_pf_available() {
    log_verbose "Checking PF availability..."
    
    if ! pfctl -s info >/dev/null 2>&1; then
        log_error "PF is not available on this system"
        exit 1
    fi
    
    log_verbose "PF is available"
}

# Check if main PF configuration exists
check_pf_config() {
    log_verbose "Checking PF configuration..."
    
    if [[ ! -f "${MAIN_CONF_PATH}" ]]; then
        log_warning "PF configuration file not found: ${MAIN_CONF_PATH}"
        log_info "Creating empty PF configuration"
        touch "${MAIN_CONF_PATH}"
    fi
    
    log_verbose "PF configuration file exists"
}

# Validate PF configuration syntax
validate_pf_config() {
    log_info "Validating PF configuration syntax..."
    
    local validation_output
    if ! validation_output=$(pfctl -n -f "${MAIN_CONF_PATH}" 2>&1); then
        log_error "PF configuration syntax validation failed:"
        echo "${validation_output}" >&2
        return 1
    fi
    
    log_success "PF configuration syntax is valid"
    return 0
}

# Check if PF is enabled
check_pf_enabled() {
    if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        log_verbose "PF is already enabled"
        return 0
    else
        log_verbose "PF is disabled"
        return 1
    fi
}

# Enable PF
enable_pf() {
    log_info "Enabling PF..."
    
    if check_pf_enabled; then
        log_info "PF is already enabled"
        return 0
    fi
    
    if ! pfctl -e 2>/dev/null; then
        log_error "Failed to enable PF"
        return 1
    fi
    
    log_success "PF enabled successfully"
    return 0
}

# Reload PF configuration
reload_pf_config() {
    log_info "Reloading PF configuration..."
    
    # Use pfctl_flags from .cursorrules
    local pfctl_cmd="pfctl ${PFCTL_FLAGS}"
    
    if ! ${pfctl_cmd} 2>/dev/null; then
        log_error "Failed to reload PF configuration"
        return 1
    fi
    
    log_success "PF configuration reloaded successfully"
    return 0
}

# Check if LimaWAN anchor is loaded
check_limawan_anchor() {
    log_verbose "Checking LimaWAN anchor status..."
    
    if [[ ! -f "${ANCHOR_PATH}" ]]; then
        log_warning "LimaWAN anchor file not found: ${ANCHOR_PATH}"
        return 1
    fi
    
    if ! grep -q "anchor \"${ANCHOR_NAME}\"" "${MAIN_CONF_PATH}" 2>/dev/null; then
        log_warning "LimaWAN anchor not found in PF configuration"
        return 1
    fi
    
    # Check if anchor rules are loaded
    if ! pfctl -a "${ANCHOR_NAME}" -s rules >/dev/null 2>&1; then
        log_warning "LimaWAN anchor rules not loaded"
        return 1
    fi
    
    log_verbose "LimaWAN anchor is properly loaded"
    return 0
}

# Show detailed PF status
show_pf_status() {
    log_info "PF Status Report:"
    echo "========================================"
    
    # General PF info
    echo
    log_info "PF General Status:"
    pfctl -s info 2>/dev/null || echo "PF status unavailable"
    
    # Show all anchors
    echo
    log_info "Loaded Anchors:"
    pfctl -s Anchors 2>/dev/null || echo "No anchors found"
    
    # Show LimaWAN specific rules
    echo
    log_info "LimaWAN Anchor Rules:"
    if pfctl -a "${ANCHOR_NAME}" -s rules 2>/dev/null; then
        log_success "LimaWAN rules are active"
    else
        log_warning "No LimaWAN rules found"
    fi
    
    # Show LimaWAN NAT rules
    echo
    log_info "LimaWAN NAT Rules:"
    if pfctl -a "${ANCHOR_NAME}" -s nat 2>/dev/null; then
        log_success "LimaWAN NAT rules are active"
    else
        log_warning "No LimaWAN NAT rules found"
    fi
    
    # Show state information
    echo
    log_info "PF State Information:"
    pfctl -s info 2>/dev/null | grep -E "(Status|Debug|State Table|Source Tracking)" || echo "State info unavailable"
    
    # Show interface information
    echo
    log_info "Network Interfaces:"
    pfctl -s Interfaces 2>/dev/null || echo "Interface info unavailable"
    
    echo "========================================"
}

# Show brief PF status
show_brief_status() {
    local pf_status
    if check_pf_enabled; then
        pf_status="ENABLED"
    else
        pf_status="DISABLED"
    fi
    
    local limawan_status
    if check_limawan_anchor; then
        limawan_status="ACTIVE"
    else
        limawan_status="INACTIVE"
    fi
    
    echo "PF Status: ${pf_status}"
    echo "LimaWAN Status: ${limawan_status}"
}

# Test PF configuration without applying
test_pf_config() {
    log_info "Testing PF configuration (dry run)..."
    
    local test_output
    if test_output=$(pfctl -n -f "${MAIN_CONF_PATH}" 2>&1); then
        log_success "PF configuration test passed"
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "${test_output}"
        fi
    else
        log_error "PF configuration test failed:"
        echo "${test_output}" >&2
        return 1
    fi
    
    return 0
}

# Main enable function
enable_pf_service() {
    log_info "Starting PF enable process..."
    
    # Check prerequisites
    check_pf_available
    check_pf_config
    
    # Validate configuration
    if ! validate_pf_config; then
        log_error "Configuration validation failed"
        exit 1
    fi
    
    if [[ "${VALIDATE_ONLY}" == "true" ]]; then
        log_success "Configuration validation completed"
        return 0
    fi
    
    # Enable PF
    if ! enable_pf; then
        log_error "Failed to enable PF"
        exit 1
    fi
    
    # Reload configuration
    if ! reload_pf_config; then
        log_error "Failed to reload PF configuration"
        exit 1
    fi
    
    # Check LimaWAN anchor status
    if check_limawan_anchor; then
        log_success "LimaWAN anchor is active"
    else
        log_warning "LimaWAN anchor is not active"
        log_info "Run setup_pf_forwarding.sh to configure port forwarding"
    fi
    
    log_success "PF enable process completed successfully"
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Enable PF, reload configuration, and check status.

Options:
    -v, --verbose       Enable verbose output
    -t, --test          Test configuration without applying (dry run)
    -f, --force         Force reload even if already enabled
    -s, --status        Show detailed PF status
    -b, --brief         Show brief status
    -h, --help          Show this help message

Examples:
    $0                  # Enable PF and reload configuration
    $0 --test           # Test configuration without applying
    $0 --status         # Show detailed PF status
    $0 --brief          # Show brief status
    $0 --force          # Force reload configuration

Files used:
    ${MAIN_CONF_PATH}        # Main PF configuration
    ${ANCHOR_PATH}           # LimaWAN anchor rules

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -t|--test)
                VALIDATE_ONLY=true
                shift
                ;;
            -f|--force)
                FORCE_RELOAD=true
                shift
                ;;
            -s|--status)
                show_pf_status
                exit 0
                ;;
            -b|--brief)
                show_brief_status
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
    
    # Check root privileges
    check_root
    
    # Enable PF service
    enable_pf_service
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 