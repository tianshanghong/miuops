# miuOps

Ansible-based bootstrap for secure Docker infrastructure on bare metal servers.

miuOps provisions a server with Docker, Traefik, Cloudflare Tunnel, and a ufw firewall — then gets out of the way. Day-to-day service deployment is handled by your own private GitOps **fleet repo** via GitHub Actions.

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
              Traefik (host binary)
                      |
   +-------------------------------------+
   |  Per-stack bridge networks          |
   +-------------------------------------+
                      |
                Docker Services
```

- Traffic flows through Cloudflare's network for DDoS protection and WAF
- No ports are exposed to the internet (all ingress via Cloudflare Tunnel)
- Traefik reverse proxy handles TLS termination and service routing
- The host firewall (ufw) denies all inbound except rate-limited SSH; containers run on isolated per-stack networks

## Quick Start

```bash
# 1. Create your private fleet repo from miuops-fleet-template ("Use this template"),
#    then clone it and cd in — this is where your fleet's config + stacks live.
# 2. Install the CLI: clone this repo and put `miuops` on your PATH.
# 3. From your fleet repo, bootstrap a server (the CLI reads config from ./fleet):
CF_API_TOKEN=your_token miuops up root@203.0.113.10 example.com example.org
```

Pass one or more domains — the CLI creates the Cloudflare Tunnel + DNS routes, writes the server's config into `fleet/`, and converges the host. Commit and push `fleet/`, and GitHub Actions deploys your stacks over SSH.

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
CF_API_TOKEN=your_token miuops up --dry-run root@203.0.113.10 example.com example.org

# SSH user defaults to root if omitted
CF_API_TOKEN=your_token miuops up 203.0.113.10 example.com
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

Your fleet repo describes the whole fleet: each server is one line in
`fleet/inventory.ini` plus one `fleet/host_vars/<name>.yml` (its `domains` +
`tunnel_id`). Config shared by the whole fleet (e.g. the Grafana Cloud endpoints)
goes in `fleet/group_vars/all.yml` instead of being repeated per server — see
[`group_vars/all.yml.example`](group_vars/all.yml.example). The CLI reads `fleet/`
from the current directory, so run it from your fleet repo — servers coexist and you
converge any subset:

```bash
miuops apply server-a          # one server
miuops apply                   # the whole fleet
```

Day-to-day domain/converge commands are in [Daily Operations](docs/DAILY_OPS.md).

## What Gets Deployed

| Component | Role | Purpose |
|---|---|---|
| ufw firewall | `firewall` | Default-deny inbound; only rate-limited SSH is open. No public container exposure. |
| Docker engine | `docker` | Docker CE + Compose plugin; hardened daemon (loopback-published ports, `userns-remap`, ICC off, API never on TCP). |
| Traefik | `traefik` | Non-root host binary; discovers services through a read-only docker-socket-proxy and routes to per-stack networks. |
| Cloudflare Tunnel | `cloudflared` | Zero exposed ports; wildcard + root DNS records; systemd service. |
| SSH hardening | `ssh` | Key-only login (`PasswordAuthentication no`). |
| Metadata block | `metadata-block` | Blocks containers from reaching the cloud metadata endpoint (`169.254.0.0/16`). |
| Observability | `observability` | Grafana Alloy host binary shipping metrics + logs to Grafana Cloud (on by default; activates once the Grafana Cloud connection is configured). |
| Volume backup | `backup` | Host `systemd` timer that tars Docker volumes to S3 — no container, no `docker.sock`. |
| Security upgrades | `unattended-upgrades` | Automatic unattended security patches, no auto-reboot. |

## Deploy Services

After bootstrap, create one private **fleet repo** from the **[miuops-fleet-template](https://github.com/tianshanghong/miuops-fleet-template)** ("Use this template"). The fleet repo describes your whole fleet — `fleet/inventory.ini`, `fleet/host_vars/<server>.yml`, SOPS-encrypted secrets under `fleet/secrets/`, and your per-server Compose stacks under `fleet/stacks/<server>/<stack>/`. It consumes miuOps as a dependency: a ~5-line caller workflow that calls the miuOps reusable `deploy.yml` (pinned to a tag, `secrets: inherit`) — there is no tool code to fork. On push to `main`, GitHub Actions discovers the changed servers and deploys each over SSH.

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

- `miuops up` automatically creates and configures a Cloudflare Tunnel
- DNS CNAME records are created by the CLI via Cloudflare API
- Re-running `miuops up` with additional domains adds them (additive — never drops)
- `miuops add-domain <host> <domain…>` / `remove-domain <host> <domain…>` manage domains on a live server (remove-domain also deletes the orphaned CNAMEs)
- A domain belongs to exactly one server; assigning it to a second is refused
- To delete a tunnel, see [Deleting a tunnel](docs/DAILY_OPS.md#deleting-a-tunnel)

## Backup Setup

- `scripts/setup-s3-backup.sh --server <server>` — Create the shared S3 bucket (Object Lock + lifecycle) and a per-server, prefix-scoped IAM user for backups
- `images/postgres-walg/` — Custom PostgreSQL 17 + WAL-G image for continuous WAL archiving to S3

One shared `{project}-backup` bucket holds every server's backups under a per-server prefix (`<server>/…`); each server gets its own IAM user scoped to only its prefix (no Delete, no cross-prefix access), so a compromised server's key can touch only its own backups. Within a server's prefix the host-side `backup` role stores volume tarballs under `<server>/vol/` and WAL-G stores database backups under `<server>/db/`. The volume backup is a host `systemd` timer — no container, no `docker.sock` mount; see [roles/backup/README.md](roles/backup/README.md). Object Lock (Governance, 30 days) prevents deletion; S3 lifecycle transitions to Glacier at 30 days and expires at 90 days.

## Security

- Zero exposed ports — all traffic flows through Cloudflare Tunnel
- ufw firewall: default-deny inbound, only rate-limited SSH open (`ufw limit`); optional management-CIDR allowlist
- **SSH is key-only** (`PasswordAuthentication no`) — make sure your public key is in the server's `~/.ssh/authorized_keys` before converging, or you will be locked out
- Docker daemon hardened — ports publish to loopback by default, the API is never exposed over TCP, ICC and the userland proxy are disabled, and `userns-remap` maps container root to an unprivileged host UID
- Containers are blocked from the cloud metadata endpoint (`169.254.0.0/16`)
- Automatic unattended security upgrades (no auto-reboot)
- Sensitive files excluded from version control (`.gitignore`)

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — Design decisions, network model, and system diagram
- [Installation Guide](docs/INSTALLATION.md) — Full end-to-end setup walkthrough
- [Secret Model](docs/SECRETS.md) — Where each secret lives: config in versioned vars, deployed secrets SOPS-encrypted in the fleet, the Cloudflare token operator-local
- [Scaling & Advanced](docs/SCALING.md) — Optional patterns (env grouping, SOPS, YubiKey)
- [Repository Structure](docs/STRUCTURE.md) — Directory layout and role descriptions
- [Disaster Recovery](docs/DISASTER_RECOVERY.md) — Backup restore procedures for all failure scenarios
- [Daily Operations](docs/DAILY_OPS.md) — Quick reference for day-to-day server management

## Contributing

Contributions are welcome — please sign off your commits (`git commit -s`) per the
Developer Certificate of Origin. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache License 2.0](LICENSE) — see also [NOTICE](NOTICE).

