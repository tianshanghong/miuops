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

## Quick Start

```bash
git clone https://github.com/tianshanghong/miuops
cd miuops
CF_API_TOKEN=your_token ./miuops up root@203.0.113.10 example.com example.org
```

That's it. Pass one or more domains — the CLI handles Cloudflare Tunnel creation, DNS route registration, config generation, and runs the playbook.

### Prerequisites

You need these installed on your local machine (the CLI checks and tells you how to install any that are missing):

| Tool | macOS | Linux |
|---|---|---|
| `ansible` | `brew install ansible` | `sudo apt install ansible` |
| `cloudflared` | `brew install cloudflare/cloudflare/cloudflared` | [pkg.cloudflare.com](https://pkg.cloudflare.com/) |
| `jq` | `brew install jq` | `sudo apt install jq` |
| `curl`, `ssh` | pre-installed | pre-installed |

You also need:
- A **Cloudflare account** with your domain added
- A **Cloudflare API token** — go to [API Tokens](https://dash.cloudflare.com/profile/api-tokens), click "Create Token", and use the **Edit zone DNS** template
- A **bare metal server** with SSH access (Debian/Ubuntu)

### Options

```bash
# Preview what would happen without making changes
CF_API_TOKEN=your_token ./miuops up --dry-run root@203.0.113.10 example.com example.org

# SSH user defaults to root if omitted
CF_API_TOKEN=your_token ./miuops up 203.0.113.10 example.com
```

## Commands

| Command | What it does |
|---|---|
| `miuops up <user@host> <domain…>` | Day-1: create the tunnel + DNS, write config, converge. Additive — re-running adds domains, never drops them. |
| `miuops apply [host]` | Day-2: re-converge one server (or the whole fleet if omitted). |
| `miuops add-domain <host> <domain…>` | Add domain(s) to a server (creates DNS, merges config). |
| `miuops remove-domain <host> <domain…>` | Remove domain(s) and delete their Cloudflare CNAMEs. |

All commands accept `--dry-run` (preview) and `--no-apply` (change config/DNS but skip the converge).

## Managing multiple servers

Each server is one line in `inventory.ini` plus one `host_vars/<name>.yml` (its
`domains` + `tunnel_id`). Run `miuops up` once per server in a single checkout —
they coexist, and you converge any subset:

```bash
miuops apply server-a          # one server
miuops apply                   # the whole fleet
```

Day-to-day domain/converge commands are in [Daily Operations](docs/DAILY_OPS.md).
See **[Scaling & advanced patterns](docs/SCALING.md)** for migrating from a
single-server setup and optional patterns (env grouping, SOPS, YubiKey, a
management-CIDR SSH allowlist).

## What Gets Deployed

| Component | Role | Purpose |
|---|---|---|
| iptables firewall | `firewall` | INPUT + DOCKER-USER chains, rate-limited SSH, zero public container exposure |
| Docker engine | `docker` | Docker CE + Compose plugin, hardened daemon config |
| Traefik | `traefik` | Reverse proxy directories + Docker network (compose deployed via stack repo) |
| Cloudflare Tunnel | `cloudflared` | Secure ingress, wildcard DNS records, systemd service |

## Deploy Services

After bootstrap, create your private stack repo from the **[miuops-stack-template](https://github.com/tianshanghong/miuops-stack-template)** — it includes Traefik, S3 backups, and a GitHub Actions pipeline that deploys on push to `main`.

## Infrastructure Upgrades

Pull tool updates, then re-converge with `miuops apply [host]` (whole fleet if
omitted). To target a single role, add `--tags` (and `--limit <host>` for one
server):

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

- `./miuops up` automatically creates and configures a Cloudflare Tunnel
- DNS CNAME records are created by the CLI via Cloudflare API
- Re-running `./miuops up` with additional domains adds them (additive — never drops)
- `./miuops add-domain <host> <domain…>` / `remove-domain <host> <domain…>` manage domains on a live server (remove-domain also deletes the orphaned CNAMEs)
- A domain belongs to exactly one server; assigning it to a second is refused
- To delete a tunnel, see [Deleting a tunnel](docs/DAILY_OPS.md#deleting-a-tunnel)

## Backup Setup

- `scripts/setup-s3-backup.sh` — Create an S3 bucket (Object Lock + lifecycle) and IAM user for backups
- `images/postgres-walg/` — Custom PostgreSQL 17 + WAL-G image for continuous WAL archiving to S3

The setup script creates a single `{project}-backup` bucket used by both the host-side `backup` role (volume tarballs under `vol/`) and WAL-G (database backups under `db/`). The volume backup is a host `systemd` timer — no container, no `docker.sock` mount; see [roles/backup/README.md](roles/backup/README.md). Object Lock (Governance, 30 days) prevents deletion; S3 lifecycle transitions to Glacier at 30 days and expires at 90 days.

## Security

- Zero exposed ports — all traffic flows through Cloudflare Tunnel
- iptables firewall with default-DROP on INPUT and DOCKER-USER chains
- Rate-limited SSH by default (6 attempts / 60s, configurable); optional management-CIDR allowlist
- Docker daemon hardened (ICC disabled, userland proxy disabled)
- Sensitive files excluded from version control (`.gitignore`)

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — Design decisions, network model, and system diagram
- [Installation Guide](docs/INSTALLATION.md) — Full end-to-end setup walkthrough
- [Scaling & Advanced](docs/SCALING.md) — Migration to a fleet + optional patterns (env grouping, SOPS, YubiKey)
- [Repository Structure](docs/STRUCTURE.md) — Directory layout and role descriptions
- [Disaster Recovery](docs/DISASTER_RECOVERY.md) — Backup restore procedures for all failure scenarios
- [Daily Operations](docs/DAILY_OPS.md) — Quick reference for day-to-day server management

## Contributing

Contributions are welcome — please sign off your commits (`git commit -s`) per the
Developer Certificate of Origin. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE) — see also [NOTICE](NOTICE).

