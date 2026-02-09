# ADCTP (Ansible + Docker + Cloudflare Tunnel + Traefik + Portainer)

This Ansible playbook automates the deployment of a Docker-based infrastructure with:
- **Traefik** for reverse proxy and automatic TLS certificate management
- **Cloudflare Tunnel** for secure, encrypted connections without exposing ports to the internet
- **Portainer CE** for web-based Docker management
- **iptables Firewall** for securing both system and Docker networking

## Architecture Overview

This setup creates a secure, automated infrastructure where:
- Traffic flows through Cloudflare's network for security and performance
- Services are automatically assigned subdomains with valid TLS certificates
- No ports need to be exposed to the internet
- New services can be deployed by simply adding labels to containers
- System and Docker networking are secured with iptables rules

```
                Internet Users
                      |
                      ↓
  ┌─────────────────────────────────────┐
  │  INPUT iptables chain (system)      │
  └─────────────────────────────────────┘
                      |
              [DNS: *.example.com]
                      |
                Cloudflare CDN/WAF
                      |
           ┌──────────┴──────────┐
           │  Cloudflare Tunnel  │
           └──────────┬──────────┘
                      |
                  cloudflared
                      |
                   Traefik
                      |
   ┌─────────────────────────────────────┐
   │  DOCKER-USER iptables chain         │
   └─────────────────────────────────────┘
                      |
                Docker Services
```

## Repository Structure

This repository has been organized into the following directories:

```
.
├── ansible.cfg            # Ansible configuration file
├── docs/                  # Documentation files
├── examples/              # Example configuration files
├── files/                 # Files used by Ansible (tunnel credentials)
├── group_vars/            # Variables for Ansible groups
├── playbook.yml           # Main Ansible playbook
├── requirements.yml       # Ansible Galaxy requirements
├── roles/                 # Ansible roles
└── scripts/               # Utility scripts
```

For detailed information about the repository structure, see [docs/STRUCTURE.md](docs/STRUCTURE.md).

## Prerequisites

1. A Cloudflare account with your domain
2. Cloudflare API token with Zone:DNS:Edit permissions
3. Cloudflare Tunnel created and credentials downloaded
4. Bare metal servers with SSH access
5. Ansible ≥ 2.10 on your control machine
6. Compatible bcrypt Python package (see Compatibility Notes section)

You can check if your system meets the prerequisites by running:

```bash
./scripts/check-prereqs.sh
```

## Quick Start

For detailed installation instructions, see [docs/INSTALLATION.md](docs/INSTALLATION.md).

```bash
# Clone repository
git clone https://github.com/tianshanghong/metal
cd metal

# Check prerequisites
./scripts/check-prereqs.sh

# Install Ansible requirements
ansible-galaxy collection install -r requirements.yml

# Configure (copy from examples)
cp examples/inventory.ini.template inventory.ini
cp examples/all.yml.template group_vars/all.yml

# Edit configuration files
nano inventory.ini
nano group_vars/all.yml

# Create Cloudflare Tunnel
./scripts/create-tunnel.sh
# OR copy existing tunnel credentials
cp ~/.cloudflared/<TUNNEL_ID>.json files/

# Run playbook to deploy infrastructure and set up DNS
ansible-playbook playbook.yml
```

## Domain Configuration

This playbook supports both single and multiple domains through a simple configuration structure. In your `group_vars/all.yml` file:

```yaml
# List of all domains to be configured with Cloudflare Tunnel
# First domain will be used as default for services without explicit domain
domains:
  - domain: "example.com"
    zone_id: "your_zone_id_here"  # Cloudflare Zone ID from dashboard
  - domain: "anotherdomain.com"
    zone_id: "another_zone_id_here"
```

To set up your domains:

1. Add all domains to your Cloudflare account with Cloudflare Tunnel enabled

2. Obtain the Zone ID for each domain from your Cloudflare dashboard:
   - Log in to Cloudflare
   - Select your domain
   - The Zone ID is displayed on the right side of the Overview page

3. Update your `group_vars/all.yml` file with the domains and their Zone IDs

4. Deploy your infrastructure with Ansible:
   ```bash
   ansible-playbook playbook.yml
   ```

The playbook will configure Cloudflare Tunnel for all your domains, create DNS records, and set up the routing rules.

## Adding New Services

To add a new service, use Docker Compose and add these labels:

```yaml
services:
  myapp:
    image: myapp:latest
    networks:
      - traefik_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=le"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"

networks:
  traefik_network:
    external: true
```

For services on additional domains, simply change the Host rule:

```yaml
- "traefik.http.routers.myapp2.rule=Host(`app.anotherdomain.com`)"
```

The `networks` section is required to connect your service to the existing Traefik network, and the `external: true` property ensures Docker uses the pre-existing network rather than creating a new one.

Remember that each router name (e.g., `myapp`, `myapp2`) must be unique across all your services.

## Optional Remote Dev Box

Need a persistent coding environment on the same host? Enable the `dev_box` role to install tmux, mosh, zsh, NVM/Node, and the Codex CLI for the Ansible SSH user. Flip `dev_box_enabled: true` in your vars (see `docs/DEV_BOX.md`) and re-run the playbook—the host becomes a ready-to-code remote workstation you can reach via SSH or mosh.

## Tunnel Management

This project separates concerns between tunnel management (scripts) and DNS management (Ansible):

- **create-tunnel.sh**: Creates Cloudflare Tunnels and prepares credentials
- **delete-tunnel.sh**: Deletes Cloudflare Tunnels and cleans up credentials
- **Ansible Playbook**: Manages all DNS records and infrastructure deployment

This separation ensures that DNS records stay in sync with your configuration and prevents conflicts between manual and automated management.

## Security Notes

- No ports are exposed to the internet as all traffic flows through Cloudflare Tunnel
- All traffic is encrypted with TLS
- Cloudflare provides DDoS protection and WAF capabilities
- The setup minimizes attack surface by exposing only necessary services
- Comprehensive iptables firewall protection:
  - System INPUT chain secures the host system itself:
    - Allows established connections and loopback traffic
    - Permits access from management networks
    - Whitelists specific service ports (SSH, etc.)
  - DOCKER-USER chain secures container networking:
    - Blocks all direct external access to containers
    - Allows only established connections
  - Zero public exposure of container services
  - Both IPv4 and IPv6 are properly secured
  - Rules persist across reboots via iptables-persistent
- Sensitive files and credentials are excluded from version control:
  - Server information (`inventory.ini`)
  - API tokens and credentials (`group_vars/all.yml`)
  - Tunnel credentials (`files/*.json`)
- Interactive prompts are used to collect credentials securely during deployment
- Secure password handling:
  - Traefik dashboard uses SHA-512 hashed passwords
  - Portainer uses bcrypt hashed passwords set at container startup

## Customization

- Modify the Traefik configuration in `roles/traefik/templates/traefik-compose.yml.j2`
- Adjust Cloudflare Tunnel settings in `roles/cloudflared/templates/config.yml.j2`
- Customize Portainer in `roles/portainer/templates/portainer-compose.yml.j2`

## Compatibility Notes

### bcrypt Python Module
This playbook uses bcrypt for password hashing. Some versions of the bcrypt Python module (including version 4.0.0+) may cause compatibility issues with Ansible's password hashing functionality. If you encounter this error:

```
AttributeError: module 'bcrypt' has no attribute '__about__'
```

The included `scripts/bcrypt_patch.py` script can automatically fix this issue:

```bash
# Fix bcrypt compatibility issues
python3 scripts/bcrypt_patch.py
```

#### Script Features
- **Auto-detection**: Automatically finds your Ansible Python environment
- **Non-invasive**: Only patches what's necessary
- **Safe**: Validates if the patch is needed before applying
- **Flexible**: Command-line options for custom configurations

#### Advanced Options
```bash
# Specify a custom Ansible Python path
python3 scripts/bcrypt_patch.py --path /path/to/ansible/python/site-packages

# Check if patch is needed without applying it
python3 scripts/bcrypt_patch.py --check

# Force patching even if it seems already applied
python3 scripts/bcrypt_patch.py --force

# Show help
python3 scripts/bcrypt_patch.py --help
```

#### Alternative Solutions
If you prefer not to use the patch script:

1. **Install a compatible version of bcrypt**:
   ```bash
   pip install bcrypt==3.2.0
   ```

2. **Use a different hashing method**:
   Modify the playbook to use SHA-512 or other hash types instead of bcrypt where possible.

### Docker Compose Variable Interpolation
If you see warnings about undefined variables in Docker Compose:
```
The "apr1" variable is not set. Defaulting to a blank string.
```

This is normal when using password hashes with $ symbols. Our templates automatically escape these characters.

## Troubleshooting

### Password Management
- For Traefik dashboard authentication, passwords are hashed using SHA-512
- For Portainer, passwords are hashed using bcrypt with proper escaping for Docker Compose
- Password hashing is done locally on the Ansible controller for security

### Common Issues
- If bcrypt hashing fails, ensure you have the correct version installed (see Compatibility Notes)
- For Docker Compose errors, check that your Docker version is compatible (20.10.0+)
- For DNS issues, verify that your Cloudflare API token has the correct permissions

## Notes for macOS Deployments

For macOS hosts, you may need to:
1. Comment out Linux-specific tasks 
2. Uncomment and adapt macOS-specific tasks in the role files
3. Install Docker Desktop for Mac manually or via Homebrew
