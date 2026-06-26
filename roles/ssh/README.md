# SSH Role

Host SSH hardening: **key-only authentication**.

The public SSH port (22) is the one service a tunnel-only host still exposes, and it is under
constant internet-wide password brute-force. This role disables password authentication so
that brute-force is pointless — only key holders can log in.

## What it does

Deploys `/etc/ssh/sshd_config.d/10-miuops-ssh.conf` (a drop-in, leaving the distro's base
`sshd_config` untouched) and reloads sshd:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthenticationMethods publickey
```

The `10-` prefix matters: sshd uses the **first** value it sees for each keyword and reads
`sshd_config.d/*.conf` in lexical order, so this must sort **before** a cloud image's
`50-cloud-init.conf` (which may set `PasswordAuthentication yes`) — otherwise the cloud-init
value silently wins and the host stays password-open. `PermitRootLogin prohibit-password`
keeps root reachable by key (the deploy connects as root) while refusing root password
logins. `AuthenticationMethods publickey` makes "publickey and nothing else" explicit. The
drop-in is validated with `sshd -t` before the reload, so a syntax error can never lock you
out.

SSH connection **rate-limiting** (`ufw limit`, ~6 conns/30s) is handled by `roles/firewall`,
which runs just before this role. fail2ban and a tight `MaxAuthTries` are intentionally
omitted — key-only already makes password brute-force pointless, and a low `MaxAuthTries`
breaks legitimate multi-key SSH agents.

## CI deploy keys (`deploy_public_keys`)

Before the lockout guard runs, the role installs each entry of the `deploy_public_keys`
host_var into the **connecting user's** `authorized_keys` — the same user (root by default)
that the guard checks and that CI/rsync connects as. This is how a per-server CI deploy key
gets onto the host.

```yaml
# fleet/host_vars/<server>.yml
deploy_public_keys:
  - "ssh-ed25519 AAAA... ci-deploy@<server>"   # PUBLIC key ONLY
```

Key properties:

- **PUBLIC keys only.** The operator generates the keypair; the tool only ever handles the
  **public** key. Every entry is positively matched against an allowlist of public-key types
  (`ssh-rsa`, `ssh-ed25519`, `ssh-dss`, `ecdsa-sha2-`, `sk-ssh-ed25519@openssh.com`,
  `sk-ecdsa-sha2-`) **and** refused if it contains `PRIVATE KEY`. A private key fed in by
  mistake **fails the converge** (fail-closed) and is never written.
- **Additive, not exclusive.** Keys are added with `exclusive: false`, so the operator's
  existing bootstrap key (which the lockout guard depends on) is preserved. Rotation: add the
  new key, update the Environment secret, converge, then remove the old key from both the list
  and `authorized_keys`.
- **Installed before the guard.** The install runs above the key-only lockout guard, so a
  host that only had the operator's bootstrap key also gains the CI key and the guard still
  passes.
- **No-op by default.** `deploy_public_keys` defaults to `[]`, so an Ansible-only `apply`
  without the CLI still converges and existing servers are unaffected.

The matching **private** key never enters this repo and never touches the tool. The operator
puts it into the per-server **GitHub Environment** as a secret:

```sh
ssh-keygen -t ed25519 -f deploy_<server> -C "ci-deploy@<server>" -N ""
# deploy_<server>.pub  -> deploy_public_keys in fleet/host_vars/<server>.yml
# deploy_<server>      -> GitHub Environment <server>, secret SSH_PRIVATE_KEY:
gh secret set SSH_PRIVATE_KEY --env <server> --body "$(cat deploy_<server>)"
shred -u deploy_<server>   # private key now lives ONLY in the Environment
```

The allowlist/refusal logic is covered by a test: `tests/ssh_deploy_key_validation_test.sh`.

## Requirements

- A working SSH **key** in the deploy user's `authorized_keys` BEFORE this runs — once
  password auth is off, only keys work. The role **asserts** this and fails fast (no lockout)
  if none is present. (Fresh hosts are provisioned with the operator's key; a
  `deploy_public_keys` entry is installed just above, so it also satisfies the guard.)
- `ansible.posix` collection (already a declared dependency in `requirements.yml`) for the
  `authorized_key` module.
- Debian/Ubuntu with the `sshd_config.d/` drop-in directory (default on current releases).
