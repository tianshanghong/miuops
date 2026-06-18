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

## Docker published ports

A container that publishes a host port (e.g. `-p 5000:5000`) is **not** filtered by the `INPUT` chain — Docker DNATs the traffic through `FORWARD`, bypassing host firewalls like ufw, and [by default allows all external source IPs to reach published ports](https://docs.docker.com/engine/network/firewall-iptables/). This role blocks that in the `DOCKER-USER` chain, which Docker evaluates first in `FORWARD`:

- established/related → `RETURN`
- container-originated, i.e. from a bridge (`-i br+`) → `RETURN`
- loopback → bridge (`-i lo -o br+`, for cloudflared → Traefik) → `RETURN`
- everything else (i.e. arriving on the external interface) → `DROP`

So external hosts cannot reach a published port even if a container sets one. Verified end-to-end with external IPv4 and IPv6 probes, and asserted in CI. Notes: on the default IPv4-only Docker network, published ports are not bound on IPv6 at all; host-bound IPv6 ports are covered by the `INPUT` default `DROP`.

Prefer not publishing host ports (use Traefik labels). If you must, bind to loopback: `127.0.0.1:5000:5000`.

## Requirements

- Requires `iptables` to be available on the target system
- Uses `iptables-persistent` package for persistence
- Rules are saved to standard locations:
  - IPv4: `/etc/iptables/rules.v4`
  - IPv6: `/etc/iptables/rules.v6` 