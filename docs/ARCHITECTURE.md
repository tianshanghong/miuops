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

All compose stacks follow a three-tier network model with per-stack ingress isolation.

### Network tiers

| Network | Type | Scope | Purpose |
|---|---|---|---|
| `ingress` | normal bridge | Per-stack (e.g. `app1_ingress`) | HTTP ingress. Traefik connects via deploy workflow. Isolates stacks from each other. |
| `internal` | `internal: true` | Per-stack (e.g. `app1_internal`) | Backend isolation. DB, cache, queues. No internet, no cross-stack. |
| `egress` | normal bridge | Per-stack (e.g. `app1_egress`) | Outbound internet. Only for containers that must call external APIs. |

Traefik uses its compose-managed default network (`traefik_default`). No external network is required — cloudflared reaches Traefik via host port binding (`ports: 80:80, 443:443`) and the iptables loopback-to-bridge rule (`-i lo -o br+`), which matches any bridge interface.

Docker Compose scopes non-external networks by project name, so each stack's `ingress`, `internal`, and `egress` are automatically isolated from other stacks.

### Why per-stack ingress?

A shared ingress network allows any container on the network to reach any other container — on any port. Docker's `icc: false` setting only applies to the default bridge (`docker0`), not user-defined networks. If one service is compromised, the attacker can pivot laterally to all other services on the same network.

Per-stack ingress networks eliminate this risk. Each stack gets its own bridge network. Traefik joins each via `docker network connect` (handled automatically by the deploy workflow). A compromised container can only see Traefik on its own isolated network — not other stacks.

### Rules

1. **Web-facing services join a per-stack `ingress` network** — the deploy workflow connects Traefik to each stack's ingress network via `docker network connect`.
2. **Backend services (DB, cache) go on `internal` only** — `internal: true` blocks outbound internet and isolates from other stacks.
3. **Containers needing outbound internet join `egress`** — a normal bridge with NAT. Most services don't need this.
4. **Dual-network for mixed needs** — a container needing both DB access and outbound internet joins both `internal` and `egress`.
5. **Every application service MUST have explicit `networks:`** — no implicit defaults. Traefik is the exception — it uses compose default (`traefik_default`) since its network connections are managed by the deploy workflow.
6. **No `ports:` except Traefik** — all other ingress goes through Traefik labels.
7. **Some images default to binding on `localhost`** — if a container is unreachable from Traefik, set `HOST=0.0.0.0` in its environment. This is safe within a per-stack ingress network because only Traefik can reach the container.

### Topology

```
cloudflared (host) → 127.0.0.1:443
    ↓ (host port binding, iptables: -i lo -o br+ -j RETURN)
Traefik (traefik_default, ports 80/443)
    ├── docker network connect app_ingress
    ├── docker network connect crawler_ingress
    ↓
app (app_ingress + app_internal)         crawler (crawler_ingress + crawler_internal + crawler_egress)
    ↓                                        ↓                  ↓
db (app_internal only)                   db (crawler_internal)  internet (crawler_egress)

Lateral movement blocked:
  app ✕──► crawler  (different ingress networks)
  crawler ✕──► app  (different ingress networks)
```

### Defense in depth (Ansible-managed)

- Per-stack ingress networks: lateral movement between stacks blocked at Docker network level
- Docker daemon: `icc: false`, `userland-proxy: false`
- iptables DOCKER-USER chain: blocks all direct container access from outside
- iptables: only loopback traffic allowed to reach Docker bridges (cloudflared → Traefik)

## Backup Design

Single S3 bucket, single IAM user. Prefixes separate data by type.

```
s3://{project}-backup/
  ├── db/{app-name}/    ← WAL-G (base backups + WAL segments)
  └── vol/              ← offen/docker-volume-backup (volume tarballs)
```

**Why one bucket?** All credentials live on the same server — separate buckets with separate IAM users don't improve security if the server is compromised (the attacker gets all credentials). One lifecycle policy, one Object Lock config, one bucket to manage. Adding a database means picking a new `WALG_S3_PREFIX`, no AWS operations needed.

**Why one IAM user?** Same reasoning. The IAM user gets Put, Get, List permissions only — no Delete. Object Lock (Governance, 30 days) prevents deletion by anyone without the `s3:BypassGovernanceRetention` permission. Backups can optionally be encrypted client-side (GPG or Age) before upload — see [Backup Encryption](BACKUP_ENCRYPTION.md).

For restore procedures, see [Disaster Recovery](DISASTER_RECOVERY.md).

## Known Limitations

- **gRPC not supported** through Cloudflare Tunnel — QUIC transport lacks HTTP trailer support. Workarounds: gRPC-Web via Envoy sidecar, or direct origin with real TLS cert (bypassing the tunnel).
