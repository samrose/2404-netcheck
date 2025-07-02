#!/bin/bash

# Ubuntu 24.04 Network Health Check Script
# Comprehensive networking health check including DHCP, NDisc, and IPv6

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
ERRORS=0
WARNINGS=0
CHECKS=0
VERBOSE=0

# Function to print status messages
print_status() {
    local status=$1
    local message=$2
    local details=${3:-""}
    
    case $status in
        "PASS")
            echo -e "${GREEN}✓${NC} $message"
            ;;
        "FAIL")
            echo -e "${RED}✗${NC} $message"
            [[ -n "$details" ]] && echo -e "  ${RED}Details:${NC} $details"
            ((ERRORS++))
            ;;
        "WARN")
            echo -e "${YELLOW}⚠${NC} $message"
            [[ -n "$details" ]] && echo -e "  ${YELLOW}Details:${NC} $details"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "${BLUE}ℹ${NC} $message"
            ;;
    esac
    ((CHECKS++))
}

# Function to run command and capture output
run_command() {
    local cmd="$1"
    local timeout=${2:-10}
    
    if timeout "$timeout" bash -c "$cmd" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to get primary network interface
get_primary_interface() {
    ip route show default | awk '/default/ { print $5; exit }'
}

# Function to check systemd-networkd status
check_systemd_networkd() {
    echo -e "\n${BLUE}=== SystemD NetworkD Status ===${NC}"
    
    if systemctl is-active systemd-networkd >/dev/null 2>&1; then
        print_status "PASS" "systemd-networkd is active and running"
    else
        print_status "FAIL" "systemd-networkd is not active" "$(systemctl status systemd-networkd --no-pager -l)"
        return
    fi
    
    # Check for recent errors
    local recent_errors
    recent_errors=$(journalctl -u systemd-networkd --since "1 hour ago" --no-pager | grep -i "error\|fail\|could not" | wc -l)
    
    if [[ $recent_errors -eq 0 ]]; then
        print_status "PASS" "No recent systemd-networkd errors"
    else
        local error_details
        error_details=$(journalctl -u systemd-networkd --since "1 hour ago" --no-pager | grep -i "error\|fail\|could not" | tail -3)
        print_status "WARN" "Found $recent_errors recent systemd-networkd errors" "$error_details"
    fi
    
    # Check for NDisc errors specifically
    local ndisc_errors
    ndisc_errors=$(journalctl -u systemd-networkd --since "24 hours ago" --no-pager | grep -i "could not set ndisc route" | wc -l)
    
    if [[ $ndisc_errors -eq 0 ]]; then
        print_status "PASS" "No recent NDisc route errors"
    else
        print_status "FAIL" "Found $ndisc_errors NDisc route errors in the last 24 hours" "Consider setting ManageForeignRoutes=no in networkd.conf"
    fi
}

# Function to check systemd-resolved status
check_systemd_resolved() {
    echo -e "\n${BLUE}=== SystemD Resolved Status ===${NC}"
    
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        print_status "PASS" "systemd-resolved is active and running"
    else
        print_status "WARN" "systemd-resolved is not active" "DNS resolution may not work properly"
    fi
    
    # Check DNS configuration
    if command_exists resolvectl; then
        local dns_servers
        dns_servers=$(resolvectl dns 2>/dev/null | grep -v "Link.*():" | wc -l)
        if [[ $dns_servers -gt 0 ]]; then
            print_status "PASS" "DNS servers are configured"
            [[ $VERBOSE -eq 1 ]] && resolvectl dns
        else
            print_status "WARN" "No DNS servers configured"
        fi
    fi
}

# Function to check network interfaces
check_network_interfaces() {
    echo -e "\n${BLUE}=== Network Interface Status ===${NC}"
    
    local primary_interface
    primary_interface=$(get_primary_interface)
    
    if [[ -n "$primary_interface" ]]; then
        print_status "PASS" "Primary interface detected: $primary_interface"
        
        # Check interface status with networkctl
        if command_exists networkctl; then
            local interface_state
            interface_state=$(networkctl status "$primary_interface" 2>/dev/null | grep "State:" | awk '{print $2}' || echo "unknown")
            
            case $interface_state in
                "routable"|"configured")
                    print_status "PASS" "Interface $primary_interface is in $interface_state state"
                    ;;
                "configuring")
                    print_status "WARN" "Interface $primary_interface is still configuring" "This may be temporary"
                    ;;
                "failed")
                    print_status "FAIL" "Interface $primary_interface is in failed state"
                    ;;
                *)
                    print_status "WARN" "Interface $primary_interface is in unknown state: $interface_state"
                    ;;
            esac
        fi
        
        # Check if interface has carrier
        local carrier_file="/sys/class/net/$primary_interface/carrier"
        if [[ -f "$carrier_file" ]]; then
            local carrier
            carrier=$(cat "$carrier_file" 2>/dev/null || echo "0")
            if [[ "$carrier" == "1" ]]; then
                print_status "PASS" "Interface $primary_interface has physical link (carrier detected)"
            else
                print_status "FAIL" "Interface $primary_interface has no physical link (no carrier)"
            fi
        fi
    else
        print_status "FAIL" "No primary network interface detected"
    fi
    
    # Check for any failed interfaces
    if command_exists networkctl; then
        local failed_interfaces
        failed_interfaces=$(networkctl list 2>/dev/null | grep -c "failed" || echo "0")
        if [[ $failed_interfaces -eq 0 ]]; then
            print_status "PASS" "No failed network interfaces"
        else
            print_status "FAIL" "$failed_interfaces interface(s) in failed state"
        fi
    fi
}

# Function to check DHCP status
check_dhcp_status() {
    echo -e "\n${BLUE}=== DHCP Status ===${NC}"
    
    local primary_interface
    primary_interface=$(get_primary_interface)
    
    if [[ -n "$primary_interface" ]]; then
        # Check for DHCP lease
        local dhcp_lease
        dhcp_lease=$(journalctl -u systemd-networkd --since "1 hour ago" --no-pager | grep -i "dhcp.*address.*via" | tail -1)
        
        if [[ -n "$dhcp_lease" ]]; then
            print_status "PASS" "DHCP lease obtained recently"
            [[ $VERBOSE -eq 1 ]] && echo "  Latest: $dhcp_lease"
        else
            print_status "WARN" "No recent DHCP lease activity" "May be using static configuration"
        fi
        
        # Check for DHCP errors
        local dhcp_errors
        dhcp_errors=$(journalctl -u systemd-networkd --since "1 hour ago" --no-pager | grep -i "dhcp.*fail\|dhcp.*error" | wc -l)
        
        if [[ $dhcp_errors -eq 0 ]]; then
            print_status "PASS" "No recent DHCP errors"
        else
            print_status "FAIL" "$dhcp_errors DHCP errors in the last hour"
        fi
    fi
    
    # Check if we have a default route
    if ip route show default >/dev/null 2>&1; then
        local default_route
        default_route=$(ip route show default | head -1)
        print_status "PASS" "IPv4 default route is configured"
        [[ $VERBOSE -eq 1 ]] && echo "  Route: $default_route"
    else
        print_status "FAIL" "No IPv4 default route configured"
    fi
}

# Function to check IPv6 configuration
check_ipv6_status() {
    echo -e "\n${BLUE}=== IPv6 Status ===${NC}"
    
    # Check if IPv6 is enabled
    local ipv6_disabled
    ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    
    if [[ "$ipv6_disabled" == "0" ]]; then
        print_status "PASS" "IPv6 is enabled system-wide"
    else
        print_status "WARN" "IPv6 is disabled system-wide" "Some features may not work"
        return
    fi
    
    local primary_interface
    primary_interface=$(get_primary_interface)
    
    if [[ -n "$primary_interface" ]]; then
        # Check for IPv6 link-local address
        local ipv6_ll
        ipv6_ll=$(ip -6 addr show "$primary_interface" | grep -c "inet6 fe80:" || echo "0")
        
        if [[ $ipv6_ll -gt 0 ]]; then
            print_status "PASS" "IPv6 link-local address configured on $primary_interface"
        else
            print_status "FAIL" "No IPv6 link-local address on $primary_interface"
        fi
        
        # Check for IPv6 global address
        local ipv6_global
        ipv6_global=$(ip -6 addr show "$primary_interface" | grep -v "inet6 fe80:" | grep -c "inet6" || echo "0")
        
        if [[ $ipv6_global -gt 0 ]]; then
            print_status "PASS" "IPv6 global address(es) configured on $primary_interface"
        else
            print_status "WARN" "No IPv6 global addresses on $primary_interface" "May be normal if IPv6 is not provided by network"
        fi
        
        # Check IPv6 default route
        if ip -6 route show default >/dev/null 2>&1; then
            print_status "PASS" "IPv6 default route is configured"
        else
            print_status "WARN" "No IPv6 default route" "Normal if IPv6 is not provided by network"
        fi
    fi
    
    # Check for Router Advertisement processing
    local ra_activity
    ra_activity=$(journalctl -u systemd-networkd --since "1 hour ago" --no-pager | grep -i "router.*advertisement\|ndisc.*router" | wc -l)
    
    if [[ $ra_activity -gt 0 ]]; then
        print_status "PASS" "Router Advertisement activity detected"
    else
        print_status "INFO" "No recent Router Advertisement activity" "Normal if network doesn't provide IPv6"
    fi
}

# Function to test connectivity
check_connectivity() {
    echo -e "\n${BLUE}=== Connectivity Tests ===${NC}"
    
    # Test IPv4 connectivity
    if run_command "ping -c 2 -W 5 8.8.8.8" 10; then
        print_status "PASS" "IPv4 connectivity to 8.8.8.8"
    else
        print_status "FAIL" "IPv4 connectivity test failed"
    fi
    
    # Test IPv4 DNS resolution
    if run_command "ping -c 2 -W 5 google.com" 10; then
        print_status "PASS" "IPv4 DNS resolution and connectivity"
    else
        print_status "FAIL" "IPv4 DNS resolution or connectivity failed"
    fi
    
    # Test IPv6 connectivity (only if IPv6 is available)
    local ipv6_available
    ipv6_available=$(ip -6 addr show | grep -v "inet6 ::1\|inet6 fe80:" | grep -c "inet6" || echo "0")
    
    if [[ $ipv6_available -gt 0 ]]; then
        if run_command "ping6 -c 2 -W 5 2001:4860:4860::8888" 10; then
            print_status "PASS" "IPv6 connectivity to Google DNS"
        else
            print_status "WARN" "IPv6 connectivity test failed" "May be normal if ISP doesn't provide IPv6"
        fi
        
        if run_command "ping6 -c 2 -W 5 ipv6.google.com" 10; then
            print_status "PASS" "IPv6 DNS resolution and connectivity"
        else
            print_status "WARN" "IPv6 DNS resolution or connectivity failed"
        fi
    else
        print_status "INFO" "Skipping IPv6 connectivity tests (no global IPv6 addresses)"
    fi
}

# Function to check DNS resolution
check_dns_resolution() {
    echo -e "\n${BLUE}=== DNS Resolution Tests ===${NC}"
    
    # Test basic DNS resolution
    if run_command "nslookup google.com" 10; then
        print_status "PASS" "Basic DNS resolution working"
    else
        print_status "FAIL" "Basic DNS resolution failed"
    fi
    
    # Test IPv6 DNS resolution
    if command_exists dig; then
        if run_command "dig google.com AAAA +short" 10; then
            print_status "PASS" "IPv6 DNS (AAAA) resolution working"
        else
            print_status "WARN" "IPv6 DNS (AAAA) resolution failed"
        fi
    fi
    
    # Check /etc/resolv.conf
    if [[ -f /etc/resolv.conf ]]; then
        if [[ -L /etc/resolv.conf ]]; then
            local resolv_target
            resolv_target=$(readlink /etc/resolv.conf)
            if [[ "$resolv_target" == *"systemd"* ]]; then
                print_status "PASS" "/etc/resolv.conf correctly managed by systemd"
            else
                print_status "WARN" "/etc/resolv.conf points to unexpected target: $resolv_target"
            fi
        else
            print_status "WARN" "/etc/resolv.conf is not a symbolic link" "May indicate manual DNS configuration"
        fi
    else
        print_status "FAIL" "/etc/resolv.conf does not exist"
    fi
}

# Function to check network configuration files
check_network_configuration() {
    echo -e "\n${BLUE}=== Network Configuration ===${NC}"
    
    # Check netplan configuration
    if command_exists netplan && [[ -d /etc/netplan ]]; then
        local netplan_files
        netplan_files=$(find /etc/netplan -name "*.yaml" -o -name "*.yml" | wc -l)
        
        if [[ $netplan_files -gt 0 ]]; then
            print_status "PASS" "Netplan configuration files found ($netplan_files files)"
            
            # Validate netplan configuration
            if run_command "netplan generate" 5; then
                print_status "PASS" "Netplan configuration is valid"
            else
                print_status "FAIL" "Netplan configuration has errors"
            fi
        else
            print_status "INFO" "No netplan configuration files found"
        fi
    fi
    
    # Check networkd configuration
    if [[ -d /etc/systemd/network ]]; then
        local networkd_files
        networkd_files=$(find /etc/systemd/network -name "*.network" -o -name "*.netdev" | wc -l)
        
        if [[ $networkd_files -gt 0 ]]; then
            print_status "INFO" "systemd-networkd configuration files found ($networkd_files files)"
        fi
    fi
    
    # Check for ManageForeignRoutes setting
    local foreign_routes_config=""
    
    # Check main config file
    if [[ -f /etc/systemd/networkd.conf ]]; then
        foreign_routes_config=$(grep -i "ManageForeignRoutes" /etc/systemd/networkd.conf 2>/dev/null || echo "")
    fi
    
    # Check drop-in files
    if [[ -d /etc/systemd/networkd.conf.d ]]; then
        local dropins
        dropins=$(find /etc/systemd/networkd.conf.d -name "*.conf" -exec grep -l "ManageForeignRoutes" {} \; 2>/dev/null || echo "")
        if [[ -n "$dropins" ]]; then
            foreign_routes_config="found in drop-ins"
        fi
    fi
    
    if [[ -n "$foreign_routes_config" ]]; then
        print_status "INFO" "ManageForeignRoutes configuration found" "Good for preventing NDisc route issues"
    else
        print_status "INFO" "ManageForeignRoutes not configured" "Consider setting to 'no' if experiencing NDisc issues"
    fi
}

# Function to show summary
show_summary() {
    echo -e "\n${BLUE}=== Health Check Summary ===${NC}"
    echo "Total checks performed: $CHECKS"
    
    if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}✓ All checks passed! Network appears healthy.${NC}"
        exit 0
    elif [[ $ERRORS -eq 0 ]]; then
        echo -e "${YELLOW}⚠ $WARNINGS warning(s) found, but no critical errors.${NC}"
        exit 0
    else
        echo -e "${RED}✗ $ERRORS error(s) and $WARNINGS warning(s) found.${NC}"
        echo -e "\n${YELLOW}Common fixes for Ubuntu 24.04:${NC}"
        echo "1. For NDisc route errors:"
        echo "   sudo mkdir -p /etc/systemd/networkd.conf.d/"
        echo "   echo -e '[Network]\\nManageForeignRoutes=no' | sudo tee /etc/systemd/networkd.conf.d/99-foreign-routes.conf"
        echo "   sudo systemctl restart systemd-networkd"
        echo ""
        echo "2. For systemd-networkd issues:"
        echo "   sudo systemctl restart systemd-networkd"
        echo "   sudo systemctl restart systemd-resolved"
        echo ""
        echo "3. For netplan issues:"
        echo "   sudo netplan try"
        echo "   sudo netplan apply"
        exit 1
    fi
}

# Function to show help
show_help() {
    cat << EOF
Ubuntu 24.04 Network Health Check Script

Usage: $0 [OPTIONS]

OPTIONS:
    -v, --verbose    Show detailed output
    -h, --help       Show this help message

This script performs comprehensive network health checks including:
- systemd-networkd status and errors
- systemd-resolved status
- Network interface status
- DHCP configuration
- IPv6 and NDisc status
- Connectivity tests
- DNS resolution tests
- Network configuration validation

Exit codes:
    0 - All checks passed or only warnings
    1 - Critical errors found
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check if running as root for some commands
if [[ $EUID -ne 0 ]]; then
    print_status "WARN" "Not running as root" "Some checks may have limited information"
fi

# Main execution
echo -e "${BLUE}Ubuntu 24.04 Network Health Check${NC}"
echo "=================================="

check_systemd_networkd
check_systemd_resolved
check_network_interfaces
check_dhcp_status
check_ipv6_status
check_connectivity
check_dns_resolution
check_network_configuration

show_summary
