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
├── images/
│   └── postgres-walg/         # PostgreSQL 17 + WAL-G Docker image
├── miuops                     # CLI entry point (./miuops up)
├── scripts/
│   └── setup-s3-backup.sh     # S3 backup bucket + IAM user creation
└── docs/                      # Documentation
```

## Roles

- **firewall** — Configures iptables with nft backend. INPUT chain (rate-limited SSH, management networks, whitelisted ports) and DOCKER-USER chain (blocks all direct container access, allows only loopback for cloudflared).
- **docker** — Installs Docker CE + Compose plugin via signed apt repo. Hardens daemon (ICC disabled, userland proxy disabled).
- **traefik** — Bootstraps Traefik directories and Docker network. Pulls latest image when stack is deployed.
- **cloudflared** — Installs cloudflared via apt repo, deploys tunnel credentials and config, creates wildcard + root CNAME DNS records, runs as systemd service.

## Images

- **postgres-walg** — Custom PostgreSQL 17 image with WAL-G baked in. Provides continuous WAL archiving to S3 and a `walg-backup.sh` helper for daily base backups.
