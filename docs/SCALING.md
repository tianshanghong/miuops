# Scaling to a fleet — migration & advanced patterns

MiuOps manages multiple servers from one checkout: a flat `inventory.ini` plus one
`host_vars/<host>.yml` per server (its `domains` + `tunnel_id`); globals come from
role defaults. See [STRUCTURE.md](STRUCTURE.md) for the layout and
[DAILY_OPS.md](DAILY_OPS.md) for the day-to-day commands (`apply`, `add-domain`,
`remove-domain`). This page covers the **one-time migration** and **optional
advanced patterns** — none of which the tool requires.

## Migrating an existing single-server setup

1. `mkdir -p host_vars`
2. Create `host_vars/<inventory_hostname>.yml` with the `domains` and `tunnel_id`
   from your old `group_vars/all.yml` (see `host_vars/server1.yml.example`).
3. Delete `group_vars/all.yml`.
4. Ensure `inventory.ini` lists the host (flat, under `[bare_metal]`).
5. `ansible-playbook playbook.yml --limit <host>` — should report `changed=0`.

From separate clones: do the above once per server in a single checkout, import
each server's `files/<tunnel_id>.json`, then retire the old clones.

## Per-server firewall posture

Each server's exposure is data in its `host_vars`. Defaults are generic-safe (SSH
rate-limited via `ufw limit`). To harden a specific server:

```yaml
# host_vars/prod-a.yml
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
  in `inventory.ini` and put shared vars in `group_vars/<group>.yml` (standard
  Ansible), then `miuops apply <group>` / `ansible-playbook --limit <group>`.
- **Separate private config repo.** Keep `inventory.ini`, `host_vars/`, and
  `files/*.json` in a private repo that consumes this public tool: point Ansible at
  it with `ansible-playbook -i /path/to/fleet/inventory.ini playbook.yml`.
- **SOPS-encrypted secrets.** Gitignored plaintext is readable by any agent on your
  machine. Encrypting `host_vars`/`files` with [SOPS](https://github.com/getsops/sops)
  stores ciphertext in git instead. With a **YubiKey-backed age key for sensitive
  servers**, an agent cannot decrypt them at all (no hardware) — so it can neither
  read nor deploy those hosts. (At deploy time the value is decrypted to be used;
  SOPS protects it at rest.)
