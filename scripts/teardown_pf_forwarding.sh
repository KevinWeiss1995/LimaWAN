#!/bin/bash
set -euo pipefail

# LimaWAN PF Teardown Script
# Safely removes PF port forwarding rules and restores original configuration

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Configuration from .cursorrules
readonly ANCHOR_PATH="/etc/pf.anchors/limawan"
readonly MAIN_CONF_PATH="/etc/pf.conf"
readonly PF_CONF_BACKUP_PATH="/etc/pf.conf.bak"
readonly ANCHOR_NAME="limawan"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
FORCE_REMOVE=false
KEEP_BACKUP=false
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

# Check if LimaWAN rules exist
check_limawan_rules() {
    if [[ ! -f "${ANCHOR_PATH}" ]]; then
        log_warning "LimaWAN anchor file not found: ${ANCHOR_PATH}"
        return 1
    fi
    
    if ! grep -q "anchor \"${ANCHOR_NAME}\"" "${MAIN_CONF_PATH}" 2>/dev/null; then
        log_warning "LimaWAN anchor not found in PF configuration"
        return 1
    fi
    
    return 0
}

# Flush LimaWAN anchor rules
flush_anchor_rules() {
    log_info "Flushing LimaWAN anchor rules..."
    
    if pfctl -a "${ANCHOR_NAME}" -F rules 2>/dev/null; then
        log_success "LimaWAN anchor rules flushed"
    else
        log_warning "Failed to flush LimaWAN anchor rules (may not exist)"
    fi
    
    if pfctl -a "${ANCHOR_NAME}" -F nat 2>/dev/null; then
        log_success "LimaWAN NAT rules flushed"
    else
        log_warning "Failed to flush LimaWAN NAT rules (may not exist)"
    fi
}

# Remove anchor from main PF configuration
remove_anchor_from_config() {
    log_info "Removing LimaWAN anchor from PF configuration..."
    
    if [[ ! -f "${MAIN_CONF_PATH}" ]]; then
        log_warning "PF configuration file not found: ${MAIN_CONF_PATH}"
        return 1
    fi
    
    # Create temporary file without LimaWAN anchor
    local temp_file
    temp_file=$(mktemp)
    
    # Remove LimaWAN anchor block
    awk '
        /^# LimaWAN Port Forwarding Anchor$/ { skip = 1; next }
        /^anchor "limawan"/ { skip = 1; next }
        skip && /^}$/ { skip = 0; next }
        skip && /^$/ { next }
        !skip { print }
    ' "${MAIN_CONF_PATH}" > "${temp_file}"
    
    # Replace original file
    mv "${temp_file}" "${MAIN_CONF_PATH}"
    
    log_success "LimaWAN anchor removed from PF configuration"
}

# Remove anchor file
remove_anchor_file() {
    log_info "Removing LimaWAN anchor file..."
    
    if [[ -f "${ANCHOR_PATH}" ]]; then
        rm -f "${ANCHOR_PATH}"
        log_success "LimaWAN anchor file removed: ${ANCHOR_PATH}"
    else
        log_warning "LimaWAN anchor file not found: ${ANCHOR_PATH}"
    fi
    
    # Remove anchor directory if empty
    local anchor_dir
    anchor_dir="$(dirname "${ANCHOR_PATH}")"
    if [[ -d "${anchor_dir}" ]] && [[ -z "$(ls -A "${anchor_dir}")" ]]; then
        rmdir "${anchor_dir}"
        log_verbose "Removed empty anchor directory: ${anchor_dir}"
    fi
}

# Restore backup configuration
restore_backup_config() {
    if [[ ! -f "${PF_CONF_BACKUP_PATH}" ]]; then
        log_warning "No backup configuration found: ${PF_CONF_BACKUP_PATH}"
        return 1
    fi
    
    log_info "Restoring backup PF configuration..."
    
    if [[ "${FORCE_REMOVE}" == "true" ]]; then
        cp "${PF_CONF_BACKUP_PATH}" "${MAIN_CONF_PATH}"
        log_success "Backup configuration restored from ${PF_CONF_BACKUP_PATH}"
    else
        log_info "Use --force to restore backup configuration"
        log_info "Backup available at: ${PF_CONF_BACKUP_PATH}"
    fi
}

# Validate PF configuration
validate_pf_config() {
    log_info "Validating PF configuration..."
    
    if ! pfctl -n -f "${MAIN_CONF_PATH}" 2>/dev/null; then
        log_error "PF configuration validation failed"
        return 1
    fi
    
    log_success "PF configuration is valid"
    return 0
}

# Reload PF configuration
reload_pf_config() {
    log_info "Reloading PF configuration..."
    
    if ! pfctl -f "${MAIN_CONF_PATH}"; then
        log_error "Failed to reload PF configuration"
        return 1
    fi
    
    log_success "PF configuration reloaded successfully"
    return 0
}

# Clean up backup files
cleanup_backup_files() {
    if [[ "${KEEP_BACKUP}" == "true" ]]; then
        log_info "Keeping backup files as requested"
        return 0
    fi
    
    log_info "Cleaning up backup files..."
    
    if [[ -f "${PF_CONF_BACKUP_PATH}" ]]; then
        rm -f "${PF_CONF_BACKUP_PATH}"
        log_success "Backup file removed: ${PF_CONF_BACKUP_PATH}"
    fi
}

# Show current PF status
show_pf_status() {
    log_info "Current PF Status:"
    echo "----------------------------------------"
    
    # PF general status
    pfctl -s info 2>/dev/null || echo "PF status unavailable"
    
    echo
    log_info "All Anchors:"
    pfctl -s Anchors 2>/dev/null || echo "No anchors found"
    
    echo
    log_info "All Rules:"
    pfctl -s rules 2>/dev/null | head -20 || echo "No rules found"
    
    echo "----------------------------------------"
}

# Main teardown function
teardown_pf_forwarding() {
    log_info "Starting LimaWAN PF teardown process..."
    
    # Check if LimaWAN rules exist
    if ! check_limawan_rules; then
        log_warning "No LimaWAN rules found to remove"
        if [[ "${FORCE_REMOVE}" != "true" ]]; then
            log_info "Use --force to proceed anyway"
            return 0
        fi
    fi
    
    # Flush anchor rules first
    flush_anchor_rules
    
    # Remove anchor from main configuration
    remove_anchor_from_config
    
    # Remove anchor file
    remove_anchor_file
    
    # Validate and reload configuration
    if validate_pf_config; then
        reload_pf_config
    else
        log_error "Configuration validation failed - attempting backup restore"
        restore_backup_config
        if validate_pf_config; then
            reload_pf_config
        else
            log_error "Unable to restore valid PF configuration"
            exit 1
        fi
    fi
    
    # Clean up backup files
    cleanup_backup_files
    
    log_success "LimaWAN PF teardown completed successfully"
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Safely remove LimaWAN PF port forwarding rules and restore original configuration.

Options:
    -f, --force         Force removal even if rules not found
    -k, --keep-backup   Keep backup files after teardown
    -V, --verbose       Enable verbose output
    -s, --status        Show current PF status
    -h, --help          Show this help message

Examples:
    $0                  # Remove LimaWAN rules
    $0 --force          # Force removal even if rules not found
    $0 --keep-backup    # Keep backup files
    $0 --status         # Show PF status

Files affected:
    ${ANCHOR_PATH}           # LimaWAN anchor rules (removed)
    ${MAIN_CONF_PATH}        # Main PF configuration (modified)
    ${PF_CONF_BACKUP_PATH}   # Backup configuration (removed unless --keep-backup)

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                FORCE_REMOVE=true
                shift
                ;;
            -k|--keep-backup)
                KEEP_BACKUP=true
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
    
    # Check root privileges
    check_root
    
    # Perform teardown
    teardown_pf_forwarding
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 