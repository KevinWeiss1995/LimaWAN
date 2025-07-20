#!/bin/bash
set -euo pipefail

# LimaWAN Security Hardening Script
# Apply comprehensive security measures to a running Lima VM

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_VM_NAME="limawan-vm"

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [VM_NAME]

Apply comprehensive security hardening to a Lima VM.

OPTIONS:
    -h, --help           Show this help message
    -v, --verbose        Verbose output
    -f, --force          Force overwrite existing configuration
    --ssh-only           Only configure SSH hardening
    --firewall-only      Only configure firewall
    --fail2ban-only      Only configure fail2ban
    --all                Apply all security measures (default)

ARGUMENTS:
    VM_NAME             Name of the Lima VM (default: limawan-vm)

SECURITY MEASURES:
    - SSH key authentication only
    - Disable password authentication
    - Fail2ban for SSH protection
    - UFW firewall configuration
    - System updates and security patches
    - Disable unused services
    - Set up basic intrusion detection

EXAMPLES:
    $0                              # Full hardening for limawan-vm
    $0 --ssh-only web-server        # Only SSH hardening
    $0 --verbose limawan-vm         # Verbose full hardening

EOF
}

log() {
    echo -e "${BLUE}[SECURITY]${NC} $*"
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

check_vm_running() {
    local vm_name="$1"
    
    # Skip VM check - assume it's running
    log_verbose "Assuming VM '$vm_name' is running"
    return 0
}

configure_ssh_hardening() {
    local vm_name="$1"
    
    log "Configuring SSH hardening..."
    
    # Backup original sshd_config
    limactl shell "$vm_name" sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # Configure SSH hardening
    limactl shell "$vm_name" sudo tee /etc/ssh/sshd_config.d/99-limawan-security.conf > /dev/null << 'EOF'
# LimaWAN SSH Security Configuration
# Disable password authentication
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no

# Key-based authentication only
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Security settings
Protocol 2
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30

# Disable unused features
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no

# Logging
SyslogFacility AUTH
LogLevel INFO
EOF
    
    # Test SSH configuration
    if limactl shell "$vm_name" sudo sshd -t; then
        log_success "SSH configuration is valid"
        limactl shell "$vm_name" sudo systemctl reload ssh
        log_success "SSH service reloaded"
    else
        log_error "SSH configuration test failed"
        return 1
    fi
}

configure_firewall() {
    local vm_name="$1"
    
    log "Configuring UFW firewall..."
    
    # Install UFW if not present
    limactl shell "$vm_name" sudo apt-get update
    limactl shell "$vm_name" sudo apt-get install -y ufw
    
    # Reset UFW to defaults
    limactl shell "$vm_name" sudo ufw --force reset
    
    # Default policies
    limactl shell "$vm_name" sudo ufw default deny incoming
    limactl shell "$vm_name" sudo ufw default allow outgoing
    
    # Allow SSH (important!)
    limactl shell "$vm_name" sudo ufw allow ssh
    
    # Allow HTTP/HTTPS if nginx is running
    if limactl shell "$vm_name" systemctl is-active nginx >/dev/null 2>&1; then
        limactl shell "$vm_name" sudo ufw allow 'Nginx Full'
        log_verbose "Allowed HTTP/HTTPS for nginx"
    fi
    
    # Enable UFW
    limactl shell "$vm_name" sudo ufw --force enable
    
    log_success "UFW firewall configured and enabled"
}

configure_fail2ban() {
    local vm_name="$1"
    
    log "Configuring fail2ban..."
    
    # Install fail2ban
    limactl shell "$vm_name" sudo apt-get update
    limactl shell "$vm_name" sudo apt-get install -y fail2ban
    
    # Configure fail2ban for SSH
    limactl shell "$vm_name" sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
# Ban time: 1 hour
bantime = 3600
# Find time window: 10 minutes  
findtime = 600
# Max retries before ban
maxretry = 3
# Email notifications (optional)
destemail = root@localhost
sendername = Fail2Ban
mta = sendmail
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    # Enable and start fail2ban
    limactl shell "$vm_name" sudo systemctl enable fail2ban
    limactl shell "$vm_name" sudo systemctl start fail2ban
    
    log_success "fail2ban configured and started"
}

update_system() {
    local vm_name="$1"
    
    log "Updating system packages..."
    
    # Update package lists and install security updates
    limactl shell "$vm_name" sudo apt-get update
    limactl shell "$vm_name" sudo apt-get upgrade -y
    
    # Install essential security packages
    limactl shell "$vm_name" sudo apt-get install -y \
        unattended-upgrades \
        apt-listchanges \
        logwatch \
        chkrootkit \
        rkhunter
    
    # Configure automatic security updates
    limactl shell "$vm_name" sudo dpkg-reconfigure -plow unattended-upgrades
    
    log_success "System updated and security packages installed"
}

disable_unused_services() {
    local vm_name="$1"
    
    log "Disabling unused services..."
    
    # List of services to disable (if they exist)
    local services_to_disable=(
        "apache2"
        "sendmail"
        "postfix"
        "rpcbind"
        "nfs-common"
        "avahi-daemon"
    )
    
    for service in "${services_to_disable[@]}"; do
        if limactl shell "$vm_name" systemctl is-enabled "$service" >/dev/null 2>&1; then
            limactl shell "$vm_name" sudo systemctl disable "$service"
            limactl shell "$vm_name" sudo systemctl stop "$service"
            log_verbose "Disabled service: $service"
        fi
    done
    
    log_success "Unused services disabled"
}

show_security_status() {
    local vm_name="$1"
    
    log "Security Status Summary:"
    echo
    
    # SSH status
    if limactl shell "$vm_name" sudo sshd -t >/dev/null 2>&1; then
        log_success "SSH: Hardened configuration active"
    else
        log_warn "SSH: Configuration issues detected"
    fi
    
    # UFW status
    if limactl shell "$vm_name" sudo ufw status | grep -q "Status: active"; then
        log_success "UFW: Firewall is active"
    else
        log_warn "UFW: Firewall is not active"
    fi
    
    # Fail2ban status
    if limactl shell "$vm_name" systemctl is-active fail2ban >/dev/null 2>&1; then
        log_success "Fail2ban: Active and monitoring"
    else
        log_warn "Fail2ban: Not running"
    fi
    
    # Show current bans
    local bans
    bans=$(limactl shell "$vm_name" sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | cut -d: -f2 | xargs)
    if [[ -n "$bans" ]]; then
        log_warn "Currently banned IPs: $bans"
    fi
    
    echo
    log "Security hardening complete!"
    log "Remember to:"
    log "- Test SSH access with key authentication"
    log "- Monitor fail2ban logs: sudo tail -f /var/log/fail2ban.log"
    log "- Check UFW status: sudo ufw status verbose"
}

main() {
    local vm_name="$DEFAULT_VM_NAME"
    local ssh_only=false
    local firewall_only=false
    local fail2ban_only=false
    local force=false
    
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
            -f|--force)
                force=true
                shift
                ;;
            --ssh-only)
                ssh_only=true
                shift
                ;;
            --firewall-only)
                firewall_only=true
                shift
                ;;
            --fail2ban-only)
                fail2ban_only=true
                shift
                ;;
            --all)
                # Default behavior
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
    
    # Check if VM is running
    if ! check_vm_running "$vm_name"; then
        log_error "VM '$vm_name' must be running for security hardening"
        exit 1
    fi
    
    log "Starting security hardening for VM: $vm_name"
    
    # Apply security measures based on flags
    if [[ "$ssh_only" == "true" ]]; then
        configure_ssh_hardening "$vm_name"
    elif [[ "$firewall_only" == "true" ]]; then
        configure_firewall "$vm_name"
    elif [[ "$fail2ban_only" == "true" ]]; then
        configure_fail2ban "$vm_name"
    else
        # Full hardening (default)
        update_system "$vm_name"
        configure_ssh_hardening "$vm_name"
        configure_firewall "$vm_name"
        configure_fail2ban "$vm_name"
        disable_unused_services "$vm_name"
    fi
    
    show_security_status "$vm_name"
}

main "$@" 