#!/bin/bash
set -euo pipefail

# LimaWAN Security Monitoring Script
# Real-time security monitoring and alerting for exposed services

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration
readonly DEFAULT_VM_IP="192.168.105.10"
readonly LOG_FILE="/var/log/limawan_security.log"
readonly ALERT_THRESHOLD=5
readonly CHECK_INTERVAL=60

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Global variables
VM_IP="${VM_IP:-${DEFAULT_VM_IP}}"
VERBOSE=false
DAEMON_MODE=false
ALERT_EMAIL=""

# Logging functions
log_security() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} [SECURITY] ${message}" | tee -a "${LOG_FILE}"
}

log_alert() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}${timestamp} [ALERT] ${message}${NC}" | tee -a "${LOG_FILE}"
    
    # Send email if configured
    if [[ -n "${ALERT_EMAIL}" ]]; then
        echo "${message}" | mail -s "LimaWAN Security Alert" "${ALERT_EMAIL}" 2>/dev/null || true
    fi
}

log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}${timestamp} [INFO] ${message}${NC}" | tee -a "${LOG_FILE}"
}

# Check fail2ban status
check_fail2ban_status() {
    if ! limactl shell limawan-vm systemctl is-active fail2ban >/dev/null 2>&1; then
        log_alert "fail2ban is not running in VM"
        return 1
    fi
    
    # Check banned IPs
    local banned_count
    banned_count=$(limactl shell limawan-vm fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")
    
    if [[ "${banned_count}" -gt 0 ]]; then
        log_security "fail2ban: ${banned_count} IPs currently banned"
        
        # List banned IPs
        limactl shell limawan-vm fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" -A 1 | tail -1 | while read -r banned_ip; do
            log_security "Banned IP: ${banned_ip}"
        done
    fi
    
    return 0
}

# Check SSH connection attempts
check_ssh_attempts() {
    local recent_attempts
    recent_attempts=$(limactl shell limawan-vm "journalctl -u ssh --since '1 hour ago' | grep -c 'Failed password' || echo 0")
    
    if [[ "${recent_attempts}" -gt "${ALERT_THRESHOLD}" ]]; then
        log_alert "High number of SSH failed attempts: ${recent_attempts} in last hour"
        return 1
    fi
    
    if [[ "${recent_attempts}" -gt 0 ]]; then
        log_security "SSH failed attempts in last hour: ${recent_attempts}"
    fi
    
    return 0
}

# Check for suspicious network activity
check_network_activity() {
    # Check for unusual connection patterns
    local connection_count
    connection_count=$(limactl shell limawan-vm "netstat -tn | grep -c ':22.*ESTABLISHED' || echo 0")
    
    if [[ "${connection_count}" -gt 10 ]]; then
        log_alert "High number of concurrent SSH connections: ${connection_count}"
        return 1
    fi
    
    return 0
}

# Check VM firewall status
check_vm_firewall() {
    if ! limactl shell limawan-vm ufw status | grep -q "Status: active"; then
        log_alert "VM firewall (UFW) is not active"
        return 1
    fi
    
    return 0
}

# Check PF rules integrity
check_pf_rules() {
    if ! sudo pfctl -s rules | grep -q "limawan"; then
        log_alert "LimaWAN PF rules not found - port forwarding may be disabled"
        return 1
    fi
    
    return 0
}

# Check for system updates
check_system_updates() {
    local updates_available
    updates_available=$(limactl shell limawan-vm "apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0")
    
    if [[ "${updates_available}" -gt 0 ]]; then
        log_security "System updates available: ${updates_available} packages"
    fi
    
    return 0
}

# Check disk space
check_disk_space() {
    local disk_usage
    disk_usage=$(limactl shell limawan-vm "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" || echo "0")
    
    if [[ "${disk_usage}" -gt 90 ]]; then
        log_alert "High disk usage: ${disk_usage}%"
        return 1
    fi
    
    return 0
}

# Check for brute force patterns
check_brute_force() {
    local unique_ips
    unique_ips=$(limactl shell limawan-vm "journalctl -u ssh --since '1 hour ago' | grep 'Failed password' | awk '{print \$11}' | sort -u | wc -l" || echo "0")
    
    if [[ "${unique_ips}" -gt 5 ]]; then
        log_alert "Potential brute force attack: ${unique_ips} unique IPs with failed attempts"
        return 1
    fi
    
    return 0
}

# Run comprehensive security check
run_security_check() {
    log_info "Starting security check..."
    
    local checks_passed=0
    local checks_failed=0
    
    # Run all checks
    check_fail2ban_status && ((checks_passed++)) || ((checks_failed++))
    check_ssh_attempts && ((checks_passed++)) || ((checks_failed++))
    check_network_activity && ((checks_passed++)) || ((checks_failed++))
    check_vm_firewall && ((checks_passed++)) || ((checks_failed++))
    check_pf_rules && ((checks_passed++)) || ((checks_failed++))
    check_system_updates && ((checks_passed++)) || ((checks_failed++))
    check_disk_space && ((checks_passed++)) || ((checks_failed++))
    check_brute_force && ((checks_passed++)) || ((checks_failed++))
    
    log_info "Security check completed: ${checks_passed} passed, ${checks_failed} failed"
    
    if [[ "${checks_failed}" -gt 0 ]]; then
        log_alert "Security issues detected - immediate attention required"
        return 1
    fi
    
    return 0
}

# Generate security report
generate_security_report() {
    log_info "Generating security report..."
    
    cat << EOF

LimaWAN Security Report - $(date)
========================================

System Status:
$(limactl shell limawan-vm uptime || echo "VM not accessible")

Firewall Status:
$(limactl shell limawan-vm ufw status || echo "UFW not accessible")

fail2ban Status:
$(limactl shell limawan-vm fail2ban-client status || echo "fail2ban not accessible")

SSH Service Status:
$(limactl shell limawan-vm systemctl status ssh --no-pager -l || echo "SSH not accessible")

Recent Security Events:
$(tail -20 "${LOG_FILE}" || echo "No log file found")

Network Connections:
$(limactl shell limawan-vm netstat -tn | grep :22 || echo "No SSH connections")

Disk Usage:
$(limactl shell limawan-vm df -h || echo "Disk info not accessible")

System Updates:
$(limactl shell limawan-vm apt list --upgradable 2>/dev/null | head -10 || echo "Update info not accessible")

========================================

EOF
}

# Daemon mode - continuous monitoring
run_daemon() {
    log_info "Starting security monitoring daemon (PID: $$)"
    
    while true; do
        if ! run_security_check; then
            log_alert "Security check failed - sleeping ${CHECK_INTERVAL}s before retry"
        fi
        
        sleep "${CHECK_INTERVAL}"
    done
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Monitor LimaWAN security status and generate alerts.

Options:
    -v, --vm-ip IP         VM IP address (default: ${DEFAULT_VM_IP})
    -d, --daemon           Run in daemon mode (continuous monitoring)
    -e, --email EMAIL      Email address for alerts
    -i, --interval SEC     Check interval in seconds (default: ${CHECK_INTERVAL})
    -r, --report           Generate security report
    -V, --verbose          Enable verbose output
    -h, --help             Show this help message

Examples:
    $0                     # Run single security check
    $0 --report            # Generate security report
    $0 --daemon            # Run continuous monitoring
    $0 --daemon --email admin@example.com  # Monitor with email alerts

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
            -d|--daemon)
                DAEMON_MODE=true
                shift
                ;;
            -e|--email)
                ALERT_EMAIL="$2"
                shift 2
                ;;
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -r|--report)
                generate_security_report
                exit 0
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
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    parse_arguments "$@"
    
    # Create log file if it doesn't exist
    sudo touch "${LOG_FILE}"
    sudo chmod 644 "${LOG_FILE}"
    
    if [[ "${DAEMON_MODE}" == "true" ]]; then
        run_daemon
    else
        run_security_check
    fi
}

# Run main function
main "$@" 