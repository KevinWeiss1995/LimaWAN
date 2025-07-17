# LimaWAN

**Expose Lima VMs on macOS to the public internet using macOS Packet Filter (PF) port forwarding.**

LimaWAN enables secure, configurable WAN access to services running inside Lima VMs — no TAP, no bridge, no kernel extensions required.

## Overview

LimaWAN provides a safe and reproducible way to expose Lima virtual machines to the public internet using macOS's built-in Packet Filter (PF) firewall. Unlike traditional bridged networking solutions, LimaWAN uses PF's port forwarding capabilities to selectively expose VM services while maintaining security.

```
┌─────────────────────────────────────────────────────────────────┐
│                          Internet                               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│                     Router/ISP                                 │
│                   (Port Forward)                               │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│                    macOS Host                                  │
│                                                                │
│  ┌─────────────┐       ┌─────────────┐       ┌─────────────┐  │
│  │   Router    │  WAN  │     PF      │  FWD  │ Lima VM     │  │
│  │   :2222     │◄──────┤  Firewall   │◄──────┤ :22 (SSH)   │  │
│  │   :8080     │       │  Rules      │       │ :80 (HTTP)  │  │
│  └─────────────┘       └─────────────┘       └─────────────┘  │
│                                                                │
│  Interface: en0         Anchor: limawan      IP: 192.168.105.10│
└─────────────────────────────────────────────────────────────────┘
```

### Key Features

- **No kernel extensions**: Uses macOS built-in PF firewall
- **No TAP/bridge setup**: Simple port forwarding approach
- **Security-focused**: Configurable rules with fail-safe defaults
- **Reproducible**: Scriptable setup and teardown
- **Persistent**: Optional LaunchDaemon for boot-time setup
- **Diagnostic tools**: Comprehensive testing and monitoring

## Why Not Bridged?

Traditional bridged networking solutions require:
- TAP interface creation (complex setup)
- Kernel extensions or system modifications
- Layer 2 broadcast handling
- Complex network configuration

LimaWAN's PF-based approach provides:
- **Simplicity**: Pure Layer 3 port forwarding
- **Security**: Selective service exposure
- **Reliability**: Uses battle-tested PF firewall
- **Maintainability**: Standard macOS networking stack

## Security Implications

⚠️ **Important**: Exposing VM services to the internet carries security risks.

### Risks
- **Direct WAN exposure**: Services become publicly accessible
- **Attack surface**: Increased exposure to malicious traffic
- **VM compromise**: Potential lateral movement from compromised services
- **Network scanning**: Automated discovery of exposed services

### Mitigations
- **Service hardening**: Disable unnecessary services
- **Authentication**: Strong key-based authentication (SSH)
- **Intrusion detection**: fail2ban, monitoring
- **Firewall rules**: Restrictive PF configurations
- **Regular updates**: Keep VM and services patched

### Best Practices
1. **Use SSH keys** instead of passwords
2. **Enable fail2ban** for intrusion detection
3. **Restrict port ranges** to non-standard ports (1024-65535)
4. **Monitor logs** regularly
5. **Update regularly** both host and VM systems

## Getting Started

### Prerequisites

- macOS 12+ (Monterey or later)
- Lima >= 0.15
- Administrative privileges (`sudo` access)
- Basic understanding of networking and security

### Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-username/LimaWAN.git
   cd LimaWAN
   ```

2. **Make scripts executable**:
   ```bash
   chmod +x scripts/*.sh test/*.sh tools/*.sh
   ```

3. **Create a Lima VM with known IP**:
   ```bash
   lima start --name limawan-vm samples/lima.yaml
   ```

4. **Set up port forwarding**:
   ```bash
   sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 22 -e 2222
   ```

### Quick Start Example

```bash
# 1. Start Lima VM
lima start --name web-server samples/lima.yaml

# 2. Set up SSH forwarding
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 22 -e 2222

# 3. Set up HTTP forwarding
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 80 -e 8080

# 4. Test connectivity
scripts/diagnostics.sh -v 192.168.105.10 -i 22 -e 2222

# 5. Test SSH access
test/test_ssh_access.sh -e 2222
```

## Exposing SSH to WAN

SSH is the most common service to expose. Here's how to do it safely:

### Setup

1. **Configure SSH forwarding**:
   ```bash
   sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 22 -e 2222
   ```

2. **Test local connectivity**:
   ```bash
   ssh -p 2222 user@localhost
   ```

3. **Configure router port forwarding**:
   - Router: Forward external port 2222 → macOS host port 2222
   - Firewall: Allow incoming connections on port 2222

### Security Hardening

1. **Disable password authentication**:
   ```bash
   # In VM: /etc/ssh/sshd_config
   PasswordAuthentication no
   ChallengeResponseAuthentication no
   PubkeyAuthentication yes
   PermitRootLogin no
   ```

2. **Set up fail2ban** (automatically configured in sample lima.yaml):
   ```bash
   # Already configured in the sample VM
   sudo systemctl status fail2ban
   ```

3. **Use SSH keys only**:
   ```bash
   # Copy your public key to VM
   ssh-copy-id -p 2222 user@localhost
   ```

4. **Monitor SSH logs**:
   ```bash
   # In VM
   sudo tail -f /var/log/auth.log
   ```

### Testing External Access

```bash
# Test from external network
ssh -p 2222 user@YOUR_PUBLIC_IP

# Or use the test script
test/test_ssh_access.sh -e 2222 --external
```

## Exposing HTTP to WAN

HTTP services require additional security considerations:

### Setup

1. **Configure HTTP forwarding**:
   ```bash
   sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 80 -e 8080
   ```

2. **Test local access**:
   ```bash
   curl http://localhost:8080
   ```

3. **Configure router**:
   - Forward external port 80 → macOS host port 8080
   - Or use non-standard port for security

### Security Considerations

1. **Use HTTPS when possible**:
   ```bash
   # Set up HTTPS forwarding
   sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 443 -e 8443
   ```

2. **Web application firewall**:
   - Configure nginx/Apache with security modules
   - Rate limiting and DDoS protection

3. **Regular security updates**:
   ```bash
   # In VM
   sudo apt update && sudo apt upgrade -y
   ```

### Testing HTTP Access

```bash
# Test HTTP service
curl -I http://localhost:8080

# Test external access
curl -I http://YOUR_PUBLIC_IP:8080
```

## Restoring Default PF Config

To completely remove LimaWAN configuration:

### Method 1: Using teardown script

```bash
sudo scripts/teardown_pf_forwarding.sh
```

### Method 2: Manual cleanup

```bash
# Stop PF
sudo pfctl -d

# Remove LimaWAN anchor
sudo rm -f /etc/pf.anchors/limawan

# Edit /etc/pf.conf and remove LimaWAN anchor section
sudo nano /etc/pf.conf

# Restart PF
sudo pfctl -f /etc/pf.conf
sudo pfctl -e
```

### Method 3: Restore from backup

```bash
# If backup exists
sudo cp /etc/pf.conf.bak /etc/pf.conf
sudo pfctl -f /etc/pf.conf
```

## Troubleshooting

### Common Issues

#### PF Rules Not Loading

**Symptoms**: Rules appear in config but don't work
```bash
# Check PF status
sudo pfctl -s info

# Check anchor rules
sudo pfctl -a limawan -s rules
```

**Solutions**:
```bash
# Reload PF configuration
sudo scripts/enable_pf.sh

# Check for syntax errors
sudo pfctl -n -f /etc/pf.conf
```

#### VM Not Reachable

**Symptoms**: Cannot ping or connect to VM
```bash
# Test VM connectivity
ping 192.168.105.10
```

**Solutions**:
```bash
# Check Lima VM status
lima list

# Restart Lima VM
lima stop limawan-vm
lima start limawan-vm

# Check VM IP configuration
lima shell limawan-vm ip addr show
```

#### Port Forwarding Not Working

**Symptoms**: External connections fail
```bash
# Test local port forwarding
nc -z localhost 2222
```

**Solutions**:
```bash
# Check PF rules
sudo pfctl -a limawan -s nat

# Verify port is open in VM
lima shell limawan-vm netstat -tlnp | grep :22

# Test internal connectivity
nc -z 192.168.105.10 22
```

#### Permission Denied

**Symptoms**: Scripts fail with permission errors
```bash
# Common error
pfctl: /dev/pf: Permission denied
```

**Solutions**:
```bash
# Run with sudo
sudo scripts/setup_pf_forwarding.sh

# Check script permissions
ls -la scripts/
```

### Diagnostic Tools

#### Basic Diagnostics

```bash
# Run comprehensive diagnostics
scripts/diagnostics.sh -v 192.168.105.10 -i 22 -e 2222

# Quick system check
scripts/diagnostics.sh --quick

# Generate diagnostic report
scripts/diagnostics.sh --report
```

#### Configuration Debugging

```bash
# Show current configuration
tools/show_config.sh

# Show compact summary
tools/show_config.sh --compact

# Show detailed statistics
tools/show_config.sh --stats --verbose
```

#### Test Scripts

```bash
# Validate PF rules
test/test_pf_rules.sh

# Test with simulation
test/test_pf_rules.sh --simulate --dry-run

# Test SSH access
test/test_ssh_access.sh -e 2222

# Test external SSH access
test/test_ssh_access.sh -e 2222 --external
```

### Log Analysis

#### PF Logs

```bash
# Check system logs for PF
sudo log show --predicate 'subsystem == "com.apple.kernel.pflog"' --last 1h

# Monitor real-time PF activity
sudo tcpdump -i pflog0
```

#### Lima Logs

```bash
# Check Lima logs
lima shell limawan-vm journalctl -f

# Check specific service logs
lima shell limawan-vm sudo journalctl -u ssh
lima shell limawan-vm sudo journalctl -u nginx
```

### Performance Issues

#### High CPU Usage

```bash
# Check PF performance
sudo pfctl -s info | grep -A 10 "Counters"

# Monitor system resources
top -l 1 | grep -E "(CPU|Load)"
```

#### Network Latency

```bash
# Test network performance
ping -c 10 192.168.105.10

# Test port forwarding latency
time ssh -p 2222 user@localhost exit
```

## FAQ

### General Questions

**Q: Does LimaWAN work with all Lima VM operating systems?**
A: Yes, LimaWAN works with any Lima VM OS since it operates at the network layer. The sample configuration uses Ubuntu, but you can adapt it for other distributions.

**Q: Can I expose multiple services from the same VM?**
A: Yes, run the setup script multiple times with different port combinations:
```bash
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 22 -e 2222   # SSH
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 80 -e 8080   # HTTP
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 443 -e 8443  # HTTPS
```

**Q: Can I use custom VM IP addresses?**
A: Yes, modify the `lima.yaml` configuration and update the scripts accordingly. The default IP `192.168.105.10` is just a convention.

### Security Questions

**Q: Is it safe to expose services to the internet?**
A: Only if properly configured. Follow the security hardening guidelines, use strong authentication, enable monitoring, and keep systems updated.

**Q: What ports should I use for external access?**
A: Use non-standard ports (1024-65535) to avoid automated scanning. For example, use port 2222 for SSH instead of 22.

**Q: How do I set up HTTPS?**
A: Configure SSL certificates in your web server (nginx/Apache) and forward port 443:
```bash
sudo scripts/setup_pf_forwarding.sh -v 192.168.105.10 -i 443 -e 8443
```

### Technical Questions

**Q: Why does LimaWAN use PF instead of pfctl directly?**
A: PF provides more granular control, better security features, and integrates with macOS's network stack. Direct pfctl usage is more complex and error-prone.

**Q: Can I use LimaWAN with multiple VMs?**
A: Yes, use different IP addresses for each VM and configure separate port forwarding rules. Each VM should have a unique IP in the subnet.

**Q: What's the difference between LimaWAN and Lima's built-in port forwarding?**
A: Lima's port forwarding is host-only (localhost). LimaWAN exposes services to the public internet through PF firewall rules.

### Troubleshooting Questions

**Q: The VM is not getting the expected IP address**
A: Check the `lima.yaml` configuration, ensure the cloud-init network configuration is correct, and verify the VM's network settings:
```bash
lima shell limawan-vm ip addr show
```

**Q: PF rules are not persisting after reboot**
A: Install the LaunchDaemon for persistence:
```bash
sudo cp plists/org.limawan.firewall.plist /Library/LaunchDaemons/
sudo launchctl load /Library/LaunchDaemons/org.limawan.firewall.plist
```

**Q: How do I update LimaWAN configuration?**
A: Re-run the setup script with new parameters, or manually edit the anchor file at `/etc/pf.anchors/limawan` and reload PF:
```bash
sudo pfctl -f /etc/pf.conf
```

### Advanced Usage

**Q: Can I customize the PF rules?**
A: Yes, use the anchor generator tool:
```bash
tools/gen_anchor.sh -i 22 -e 2222 -s SSH > custom_rules.txt
```

**Q: How do I monitor network traffic?**
A: Use built-in tools:
```bash
# Monitor PF traffic
sudo tcpdump -i pflog0

# Check connection states
sudo pfctl -s states

# Monitor specific ports
sudo lsof -i :2222
```

**Q: Can I integrate LimaWAN with other tools?**
A: Yes, LimaWAN is designed to work with:
- Dynamic DNS services (for changing IP addresses)
- Reverse proxies (nginx, Caddy)
- Monitoring systems (Prometheus, Grafana)
- CI/CD pipelines (automated deployment)

## Router and Cloud Configuration

### Home Router Setup

Most home routers require port forwarding configuration:

1. **Access router admin panel** (typically http://192.168.1.1)
2. **Navigate to Port Forwarding/NAT** section
3. **Add forwarding rules**:
   - Service: SSH
   - External Port: 2222
   - Internal IP: [Your Mac's IP]
   - Internal Port: 2222
   - Protocol: TCP

### Cloud/VPS Setup

For cloud instances or VPS:

1. **Security Groups/Firewall**:
   ```bash
   # Allow SSH access
   ufw allow 2222/tcp
   
   # Allow HTTP access
   ufw allow 8080/tcp
   ```

2. **Dynamic DNS** (for changing IP addresses):
   ```bash
   # Example with ddclient
   sudo apt install ddclient
   
   # Configure in /etc/ddclient.conf
   protocol=dyndns2
   use=web
   server=domains.google.com
   login=your-username
   password=your-password
   your-domain.com
   ```

### Static IP vs Dynamic DNS

#### Static IP Configuration
```bash
# If you have a static IP
EXTERNAL_IP="203.0.113.10"
echo "Access via: ssh -p 2222 user@${EXTERNAL_IP}"
```

#### Dynamic DNS Configuration
```bash
# For dynamic IP addresses
DOMAIN="your-domain.duckdns.org"
echo "Access via: ssh -p 2222 user@${DOMAIN}"

# Update script (add to cron)
curl "https://www.duckdns.org/update?domains=your-domain&token=your-token"
```

### NAT and Firewall Considerations

#### Double NAT Detection
```bash
# Check if you're behind double NAT
curl -s https://ipinfo.io/ip
traceroute 8.8.8.8 | head -5
```

#### ISP Restrictions
- **Port 80/443**: Often blocked by ISPs
- **Port 22**: May be filtered or rate-limited
- **Port 25**: Usually blocked for SMTP
- **High ports**: Generally unrestricted

#### Alternative Solutions
```bash
# Use alternative ports
SSH_PORT=2222
HTTP_PORT=8080
HTTPS_PORT=8443

# Or use reverse proxy services
# Cloudflare Tunnel, ngrok, etc.
```

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## Support

For issues and questions:
- Create an issue on GitHub
- Check the troubleshooting section
- Run diagnostic tools for debugging information

## Acknowledgments

- Lima project for providing excellent VM management
- OpenBSD PF team for the robust firewall system
- macOS networking stack for reliable foundation 