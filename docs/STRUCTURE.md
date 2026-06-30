# Repository Structure

This is the **miuOps tool** repo — the Ansible roles, the `miuops` CLI, and the reusable
GitHub workflows. Your fleet's configuration (inventory, per-server vars, encrypted secrets,
and stacks) lives in your **separate fleet repo**, created from `miuops-fleet-template`.

```
.
├── ansible.cfg                # Ansible configuration
├── playbook.yml               # Main Ansible playbook
├── requirements.yml           # Ansible Galaxy requirements
├── roles/
│   ├── firewall/              # ufw host firewall (default-deny inbound)
│   ├── docker/                # Docker engine + hardened daemon
│   ├── ssh/                   # Key-only SSH + operator-supplied deploy keys
│   ├── traefik/               # Non-root host binary + read-only socket-proxy
│   ├── cloudflared/           # Cloudflare Tunnel + DNS records
│   ├── metadata-block/        # Block containers from the cloud metadata endpoint
│   ├── observability/         # Grafana Alloy host binary (opt-in)
│   ├── backup/                # Host-side Docker volume backup (systemd timer)
│   └── unattended-upgrades/   # Automatic security upgrades
├── .github/workflows/         # Reusable deploy.yml + the stack policy-check
├── miuops                     # CLI entry point (miuops up)
├── scripts/
│   └── setup-s3-backup.sh     # Shared S3 bucket + per-server prefix-scoped IAM
├── tests/                     # CLI/unit tests + the e2e acceptance harness
└── docs/                      # Documentation
```

## Roles

- **firewall** — Configures ufw as the host inbound firewall: default-deny incoming, allow outgoing, only rate-limited SSH (`ufw limit`) open. Optional management-network CIDRs and whitelisted ports. IPv4 + IPv6.
- **docker** — Installs Docker CE + Compose plugin via signed apt repo. Hardens the daemon: ports publish to loopback, the API is never on TCP, ICC and the userland proxy are disabled, and `userns-remap` maps container root to an unprivileged host UID.
- **ssh** — Enforces key-only login (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`), with a guard that refuses to converge if no authorized key is present (avoids lockout).
- **traefik** — Installs Traefik as a non-root host binary (systemd). It reads Docker only through a read-only docker-socket-proxy on loopback and routes to each stack's bridge network; cloudflared connects to it on loopback.
- **cloudflared** — Installs cloudflared via apt repo, deploys tunnel credentials and config, creates wildcard + root CNAME DNS records, runs as systemd service.
- **metadata-block** — Blocks containers from reaching the cloud metadata endpoint (`169.254.0.0/16`) via a `DOCKER-USER` egress rule, re-applied on Docker restart.
- **observability** *(opt-in, off by default)* — Runs Grafana Alloy as a host systemd service that ships host + container + cloudflared metrics and Docker container logs to Grafana Cloud. Enabled per host via `observability_enabled`; egress-only (no inbound port). See [OBSERVABILITY.md](OBSERVABILITY.md).
- **backup** — A host `systemd` timer that stops a volume's writers, tars the volume, optionally encrypts, and streams it to S3 — no container, no `docker.sock`. See [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md).
- **unattended-upgrades** — Installs and enables automatic unattended security upgrades with no automatic reboot.
