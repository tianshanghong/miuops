# Fleet end-to-end acceptance

`fleet-acceptance.sh` is the final gate for the fleet deployment model: it runs the spec's
acceptance checks against a **fresh VPS** that has been bootstrapped from a fleet repo
created from `miuops-fleet-template`. Every check carries a **positive control**, so a
check that can't fail (a missing probe, a swallowed error) is caught rather than passing as
a false green.

The harness *verifies* an already-bootstrapped fleet — it does not provision one. Do the
one-time setup below, then run it. Use a **throwaway** VPS and start from a verified-fresh
state; a contaminated host lies.

It checks the **fully-merged** model: every miuOps unit released and the `v0.1.0` tag cut,
the fleet bootstrapped with the current tooling — in particular the per-server, prefix-scoped
backup IAM from `setup-s3-backup.sh --server` (check 7 asserts cross-prefix denial, which
only holds with that scoped key).

## Prerequisites

- A fresh VPS (root SSH for the initial bootstrap; a non-root deploy user afterwards).
- A Cloudflare account: a domain and an API token able to manage that zone + tunnels.
- AWS credentials able to create the backup bucket + per-server IAM users.
- A GitHub account to host a private fleet repo (throwaway is fine).
- Locally: `miuops` on `PATH`, plus `sops`, `age`, `aws`, `curl`, `nc`, `ssh`.

## One-time setup

1. **Create the fleet repo** from `miuops-fleet-template` ("Use this template" → a new
   **private** repo) and clone it. Work from its root (`FLEET_DIR`).
2. **Generate keys (operator-held).**
   - SSH deploy keypair: `ssh-keygen -t ed25519 -f ./deploy_key -N ''`. The **public** half
     goes to the host; the **private** half goes into the server's GitHub Environment.
   - age identity: `age-keygen -o age-key.txt` and put its `age1…` recipient in
     `.sops.yaml`. (First pass: a software age key. Once green, re-run with an
     `age-plugin-yubikey` recipient to confirm the hardware path.)
3. **Fill in the fleet.**
   - `fleet/inventory.ini` and `fleet/host_vars/<server>.yml` (domains, `tunnel_id`, and
     `deploy_public_keys` = the deploy key's public half).
   - `cp .env.example fleet/secrets/<server>.env`, fill it, `sops -e -i` it, commit the
     ciphertext.
   - A test stack at `fleet/stacks/<server>/whoami/docker-compose.yml` routed at
     `whoami.<domain>` (the template ships this).
4. **Cloud + GitHub.**
   - Backup: `scripts/setup-s3-backup.sh --server <server>` (one bucket, per-server prefix,
     prefix-scoped IAM user). Keep the per-server key for `SERVER_AWS_*` below.
   - Create a per-server GitHub Environment named after the server handle with
     `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY` (and optionally `SSH_PORT`, `SSH_KNOWN_HOSTS`).
5. **Bootstrap + deploy.** Run `miuops up <server>` (host converge: Docker, firewall,
   cloudflared, SSH key-only, deploy keys, the tunnel cred + `.env` provisioned locally over
   SSH). Push to `main` so GitHub Actions deploys the test stack.

## Run

```bash
export VPS_HOST=203.0.113.10
export SSH_KEY=./deploy_key            # the operator private key (not in the repo)
export SSH_USER=deploy SSH_PORT=22
export DOMAIN=example.com              # TEST_HOST defaults to whoami.$DOMAIN
export SERVER=server-01 OTHER_SERVER=server-02
export FLEET_DIR=/path/to/your/fleet-repo
export BACKUP_BUCKET=myfleet-backup
export SERVER_AWS_ACCESS_KEY_ID=...    # the per-server (prefix-scoped) IAM key
export SERVER_AWS_SECRET_ACCESS_KEY=...
export SOPS_AGE_KEY_FILE=./age-key.txt

tests/e2e/fleet-acceptance.sh
```

Exit 0 = all checks passed. Exit 1 = the summary lists which checks failed.

## What each check proves (and its positive control)

1. **Idempotent converge** — a second `miuops apply` reports `changed=0`. *Control:* the play
   actually ran (`ok>0`), so `changed=0` is meaningful.
2. **External attack surface** — only `:22` is reachable; web/daemon ports are closed; a
   **live** host listener on a high port is blocked by the firewall. *Control:* `:22` is
   reachable and the listener is up on loopback (so "blocked from outside" is a real block).
3. **Stack over HTTPS** — `https://<test-host>` returns 200 with a valid TLS chain via
   cloudflared → traefik. *Control:* the body is the test stack's (the whoami marker).
4. **Egress + metadata** — outbound works; `169.254.169.254` is blocked. *Control:* egress to
   a real host succeeds, so the metadata block isn't just "no network".
5. **Per-server Environment isolation** — the deploy job binds `environment: matrix.server`,
   so a job for one server reads only that server's secrets. *Control:* the binding is
   present and keyed off the matrix server. Full cross-server runtime isolation (A can't read
   B) needs a two-server run.
6. **SOPS round-trip; no age key in CI** — the committed secret is ciphertext and decrypts
   locally with the age key. *Control:* it decrypts **with** the key and **fails without** it
   (fail-closed); no CI workflow introduces an age key.
7. **Backup prefix + scoped IAM** — the per-server key can write/read its own prefix and is
   **denied** another server's prefix and `Delete`. *Control:* its own-prefix write/read
   succeeds.
8. **Teardown** — removing the stack from the fleet and re-applying stops the public endpoint
   from serving it. *Control:* the stack was serving (200) before teardown. (Operator-driven;
   the harness does not destroy resources on its own.)
