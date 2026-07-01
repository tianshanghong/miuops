# Secrets with SOPS + age

miuops encrypts the secrets your fleet needs — the Cloudflare Tunnel credential,
each server's application `.env`, and the deployed vars (the Grafana Cloud token and a
server's AWS backup creds) — with [SOPS](https://github.com/getsops/sops)
and [age](https://github.com/FiloSottile/age). The ciphertext is safe to commit
to your fleet repo under `fleet/secrets/`; the matching age **private key** lives
only on your machine (or a YubiKey) and **never** enters CI.

## Why

- **Plaintext credentials never hit git.** The tunnel credential JSON and the app
  `.env` are committed encrypted. A repo leak yields ciphertext, not secrets.
- **All decryption is local.** miuops decrypts on your machine (the control node)
  to a private temp file, hands the plaintext to Ansible over SSH, and shreds the
  temp file. The server receives the plaintext over the SSH connection exactly as
  before — only the *source* moved from a committed plaintext file to a locally
  decrypted one.
- **CI has no key.** The deploy/CI environment holds no age identity, so it
  *cannot* decrypt `fleet/secrets/`. Tamper protection is built in: any change to
  a ciphertext byte makes `sops -d` fail closed (MAC mismatch), so a corrupted or
  altered secret is rejected rather than silently used.

## Install the tools

```bash
# macOS
brew install sops age

# Linux: install the sops binary from the releases page, plus age:
#   https://github.com/getsops/sops/releases
sudo apt install age      # or build age from source
```

The miuops CLI requires `sops` (it runs a prereq check) and uses an age identity
for decryption.

## Generate an age key

A software key — keep the private half off every server:

```bash
# Default location SOPS looks in (Linux):
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# macOS default:
#   ~/Library/Application Support/sops/age/keys.txt
```

`age-keygen` prints the **public** recipient (`age1...`); the file holds the
private key. Store a copy somewhere safe (password manager / offline media) — if
you lose the only identity that can decrypt a secret, that secret is
unrecoverable.

Derive the recipient again at any time:

```bash
age-keygen -y ~/.config/sops/age/keys.txt   # -> age1...
```

### YubiKey (hardware-backed identity)

A YubiKey works with **no CLI change** — the identity is owned entirely by the
SOPS env, and a software key file and a YubiKey identity are interchangeable.

```bash
age-plugin-yubikey            # interactive: create an identity on the key
age-plugin-yubikey --list     # prints the recipient: age1yubikey1...
```

Put the recipient in `.sops.yaml` (below). Decryption later requires the YubiKey
plugged in (touch/PIN) and `age-plugin-yubikey` on `PATH`. The miuops preflight
*warns* (does not fail) when no software identity is found, because a YubiKey
resolves only at touch time.

## Where the key is resolved

miuops sets **nothing** — it inherits your environment, and SOPS resolves the age
identity in this order:

1. `SOPS_AGE_KEY` — a literal `AGE-SECRET-KEY-1...` in the environment
2. `SOPS_AGE_KEY_FILE` — a path to an identity file (overrides the default)
3. the default file: `~/.config/sops/age/keys.txt` (Linux) /
   `~/Library/Application Support/sops/age/keys.txt` (macOS)

So a `keys.txt` holding either a software key or an `AGE-PLUGIN-YUBIKEY-...` line
both work the same way.

## `.sops.yaml` (lives at the fleet repo root)

The fleet template ships `.sops.yaml` at the **root** of the fleet repo (the
parent of `fleet/`). It names the recipient(s) your secrets are encrypted to and
matches everything under `fleet/secrets/`:

```yaml
creation_rules:
  # Tunnel credential JSON and app .env under fleet/secrets/.
  - path_regex: ^fleet/secrets/.*\.(json|env)$
    age: age1youroperatorrecipientxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Add more recipients (comma-separated, or one per `age:` list entry) for a
backup/teammate/break-glass key — any **one** matching identity can then decrypt.
A YubiKey recipient is just `age1yubikey1...` in the same spot.

miuops always invokes `sops` with the working directory set to this repo root and
passes repo-relative paths (`fleet/secrets/<file>`), so the `path_regex` above
matches.

## What miuops encrypts, and when

- **`miuops up`** creates the tunnel, then encrypts its credential **in place**
  into `fleet/secrets/<tunnel_id>.json`:

  ```bash
  sops --encrypt --input-type json --output-type json --in-place \
      fleet/secrets/<tunnel_id>.json
  ```

  Commit the resulting ciphertext.

- **At converge** (`up` / `apply`), miuops decrypts `fleet/secrets/<tunnel_id>.json`
  to a private `0600` temp file and passes its path to Ansible via
  `cloudflared_credentials_src`; the `cloudflared` role copies it to the server at
  `0600` (`no_log`). When that variable is empty the role falls back to the legacy
  plaintext `files/<tunnel_id>.json` for backward compatibility.

- **The app `.env`** — if `fleet/secrets/<server>.env` exists, a targeted
  `apply <server>` decrypts it on the control node (where a TTY exists, so an age
  YubiKey can prompt for its PIN + touch) to a private `0600` temp and provisions it
  to the host's `/opt/stacks/.env` at mode `0600` (root, `no_log`). Like
  `<host>.vars.json`, it is provisioned only for a targeted host — a whole-fleet
  `apply` (no server) cannot (each YubiKey decrypt needs an interactive PIN + touch),
  so it skips `.env` and prints a warning telling you to target the host. Encrypt one
  yourself with:

  ```bash
  cp my.env fleet/secrets/<server>.env
  sops --encrypt --input-type dotenv --output-type dotenv --in-place \
      fleet/secrets/<server>.env
  ```

  SOPS encrypts only the **values** in a `.env`, so a `git diff` still shows which
  keys changed without leaking their values.

- **Deployed vars** (`fleet/secrets/all.vars.json`, `fleet/secrets/<host>.vars.json`) —
  JSON objects of Ansible vars: the Grafana Cloud token (fleet-wide) and a server's AWS
  backup credentials (per-host). At converge miuops decrypts each present file to a
  `0600` temp and passes it to Ansible as `-e @<temp>` extra-vars, which **outrank** the
  role defaults — so the secret renders into the on-host config with no per-apply env.
  `<host>.vars.json` loads only for a targeted `apply <host>`. Encrypt one with:

  ```bash
  printf '{ "grafana_cloud_token": "glc_..." }\n' > fleet/secrets/all.vars.json
  sops --encrypt --in-place fleet/secrets/all.vars.json
  ```

  As with every example here, the file is plaintext until `sops` rewrites it — confirm it
  encrypted before committing (see [Never commit plaintext](#never-commit-plaintext)). See
  [SECRETS.md](SECRETS.md) for the full secret model (config vs deployed secret vs the
  operator-local Cloudflare token).

## Verify it works — round-trip and tamper

Run from the fleet repo root (so `.sops.yaml` applies). These are the same checks
the project's tests automate.

**Round-trip** (a secret encrypts, hides its value, and decrypts back):

```bash
# JSON tunnel credential
sops --decrypt fleet/secrets/<tunnel_id>.json | jq -e '.TunnelID and .TunnelSecret'

# app .env (value is encrypted on disk, decrypts to the original)
grep -q '^FOO=secret$' fleet/secrets/<server>.env && echo "LEAK: value in plaintext"
sops --decrypt --output-type dotenv fleet/secrets/<server>.env | grep '^FOO='
```

**Tamper fails closed** (a single flipped ciphertext byte is rejected). Flip one
base64 character inside the `"mac"` field of an encrypted JSON, then:

```bash
sops --decrypt fleet/secrets/<tunnel_id>.json ; echo "exit=$?"
# -> non-zero exit (51, MacMismatch); stderr mentions "MAC"; NO plaintext emitted.
```

A clean (un-tampered) file decrypts with exit `0`, so the check genuinely
distinguishes good from tampered ciphertext.

## CI never decrypts

The deploy/CI environment must have **no** age identity (no `SOPS_AGE_KEY*`, no
`keys.txt`, no YubiKey). Decryption there fails by design — secrets are only ever
decrypted on an operator's machine. Never add the age private key to CI secrets.

## Never commit plaintext

- Commit only the **encrypted** files under `fleet/secrets/` (every committed
  secret contains the `sops` metadata marker).
- The temp file miuops decrypts to is `0600` and shredded after converge — do not
  copy it into the repo.
- A quick guard: every committed secret should contain `sops` metadata.

  ```bash
  git -C <fleet-repo> grep -L sops -- 'fleet/secrets/*' && echo "UNENCRYPTED above"
  ```
