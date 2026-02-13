# Architecture

Design rationale and internal architecture of miuOps.

## Design Decisions

| Component | Decision | Rationale |
|---|---|---|
| Ansible | Keep for day-0 bootstrap + infra upgrades | Firewall, Docker, cloudflared, and Traefik upgrades are infrastructure — not appropriate for GitOps. |
| GitHub Actions | GitOps for service deployment | Sync compose files via SSH + rsync, `docker compose up -d`. Server never pulls from git. |
| Cloudflare Tunnel | Zero exposed ports | All ingress flows through Cloudflare. No public-facing ports on the server. |
| Traefik | Stateless reverse proxy | Label-based service discovery, no config files to manage per-service. |
| WAL-G | PostgreSQL backup | Physical backup + continuous WAL archiving to S3, baked into a custom PG image. |
| Single S3 bucket | Backup storage | One bucket, one IAM user, prefixes separate data types. Simplifies lifecycle and Object Lock config. |
| Two repos | Public tool + private config | miuOps is open-source; user infrastructure is private. Different lifecycles, different audiences. |
| No backward compat | Clean break | No migration paths, shims, or old-structure support. |

## Two-Repo Architecture

**Why two repos?** miuOps is an open-source tool. A user's infrastructure config is private, user-specific data with a different lifecycle and audience. If combined, users would fork miuOps and could never cleanly pull upstream updates.

**Git auth is a non-issue.** The server never pulls from git. GitHub Actions SSHes into the server and pushes files via rsync/scp. The server has no idea git exists.

### miuOps (public)

The tool. Users clone this to bootstrap their server.

```
miuOps/
├── miuops                    # CLI entrypoint (./miuops up)
├── roles/                    # Ansible roles for bootstrap + upgrades
│   ├── docker/               #   Docker engine
│   ├── firewall/             #   iptables (IPv4 + IPv6)
│   ├── cloudflared/          #   Cloudflare Tunnel + systemd + DNS
│   └── traefik/              #   Bootstrap (dirs, network) + upgrades
├── playbook.yml
├── scripts/
│   ├── delete-tunnel.sh
│   └── setup-s3-backup.sh
├── images/
│   └── postgres-walg/        # Custom PG image with WAL-G
└── docs/
```

### User's stack repo (private)

Created from the [miuops-stack-template](https://github.com/tianshanghong/miuops-stack-template). Contains compose files, GitHub Actions workflow, and `.env.example`.

```
my-infra/
├── stacks/
│   ├── traefik/
│   ├── backup/
│   └── <user-apps>/
├── .github/workflows/
│   └── deploy.yml            # SSH + rsync + docker compose up
├── .env.example
└── .gitignore                # .env never committed
```

## System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  CONTROL PLANE (your laptop)                                │
│  - Editor for compose files                                 │
│  - Git push to GitHub (stack repo)                          │
│  - Ansible (miuOps) for bootstrap + infra upgrades          │
│  - LazyDocker via docker context + SSH                      │
└──────────┬──────────────┬───────────────────┬───────────────┘
           │ git push     │ ansible-playbook  │ SSH tunnel
           ▼              ▼                   ▼
┌────────────────────┐  ┌────────────────────────────────────┐
│  GITHUB            │  │  SERVER (runtime)                  │
│                    │  │                                    │
│  miuOps (public)   │  │  [infra — Ansible-owned]           │
│  - Ansible roles   │  │  ├─ iptables firewall              │
│  - scripts         │  │  ├─ Docker engine                  │
│                    │  │  ├─ cloudflared (systemd)          │
│                    │  │  ├─ /opt/traefik (dirs, acme.json) │
│  my-infra (private)│  │                                    │
│  - compose files   │  │  [apps — GitOps-owned]             │
│  - GH Actions  ───────▶  ├─ Traefik (compose)              │
│  - .env (secrets)  │SSH│  ├─ App containers                 │
│                    │  │  ├─ PG + WAL-G ──────┐              │
│                    │  │  ├─ Backup sidecar ──┤              │
└────────────────────┘  │  └─ Docker volumes   │              │
                        │                      ▼              │
                        │        S3: {project}-backup         │
                        │        ├─ db/* (WAL-G)              │
                        │        └─ vol/* (offen)             │
                        └────────────────────────────────────┘
```

## Network Security Model

All compose stacks follow a three-tier network model.

### Network tiers

| Network | Type | Scope | Purpose |
|---|---|---|---|
| `traefik_network` | external | Shared (created by Ansible) | HTTP ingress: cloudflared → Traefik → container |
| `internal` | `internal: true` | Per-stack (e.g. `app1_internal`) | Backend isolation. DB, cache, queues. No internet, no cross-stack. |
| `egress` | normal bridge | Per-stack (e.g. `app1_egress`) | Outbound internet. Only for containers that must call external APIs. |

Docker Compose scopes non-external networks by project name, so each stack's `internal` and `egress` are automatically isolated from other stacks.

### Rules

1. **`traefik_network` is the only ingress path** — cloudflared → Traefik → container. Only containers with Traefik labels join this network.
2. **Backend services (DB, cache) go on `internal` only** — `internal: true` blocks outbound internet and isolates from other stacks.
3. **Containers needing outbound internet join `egress`** — a normal bridge with NAT. Most services don't need this.
4. **Dual-network for mixed needs** — a container needing both DB access and outbound internet joins both `internal` and `egress`.
5. **Every service MUST have explicit `networks:`** — no implicit defaults.
6. **No `ports:` except Traefik** — all other ingress goes through Traefik labels.

### Topology

```
cloudflared (host) → 127.0.0.1:443
    ↓
Traefik (traefik_network, ports 80/443)
    ↓ label-based routing
app (traefik_network + app_internal)     crawler (crawler_internal + crawler_egress → internet)
    ↓                                        ↓
db (app_internal only)                   db (crawler_internal only)
```

### Defense in depth (Ansible-managed)

- Docker daemon: `icc: false`, `userland-proxy: false`
- iptables DOCKER-USER chain: blocks all direct container access from outside
- iptables: only loopback traffic allowed (cloudflared → Traefik)

## Backup Design

Single S3 bucket, single IAM user. Prefixes separate data by type.

```
s3://{project}-backup/
  ├── db/{app-name}/    ← WAL-G (base backups + WAL segments)
  └── vol/              ← offen/docker-volume-backup (volume tarballs)
```

**Why one bucket?** All credentials live on the same server — separate buckets with separate IAM users don't improve security if the server is compromised (the attacker gets all credentials). One lifecycle policy, one Object Lock config, one bucket to manage. Adding a database means picking a new `WALG_S3_PREFIX`, no AWS operations needed.

**Why one IAM user?** Same reasoning. The IAM user gets Put, Get, List permissions only — no Delete. Object Lock (Compliance, 30 days) prevents deletion by anyone, including the AWS root account.

For restore procedures, see [Disaster Recovery](DISASTER_RECOVERY.md).

## Known Limitations

- **gRPC not supported** through Cloudflare Tunnel — QUIC transport lacks HTTP trailer support. Workarounds: gRPC-Web via Envoy sidecar, or direct origin with real TLS cert (bypassing the tunnel).
