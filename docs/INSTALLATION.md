# Installation Guide

## Prerequisites

1. A Cloudflare account with your domain
2. Cloudflare API token with Zone:DNS:Edit permissions
3. Cloudflare Tunnel created and credentials downloaded
4. Bare metal server with SSH access (Debian/Ubuntu)
5. Ansible >= 2.10 on your control machine

## Setup Instructions

### 1. Clone this repository

```bash
git clone https://github.com/miupay/miuOps
cd miuOps
```

### 2. Install Ansible requirements

```bash
ansible-galaxy collection install -r requirements.yml
```

### 3. Configure your inventory

```bash
cp inventory.ini.template inventory.ini
```

Edit `inventory.ini` to list your target servers:

```ini
[bare_metal]
server1 ansible_host=192.168.1.10 ansible_user=yourusername
```

### 4. Set your configuration

```bash
cp group_vars/all.yml.template group_vars/all.yml
```

Edit `group_vars/all.yml` to set your domains and credentials:

```yaml
domains:
  - domain: "example.com"
    zone_id: "your_zone_id_here"
```

### 5. Prepare Cloudflare Tunnel credentials

#### Option A: Create a new tunnel

```bash
./scripts/create-tunnel.sh
```

#### Option B: Use an existing tunnel

```bash
mkdir -p files
cp ~/.cloudflared/<TUNNEL_ID>.json files/
```

### 6. Run the playbook

```bash
ansible-playbook playbook.yml
```

The playbook will:
1. Configure iptables firewall (INPUT + DOCKER-USER chains)
2. Install and configure Docker
3. Set up Traefik with automatic TLS
4. Configure Cloudflare Tunnel and create DNS records

You'll be prompted for any missing credentials during execution.

## Post-Installation

Test that your infrastructure is working:
- Services are reachable via `https://<subdomain>.<your-domain>`
- Traefik dashboard at `https://traefik.<your-domain>` (if enabled)

