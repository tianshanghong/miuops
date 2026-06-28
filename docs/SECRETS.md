# Secret model — where each secret lives

miuops routes every converge datum to a home matched to its nature, so an `apply`
needs only your age identity unlocked — no secrets typed on the command line. Three
classes:

## 1. Config (NOT secret) → versioned vars

Non-secret settings that vary per fleet or host: the Grafana Cloud push **endpoints +
user IDs**, the backup **S3 bucket + region**. These are versioned in your fleet repo —
fleet-wide in `fleet/group_vars/all.yml`, per-host in `fleet/host_vars/<host>.yml` — and
are safe to commit. See [OBSERVABILITY.md](OBSERVABILITY.md) and
[../roles/backup/README.md](../roles/backup/README.md).

## 2. Deployed secrets → SOPS-encrypted in the fleet

Secrets the **server** needs at converge. They are SOPS-encrypted under `fleet/secrets/`
(safe to commit as ciphertext) and decrypted **at converge, on your machine, with your
age key** — never typed as per-apply env, never plaintext in git. The mechanics (age
key, `.sops.yaml`, round-trip + tamper checks) are in [SOPS_SECRETS.md](SOPS_SECRETS.md).

| Secret | File | Supplies |
|---|---|---|
| Grafana Cloud token | `fleet/secrets/all.vars.json` (fleet-wide) | `grafana_cloud_token` |
| AWS backup creds | `fleet/secrets/<host>.vars.json` (per-host) | `backup_aws_access_key_id`, `backup_aws_secret_access_key` |
| Tunnel credential | `fleet/secrets/<tunnel_id>.json` | the `cloudflared` role |
| App env | `fleet/secrets/<server>.env` | `/opt/stacks/.env` |

Create the **deployed-vars** secrets (the `*.vars.json`) — JSON objects of Ansible vars,
encrypted to your age recipient:

```bash
# fleet-wide Grafana Cloud token
printf '{ "grafana_cloud_token": "glc_..." }\n' > fleet/secrets/all.vars.json
sops --encrypt --in-place fleet/secrets/all.vars.json

# per-server AWS backup credentials (one file per server)
printf '{ "backup_aws_access_key_id": "AKIA...", "backup_aws_secret_access_key": "..." }\n' \
    > fleet/secrets/web1.vars.json
sops --encrypt --in-place fleet/secrets/web1.vars.json
```

> The `printf` writes the token in **plaintext** to disk (and into your shell history)
> until `sops --encrypt` rewrites it in place. Confirm it encrypted before you commit —
> `git grep -L sops -- 'fleet/secrets/*'` must print nothing — and never `git add` the
> plaintext. To keep plaintext off disk and history entirely, edit the encrypted file
> directly: `sops fleet/secrets/all.vars.json` opens a decrypted buffer that re-encrypts
> on save. See [SOPS_SECRETS.md](SOPS_SECRETS.md#never-commit-plaintext).

At converge miuops decrypts these to private `0600` temp files and passes each to Ansible
as `-e @<file>` extra-vars, which **outrank** the roles' defaults — so the token + creds
render into the on-host config (`/etc/alloy/config.alloy`, `/etc/miuops-backup/backup.env`)
with **no** `export GRAFANA_CLOUD_TOKEN` / `AWS_*`.

> **Per-host secrets need a targeted apply.** `miuops apply <host>` loads `all.vars.json`
> **and** that host's `<host>.vars.json`. A whole-fleet `miuops apply` (no host) loads only
> the fleet-wide `all.vars.json`. So converge a backup-enabled host with
> `miuops apply <host>` to supply its AWS creds. Whenever a host's `<host>.vars.json` is
> not loaded — no host targeted, *or* the file doesn't exist yet — the backup role falls
> back to `AWS_*` from your shell. Once your creds are SOPS'd,
> `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY` so a stale value can never silently win.

## 3. The operator token (Cloudflare) → operator-local, NOT in the fleet

`CF_API_TOKEN` is the one secret that does **not** go in the fleet. `miuops up` /
`add-domain` / `remove-domain` use it to create the tunnel and DNS via the Cloudflare API.
It is **high blast radius** (it can edit your DNS), so it stays operator-local — never
committed, never on a server, and not needed by `apply` at all.

Keep it in an operator secret store and inject it only for the one command:

```bash
# 1Password CLI
CF_API_TOKEN=$(op read "op://Private/Cloudflare-miuops/token") miuops up root@<ip> example.com
# pass
CF_API_TOKEN=$(pass cloudflare/miuops) miuops up root@<ip> example.com
# macOS keychain
CF_API_TOKEN=$(security find-generic-password -s cloudflare-miuops -w) miuops up root@<ip> example.com
```

**Scope the token to the minimum.** Create it at
[Cloudflare → API Tokens](https://dash.cloudflare.com/profile/api-tokens) with the
prebuilt **"Edit zone DNS"** template — it grants `Zone:DNS:Edit` plus the `Zone:Read`
the zone lookup needs — **restricted to the specific zone(s) you serve**, not *all* zones.

The token is **DNS-only**: it needs no tunnel or account permission. `miuops up` creates
the tunnel through the `cloudflared` binary, which authenticates with the
`cloudflared login` browser cert (`~/.cloudflared/cert.pem`) — never with `CF_API_TOKEN`.
So do **not** add `Account → Cloudflare Tunnel` to this token; keep it scoped to DNS on
your zones.

Set a TTL and, if you can, an IP allowlist. A scoped, expiring token limits the damage if
it leaks — and because it never enters the fleet or a server, a compromised server can't
reach it.

## The end state at `apply`

Config is versioned; deployed secrets are SOPS-in-fleet. So a converge needs only your
**age identity** unlocked — a YubiKey touch, or the key file SOPS resolves (see
[SOPS_SECRETS.md](SOPS_SECRETS.md#where-the-key-is-resolved)). No `GRAFANA_CLOUD_TOKEN` /
`AWS_*` typed per apply. The sole operator-local secret is `CF_API_TOKEN`, and only for
`up` / `add-domain` / `remove-domain`.
