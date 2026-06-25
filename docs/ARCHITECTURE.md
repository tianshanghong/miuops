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
| Host-side volume backup | Docker volume backup | A host `systemd` timer (Ansible `backup` role) tars each volume and streams it to S3. No container, no `docker.sock` mount — the daemon socket is root-equivalent, so nothing gets it. |
| Single S3 bucket | Backup storage | One bucket, one IAM user, prefixes separate data types. Simplifies lifecycle and Object Lock config. |
| Two repos | Public tool + private config | miuOps is open-source; user infrastructure is private. Different lifecycles, different audiences. |
| Registry auth | Stack repo deploy workflow, not Ansible | Registry credentials are deployment-specific (which registries, which tokens). The bootstrap layer shouldn't know about private image registries. Credentials live in `.env` on the server. |
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
│   ├── traefik/              #   Bootstrap (dirs, network) + upgrades
│   └── backup/               #   Host-side Docker volume backup (systemd timer)
├── playbook.yml
├── scripts/
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
│                    │  │  ├─ volume backup ───┤  (systemd    │
│                    │  │  │                   │   timer,     │
│                    │  │  └─ Docker volumes   │   host-side) │
└────────────────────┘  │                      ▼              │
                        │        S3: {project}-backup         │
                        │        ├─ db/* (WAL-G)              │
                        │        └─ vol/* (volume tarballs)   │
                        └────────────────────────────────────┘
```

## Network Security Model

All compose stacks follow a three-tier network model with per-stack ingress isolation.

### Network tiers

| Network | Type | Scope | Purpose |
|---|---|---|---|
| `ingress` | normal bridge | Per-stack (e.g. `app1_ingress`) | HTTP ingress. The host Traefik reaches it over the bridge. Isolates stacks from each other. |
| `internal` | `internal: true` | Per-stack (e.g. `app1_internal`) | Backend isolation. DB, cache, queues. No internet, no cross-stack. |
| `egress` | normal bridge | Per-stack (e.g. `app1_egress`) | Outbound internet. Only for containers that must call external APIs. |

Traefik runs as a **host binary**, not on any Docker network. cloudflared reaches it on loopback (`https://127.0.0.1:8443`), and it routes to each stack's containers by their per-stack bridge IP — the host is the gateway for every bridge, so no `docker network connect` is needed.

Docker Compose scopes non-external networks by project name, so each stack's `ingress`, `internal`, and `egress` are automatically isolated from other stacks.

### Why per-stack ingress?

A shared ingress network allows any container on the network to reach any other container — on any port. Docker's `icc: false` setting only applies to the default bridge (`docker0`), not user-defined networks. If one service is compromised, the attacker can pivot laterally to all other services on the same network.

Per-stack ingress networks eliminate this risk. Each stack gets its own bridge network, and the host Traefik reaches each stack's containers over that bridge directly (the host is the bridge gateway, so no `docker network connect` is needed). A compromised container is confined to its own per-stack networks — it cannot pivot laterally to other stacks.

### Rules

1. **Web-facing services join a per-stack `ingress` network** — the host Traefik reaches them over that bridge directly (no `docker network connect`).
2. **Backend services (DB, cache) go on `internal` only** — `internal: true` blocks outbound internet and isolates from other stacks.
3. **Containers needing outbound internet join `egress`** — a normal bridge with NAT. Most services don't need this.
4. **Dual-network for mixed needs** — a container needing both DB access and outbound internet joins both `internal` and `egress`.
5. **Every application service MUST have explicit `networks:`** — no implicit defaults. (Traefik is not a stack service; it is a host binary managed by Ansible.)
6. **No `ports:`** — ingress goes through Traefik labels; Traefik is a host process binding loopback, not a published container port.
7. **Some images default to binding on `localhost`** — if a container is unreachable from Traefik, set `HOST=0.0.0.0` in its environment. This is safe within a per-stack ingress network because only Traefik can reach the container.

### Topology

```
cloudflared (host) → https://127.0.0.1:8443 (noTLSVerify)
    ↓
Traefik (host binary, non-root, systemd-sandboxed)
    ├── discovers labels via the read-only docker-socket-proxy (127.0.0.1:2375, POST=0)
    └── routes to each container's per-stack bridge IP (the host is the bridge gateway)
    ↓
app (app_ingress + app_internal)         crawler (crawler_ingress + crawler_internal + crawler_egress)
    ↓                                        ↓                  ↓
db (app_internal only)                   db (crawler_internal)  internet (crawler_egress)

Lateral movement blocked:
  app ✕──► crawler  (separate per-stack bridges; only the host reaches them all)
  crawler ✕──► app  (separate per-stack bridges)
```

### Defense in depth (Ansible-managed)

- Per-stack ingress networks: lateral movement between stacks blocked at Docker network level
- Docker daemon: `icc: false`, `userland-proxy: false`
- ufw default-deny inbound: the only open port is SSH (rate-limited); no container port is ever publicly reachable
- Traefik is a non-root host binary and reaches Docker only via a read-only docker-socket-proxy (POST=0, loopback) — it never holds the raw docker.sock

### App-level authentication

Per-stack networks isolate stacks **from each other**, but containers **within** a stack's
network can reach each other freely (Docker's `icc: false` only governs the default bridge, not
user-defined networks). "Same network" is therefore **not** a trust boundary.

So **authenticate at the application layer**, not by network position: each service that exposes
anything to a sibling container must verify the caller itself — a token, password, or mTLS —
exactly as it would on the public internet. miuops hardens the host and the network edges
(Cloudflare tunnel, loopback-only publish, per-stack isolation, the publish-time policy-check),
but intra-stack lateral movement is the application developer's responsibility.

## Backup Design

Single S3 bucket, single IAM user. Prefixes separate data by type.

```
s3://{project}-backup/
  ├── db/{app-name}/        ← WAL-G (base backups + WAL segments)
  └── vol/{volume}/         ← host-side volume tarballs (backup role)
```

**Volume backups run on the host, not in a container.** The Ansible `backup`
role installs a `systemd` timer that runs a bash script directly on the host.
For each configured volume it stops the volume's writing containers (so the
on-disk data is at rest), tars the volume's `_data` directory, streams it
through optional client-side encryption, and uploads it straight to S3, then
restarts the containers.

**Why host-side, no socket?** A backup container has to be told which volumes to
read and when to stop the writers — historically by mounting the Docker socket
into the container. The socket is root-equivalent: anything holding it can start
a privileged container and own the host. Running the job as a host process using
the host's own `docker` CLI keeps that authority on the host and grants it to no
container. The job needs no inbound network and stages nothing on disk (it
streams `tar → encrypt → S3`).

**Consistency.** Stopping the writer before tarring yields an at-rest snapshot.
Volumes whose writers tolerate a fuzzy copy (append-only logs, rebuildable
caches) can be listed with an empty stop-set for a hot copy. PostgreSQL is best
handled by WAL-G (continuous archiving) rather than a stop-the-world tar of its
data volume.

**Why one bucket?** All credentials live on the same server — separate buckets with separate IAM users don't improve security if the server is compromised (the attacker gets all credentials). One lifecycle policy, one Object Lock config, one bucket to manage. Adding a database means picking a new `WALG_S3_PREFIX`, no AWS operations needed.

**Why one IAM user?** Same reasoning. The IAM user gets Put, Get, List permissions only — no Delete. The backup job itself never deletes; retention is enforced entirely by S3 (Object Lock + lifecycle), so a compromised host cannot erase history. Object Lock (Governance, 30 days) prevents deletion by anyone without the `s3:BypassGovernanceRetention` permission. Volume backups can optionally be encrypted client-side (age) before upload — see [Backup Encryption](BACKUP_ENCRYPTION.md).

For role configuration see [roles/backup/README.md](../roles/backup/README.md); for restore procedures, see [Disaster Recovery](DISASTER_RECOVERY.md).

## Known Limitations

- **gRPC not supported** through Cloudflare Tunnel — QUIC transport lacks HTTP trailer support. Workarounds: gRPC-Web via Envoy sidecar, or direct origin with real TLS cert (bypassing the tunnel).
