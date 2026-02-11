# miuOps

Ansible-based bootstrap for secure Docker infrastructure on bare metal servers.

miuOps provisions a server with Docker, Traefik, Cloudflare Tunnel, and an iptables firewall — then gets out of the way. Day-to-day service deployment is handled by your own private GitOps stack repo via GitHub Actions.

## Architecture Overview

```
                Internet Users
                      |
                      v
              [DNS: *.example.com]
                      |
                Cloudflare CDN/WAF
                      |
           +----------+----------+
           |  Cloudflare Tunnel  |
           +----------+----------+
                      |
                  cloudflared
                      |
                   Traefik
                      |
   +-------------------------------------+
   |  DOCKER-USER iptables chain         |
   +-------------------------------------+
                      |
                Docker Services
```

- Traffic flows through Cloudflare's network for DDoS protection and WAF
- No ports are exposed to the internet (all ingress via Cloudflare Tunnel)
- Traefik reverse proxy handles TLS termination and service routing
- System and Docker networking are secured with iptables rules

## Prerequisites

1. A Cloudflare account with your domain
2. Cloudflare API token with Zone:DNS:Edit permissions
3. Cloudflare Tunnel created and credentials downloaded
4. Bare metal server with SSH access (Debian/Ubuntu)
5. Ansible >= 2.10 on your control machine

```bash
./scripts/check-prereqs.sh
```

## Quick Start

```bash
# Clone repository
git clone https://github.com/tianshanghong/miuops
cd miuops

# Install Ansible requirements
ansible-galaxy collection install -r requirements.yml

# Configure
cp inventory.ini.template inventory.ini
cp group_vars/all.yml.template group_vars/all.yml
nano inventory.ini
nano group_vars/all.yml

# Create Cloudflare Tunnel (or copy existing credentials)
./scripts/create-tunnel.sh

# Bootstrap server
ansible-playbook playbook.yml
```

## What Gets Deployed

| Component | Role | Purpose |
|---|---|---|
| iptables firewall | `firewall` | INPUT + DOCKER-USER chains, rate-limited SSH, zero public container exposure |
| Docker engine | `docker` | Docker CE + Compose plugin, hardened daemon config |
| Traefik | `traefik` | Reverse proxy directories + Docker network (compose deployed via stack repo) |
| Cloudflare Tunnel | `cloudflared` | Secure ingress, wildcard DNS records, systemd service |

## Domain Configuration

In `group_vars/all.yml`:

```yaml
domains:
  - domain: "example.com"
    zone_id: "your_zone_id_here"
```

## Deploy Services

After bootstrap, create your private stack repo from the **[miuops-stack-template](https://github.com/tianshanghong/miuops-stack-template)** — it includes Traefik, S3 backups, and a GitHub Actions pipeline that deploys on push to `main`.

## Infrastructure Upgrades

```bash
# Update firewall rules
ansible-playbook playbook.yml --tags firewall

# Upgrade Traefik
ansible-playbook playbook.yml --tags traefik

# Upgrade cloudflared
ansible-playbook playbook.yml --tags cloudflared

# Upgrade Docker engine
ansible-playbook playbook.yml --tags docker
```

## Tunnel Management

- `scripts/create-tunnel.sh` — Create a Cloudflare Tunnel and prepare credentials
- `scripts/delete-tunnel.sh` — Delete a tunnel and clean up credentials
- DNS records are managed by Ansible during bootstrap

## Backup Setup

- `scripts/setup-s3-backup.sh` — Create an S3 bucket (Object Lock + lifecycle) and IAM user for backups
- `images/postgres-walg/` — Custom PostgreSQL 17 + WAL-G image for continuous WAL archiving to S3

The setup script creates a single `{project}-backup` bucket used by both offen (volume tarballs under `vol/`) and WAL-G (database backups under `db/`). Object Lock (Compliance, 30 days) prevents deletion; S3 lifecycle transitions to Glacier at 30 days and expires at 90 days.

## Security

- Zero exposed ports — all traffic flows through Cloudflare Tunnel
- iptables firewall with default-DROP on INPUT and DOCKER-USER chains
- Rate-limited SSH (6 attempts per 60 seconds)
- Docker daemon hardened (ICC disabled, userland proxy disabled)
- Sensitive files excluded from version control (`.gitignore`)

## Documentation

- [Installation Guide](docs/INSTALLATION.md) — Full end-to-end setup walkthrough
- [Repository Structure](docs/STRUCTURE.md) — Directory layout and role descriptions
- [Disaster Recovery](docs/DISASTER_RECOVERY.md) — Backup restore procedures for all failure scenarios
- [Daily Operations](docs/DAILY_OPS.md) — Quick reference for day-to-day server management

