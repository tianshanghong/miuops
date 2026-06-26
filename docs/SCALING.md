# Scaling & advanced patterns

Your private fleet repo (created from miuops-fleet-template) describes the whole
fleet: `fleet/inventory.ini` plus one `fleet/host_vars/<server>.yml` per server (its
`domains` + `tunnel_id`), with SOPS-encrypted tunnel creds + `<server>.env` under
`fleet/secrets/`. See [STRUCTURE.md](STRUCTURE.md) for the layout and
[DAILY_OPS.md](DAILY_OPS.md) for the day-to-day commands (`apply`, `add-domain`,
`remove-domain`). This page covers **optional advanced patterns** — none of which the
tool requires.

## Per-server firewall posture

Each server's exposure is data in its `host_vars`. Defaults are generic-safe (SSH
rate-limited via `ufw limit`). To harden a specific server:

```yaml
# fleet/host_vars/prod-a.yml
firewall_management_networks_v4: ["203.0.113.0/24"]   # allow SSH from these CIDRs
firewall_ssh_ratelimit_enabled: false                 # then the rate-limiter is optional
```

Keep the rate-limiter on if you connect from a dynamic IP — it is the only SSH
protection without a fixed source address.

## Cloudflare API token

One **scoped "Edit zone DNS" token per Cloudflare account** manages every domain —
no per-domain tokens. It is **bootstrap-only**: `up`/`add-domain`/`remove-domain`
use it for DNS; day-2 `apply` does not need it (tunnels run from the on-server
`<tunnel_id>.json`). The token is an env var and never enters `host_vars`, the
inventory, or anything committed. Prefer a scoped token over the Global API Key.

## Co-hosting multiple projects on one server (shared dev)

One server can host several projects at once (e.g. a shared dev box). Each project
deploys its own compose stack on its own per-stack networks; Traefik routes by
`Host()`. Add each project's domain with `miuops add-domain <host> dev.projectX.example`.

**Prefix every project's environment variables with the project handle.** All
stacks on a server share one `/opt/stacks/.env`, so unprefixed names collide —
project A's `DB_PASSWORD` would silently overwrite project B's. Namespace them:

```dotenv
# /opt/stacks/.env — one shared file, namespaced per project
APP1_DB_PASSWORD=...
APP1_API_KEY=...
APP2_DB_PASSWORD=...
APP2_API_KEY=...
```

Reference the prefixed name in each stack's compose (`${APP1_DB_PASSWORD}`). This
stops projects from clobbering each other's values and makes it obvious which secret
belongs to which project. For stronger isolation, give each stack its own file via
compose `env_file:` instead of the shared `.env`.

## Optional advanced patterns

All optional — the tool never requires them.

- **Environment grouping.** If several servers should share a posture, group them
  in `fleet/inventory.ini` and put shared vars in `fleet/group_vars/<group>.yml`
  (standard Ansible), then `miuops apply <group>`.
- **YubiKey-backed age key for sensitive servers.** The fleet repo already encrypts
  tunnel creds + `<server>.env` with [SOPS](https://github.com/getsops/sops),
  decrypted only on your machine. Backing the age key with a **YubiKey** means an
  agent on your box cannot decrypt those secrets at all (no hardware) — it can neither
  read nor deploy those hosts. (At deploy time the value is decrypted locally to be
  used; SOPS protects it at rest.)
