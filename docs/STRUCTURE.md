# Repository Structure

```
.
├── ansible.cfg                # Ansible configuration
├── playbook.yml               # Main Ansible playbook
├── requirements.yml           # Ansible Galaxy requirements
├── inventory.ini.template     # Example inventory file
├── group_vars/
│   └── all.yml.template       # Example group variables
├── roles/
│   ├── firewall/              # iptables firewall (INPUT + DOCKER-USER)
│   ├── docker/                # Docker engine installation
│   ├── traefik/               # Traefik reverse proxy setup
│   └── cloudflared/           # Cloudflare Tunnel + DNS records
├── files/                     # Tunnel credentials (gitignored)
├── scripts/
│   ├── check-prereqs.sh       # Prerequisite checker
│   ├── create-tunnel.sh       # Cloudflare Tunnel creation
│   ├── delete-tunnel.sh       # Cloudflare Tunnel deletion
└── docs/                      # Documentation
```

## Roles

- **firewall** — Configures iptables with nft backend. INPUT chain (rate-limited SSH, management networks, whitelisted ports) and DOCKER-USER chain (blocks all direct container access, allows only loopback for cloudflared).
- **docker** — Installs Docker CE + Compose plugin from official repos. Hardens daemon (ICC disabled, userland proxy disabled).
- **traefik** — Sets up Traefik as reverse proxy with automatic TLS via Cloudflare DNS challenge. Creates Docker network, directories, and htpasswd auth.
- **cloudflared** — Installs cloudflared binary, deploys tunnel credentials and config, creates wildcard + root CNAME DNS records, runs as systemd service.
