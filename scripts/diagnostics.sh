#!/bin/bash
set -euo pipefail

# LimaWAN Diagnostics Script
# Comprehensive testing of port forwarding and connectivity

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
readonly ANCHOR_PATH="/etc/pf.anchors/limawan"
readonly MAIN_CONF_PATH="/etc/pf.conf"
readonly ANCHOR_NAME="limawan"
readonly DEFAULT_VM_IP="192.168.105.10"
readonly DEFAULT_HOST_INTERFACE="en0"
readonly TEST_MODE_VM_PORT="2222"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Global variables
VM_IP="${VM_IP:-${DEFAULT_VM_IP}}"
HOST_INTERFACE="${HOST_INTERFACE:-${DEFAULT_HOST_INTERFACE}}"
INTERNAL_PORT=""
EXTERNAL_PORT=""
VERBOSE=false
QUICK_TEST=false
EXTERNAL_TEST=false

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

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

log_test() {
    echo -e "${PURPLE}[TEST]${NC} $1" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1" >&2
    fi
}

# Test result functions
test_pass() {
    local test_name="$1"
    log_success "PASS: ${test_name}"
    ((TESTS_PASSED++))
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    log_error "FAIL: ${test_name} - ${reason}"
    ((TESTS_FAILED++))
}

test_skip() {
    local test_name="$1"
    local reason="$2"
    log_warning "SKIP: ${test_name} - ${reason}"
    ((TESTS_SKIPPED++))
}

# Get external IP address
get_external_ip() {
    local external_ip=""
    local services=(
        "https://ipinfo.io/ip"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )
    
    for service in "${services[@]}"; do
        if external_ip=$(curl -s --connect-timeout 5 "${service}" 2>/dev/null | tr -d '\n' | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'); then
            echo "${external_ip}"
            return 0
        fi
    done
    
    return 1
}

# Test 1: System Prerequisites
test_system_prerequisites() {
    local test_name="System Prerequisites"
    log_test "${test_name}"
    
    # Check macOS version
    if [[ "$OSTYPE" != "darwin"* ]]; then
        test_fail "${test_name}" "Not running on macOS"
        return
    fi
    
    # Check if running as root (for some tests)
    if [[ "${EUID}" -ne 0 ]]; then
        log_verbose "Not running as root - some tests may be limited"
    fi
    
    # Check if required commands exist
    local commands=("pfctl" "nc" "ping" "curl")
    for cmd in "${commands[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            test_fail "${test_name}" "Required command not found: ${cmd}"
            return
        fi
    done
    
    test_pass "${test_name}"
}

# Test 2: PF Status
test_pf_status() {
    local test_name="PF Status"
    log_test "${test_name}"
    
    # Check if PF is available
    if ! pfctl -s info >/dev/null 2>&1; then
        test_fail "${test_name}" "PF is not available"
        return
    fi
    
    # Check if PF is enabled
    if ! pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
        test_fail "${test_name}" "PF is not enabled"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 3: PF Configuration Files
test_pf_config_files() {
    local test_name="PF Configuration Files"
    log_test "${test_name}"
    
    # Check main PF configuration
    if [[ ! -f "${MAIN_CONF_PATH}" ]]; then
        test_fail "${test_name}" "Main PF configuration not found: ${MAIN_CONF_PATH}"
        return
    fi
    
    # Check LimaWAN anchor in main config
    if ! grep -q "anchor \"${ANCHOR_NAME}\"" "${MAIN_CONF_PATH}" 2>/dev/null; then
        test_fail "${test_name}" "LimaWAN anchor not found in main configuration"
        return
    fi
    
    # Check anchor file exists
    if [[ ! -f "${ANCHOR_PATH}" ]]; then
        test_fail "${test_name}" "LimaWAN anchor file not found: ${ANCHOR_PATH}"
        return
    fi
    
    # Validate PF configuration syntax
    if ! pfctl -n -f "${MAIN_CONF_PATH}" >/dev/null 2>&1; then
        test_fail "${test_name}" "PF configuration syntax validation failed"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 4: LimaWAN Anchor Rules
test_limawan_anchor_rules() {
    local test_name="LimaWAN Anchor Rules"
    log_test "${test_name}"
    
    # Check if anchor rules are loaded
    if ! pfctl -a "${ANCHOR_NAME}" -s rules >/dev/null 2>&1; then
        test_fail "${test_name}" "LimaWAN anchor rules not loaded"
        return
    fi
    
    # Check if NAT rules are loaded
    if ! pfctl -a "${ANCHOR_NAME}" -s nat >/dev/null 2>&1; then
        test_fail "${test_name}" "LimaWAN NAT rules not loaded"
        return
    fi
    
    # Check if rules contain expected patterns
    local rules_output
    rules_output=$(pfctl -a "${ANCHOR_NAME}" -s rules 2>/dev/null)
    
    if [[ -z "${rules_output}" ]]; then
        test_fail "${test_name}" "No anchor rules found"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 5: Network Interface
test_network_interface() {
    local test_name="Network Interface"
    log_test "${test_name}"
    
    # Check if host interface exists
    if ! ifconfig "${HOST_INTERFACE}" >/dev/null 2>&1; then
        test_fail "${test_name}" "Host interface not found: ${HOST_INTERFACE}"
        return
    fi
    
    # Check if interface is up
    if ! ifconfig "${HOST_INTERFACE}" | grep -q "UP"; then
        test_fail "${test_name}" "Host interface is down: ${HOST_INTERFACE}"
        return
    fi
    
    # Check if interface has IP address
    if ! ifconfig "${HOST_INTERFACE}" | grep -q "inet "; then
        test_fail "${test_name}" "Host interface has no IP address: ${HOST_INTERFACE}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 6: VM Connectivity
test_vm_connectivity() {
    local test_name="VM Connectivity"
    log_test "${test_name}"
    
    # Check if VM IP is reachable
    if ! ping -c 1 -W 1000 "${VM_IP}" >/dev/null 2>&1; then
        test_fail "${test_name}" "VM not reachable: ${VM_IP}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 7: Port Forwarding Configuration
test_port_forwarding_config() {
    local test_name="Port Forwarding Configuration"
    log_test "${test_name}"
    
    if [[ -z "${INTERNAL_PORT}" || -z "${EXTERNAL_PORT}" ]]; then
        test_skip "${test_name}" "No port forwarding configured"
        return
    fi
    
    # Check if port forwarding rules exist
    local nat_rules
    nat_rules=$(pfctl -a "${ANCHOR_NAME}" -s nat 2>/dev/null)
    
    if [[ -z "${nat_rules}" ]]; then
        test_fail "${test_name}" "No NAT rules found"
        return
    fi
    
    # Check if specific port forwarding rule exists
    if ! echo "${nat_rules}" | grep -q "rdr.*${EXTERNAL_PORT}.*${VM_IP}.*${INTERNAL_PORT}"; then
        test_fail "${test_name}" "Port forwarding rule not found: ${EXTERNAL_PORT}->${VM_IP}:${INTERNAL_PORT}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 8: Internal Port Accessibility
test_internal_port_access() {
    local test_name="Internal Port Access"
    log_test "${test_name}"
    
    if [[ -z "${INTERNAL_PORT}" ]]; then
        test_skip "${test_name}" "No internal port specified"
        return
    fi
    
    # Test port connectivity to VM
    if ! nc -z -w 5 "${VM_IP}" "${INTERNAL_PORT}" 2>/dev/null; then
        test_fail "${test_name}" "Internal port not accessible: ${VM_IP}:${INTERNAL_PORT}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 9: External Port Accessibility
test_external_port_access() {
    local test_name="External Port Access"
    log_test "${test_name}"
    
    if [[ -z "${EXTERNAL_PORT}" ]]; then
        test_skip "${test_name}" "No external port specified"
        return
    fi
    
    # Test local port forwarding
    if ! nc -z -w 5 localhost "${EXTERNAL_PORT}" 2>/dev/null; then
        test_fail "${test_name}" "External port not accessible locally: ${EXTERNAL_PORT}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 10: External IP Accessibility
test_external_ip_access() {
    local test_name="External IP Access"
    log_test "${test_name}"
    
    if [[ "${EXTERNAL_TEST}" != "true" ]]; then
        test_skip "${test_name}" "External testing disabled"
        return
    fi
    
    if [[ -z "${EXTERNAL_PORT}" ]]; then
        test_skip "${test_name}" "No external port specified"
        return
    fi
    
    # Get external IP
    local external_ip
    if ! external_ip=$(get_external_ip); then
        test_fail "${test_name}" "Unable to determine external IP"
        return
    fi
    
    log_verbose "Testing external IP: ${external_ip}:${EXTERNAL_PORT}"
    
    # Test external port accessibility
    if ! nc -z -w 10 "${external_ip}" "${EXTERNAL_PORT}" 2>/dev/null; then
        test_fail "${test_name}" "External port not accessible: ${external_ip}:${EXTERNAL_PORT}"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 11: Lima VM Status
test_lima_vm_status() {
    local test_name="Lima VM Status"
    log_test "${test_name}"
    
    # Check if Lima is available
    if ! command -v lima >/dev/null 2>&1; then
        test_skip "${test_name}" "Lima not available"
        return
    fi
    
    # Check if any Lima VMs are running
    local lima_vms
    lima_vms=$(lima list 2>/dev/null | grep -v "NAME" | grep "Running" | wc -l)
    
    if [[ "${lima_vms}" -eq 0 ]]; then
        test_fail "${test_name}" "No Lima VMs running"
        return
    fi
    
    test_pass "${test_name}"
}

# Test 12: DNS Resolution
test_dns_resolution() {
    local test_name="DNS Resolution"
    log_test "${test_name}"
    
    # Test DNS resolution
    if ! nslookup google.com >/dev/null 2>&1; then
        test_fail "${test_name}" "DNS resolution failed"
        return
    fi
    
    test_pass "${test_name}"
}

# Generate diagnostic report
generate_diagnostic_report() {
    local report_file="/tmp/limawan-diagnostic-$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Generating diagnostic report: ${report_file}"
    
    cat > "${report_file}" << EOF
LimaWAN Diagnostic Report
========================
Generated: $(date)
System: $(uname -a)

Configuration:
--------------
VM IP: ${VM_IP}
Host Interface: ${HOST_INTERFACE}
Internal Port: ${INTERNAL_PORT:-"Not specified"}
External Port: ${EXTERNAL_PORT:-"Not specified"}

PF Status:
----------
EOF
    
    # Add PF status
    pfctl -s info >> "${report_file}" 2>&1 || echo "PF status unavailable" >> "${report_file}"
    
    cat >> "${report_file}" << EOF

LimaWAN Anchor Rules:
--------------------
EOF
    
    # Add anchor rules
    pfctl -a "${ANCHOR_NAME}" -s rules >> "${report_file}" 2>&1 || echo "No anchor rules" >> "${report_file}"
    
    cat >> "${report_file}" << EOF

LimaWAN NAT Rules:
-----------------
EOF
    
    # Add NAT rules
    pfctl -a "${ANCHOR_NAME}" -s nat >> "${report_file}" 2>&1 || echo "No NAT rules" >> "${report_file}"
    
    cat >> "${report_file}" << EOF

Network Interfaces:
------------------
EOF
    
    # Add network interface info
    ifconfig >> "${report_file}" 2>&1 || echo "Interface info unavailable" >> "${report_file}"
    
    cat >> "${report_file}" << EOF

Lima VMs:
---------
EOF
    
    # Add Lima VM info
    lima list >> "${report_file}" 2>&1 || echo "Lima not available" >> "${report_file}"
    
    cat >> "${report_file}" << EOF

Test Results:
-------------
Passed: ${TESTS_PASSED}
Failed: ${TESTS_FAILED}
Skipped: ${TESTS_SKIPPED}

EOF
    
    log_success "Diagnostic report generated: ${report_file}"
}

# Run all tests
run_all_tests() {
    log_info "Running LimaWAN diagnostics..."
    echo "========================================"
    
    # Core system tests
    test_system_prerequisites
    test_pf_status
    test_pf_config_files
    test_limawan_anchor_rules
    test_network_interface
    test_dns_resolution
    
    # VM connectivity tests
    test_vm_connectivity
    test_lima_vm_status
    
    # Port forwarding tests
    if [[ "${QUICK_TEST}" != "true" ]]; then
        test_port_forwarding_config
        test_internal_port_access
        test_external_port_access
        test_external_ip_access
    fi
    
    # Results summary
    echo "========================================"
    log_info "Test Results Summary:"
    log_success "Passed: ${TESTS_PASSED}"
    log_error "Failed: ${TESTS_FAILED}"
    log_warning "Skipped: ${TESTS_SKIPPED}"
    
    local total_tests=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    log_info "Total tests: ${total_tests}"
    
    if [[ ${TESTS_FAILED} -eq 0 ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed. See details above."
        return 1
    fi
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Comprehensive diagnostics for LimaWAN port forwarding.

Options:
    -v, --vm-ip IP          VM IP address (default: ${DEFAULT_VM_IP})
    -i, --internal-port N   Internal port on VM
    -e, --external-port N   External port to test
    -I, --interface IFACE   Host interface (default: ${DEFAULT_HOST_INTERFACE})
    -q, --quick             Run quick tests only
    -x, --external          Enable external IP testing
    -V, --verbose           Enable verbose output
    -r, --report            Generate diagnostic report
    -h, --help              Show this help message

Examples:
    $0                                          # Run basic diagnostics
    $0 -v 192.168.105.10 -i 22 -e 2222        # Test SSH forwarding
    $0 --quick                                  # Quick tests only
    $0 --external -e 2222                      # Test external access
    $0 --report                                 # Generate diagnostic report

Test Categories:
    - System Prerequisites
    - PF Status and Configuration
    - Network Connectivity
    - Port Forwarding Rules
    - VM Accessibility
    - External Access (with --external)

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
            -q|--quick)
                QUICK_TEST=true
                shift
                ;;
            -x|--external)
                EXTERNAL_TEST=true
                shift
                ;;
            -V|--verbose)
                VERBOSE=true
                shift
                ;;
            -r|--report)
                generate_diagnostic_report
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
    
    # Run diagnostics
    if ! run_all_tests; then
        log_info "Run with --report to generate a detailed diagnostic report"
        exit 1
    fi
    
    exit 0
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 