# Firewall Role

This Ansible role sets up iptables firewall rules to secure Docker networking by configuring the DOCKER-USER chain for both IPv4 and IPv6.

## Features

- Creates or clears the DOCKER-USER chain
- Allows established connections
- Allows traffic from specified management networks
- Implements SSH brute force protection (rate limiting)
- Allows specific whitelisted ports
- Drops all other traffic
- Makes the rules persistent
- Supports both IPv4 and IPv6

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `firewall_management_networks_v4` | List of IPv4 management network segments to allow | `[]` |
| `firewall_management_networks_v6` | List of IPv6 management network segments to allow | `[]` |
| `firewall_whitelist_ports_v4` | List of ports to whitelist for IPv4 | `[]` |
| `firewall_whitelist_ports_v6` | List of ports to whitelist for IPv6 | `[]` |
| `ssh_port` | SSH port used for rate limiting | `22` |

## Usage

```yaml
- name: Apply firewall rules
  hosts: servers
  roles:
    - firewall
```

## Notes

- The role automatically includes localhost (127.0.0.0/8 for IPv4 and ::1/128 for IPv6) in the management networks
- Docker network isolation is left to Docker's built-in network management
- The system INPUT chain and Docker's DOCKER-USER chain are both secured

## Requirements

- Requires `iptables` to be available on the target system
- Uses `iptables-persistent` package for persistence
- Rules are saved to standard locations:
  - IPv4: `/etc/iptables/rules.v4`
  - IPv6: `/etc/iptables/rules.v6` 