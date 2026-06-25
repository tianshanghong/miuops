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

## Requirements

- A working SSH **key** in the deploy user's `authorized_keys` BEFORE this runs — once
  password auth is off, only keys work. The role **asserts** this and fails fast (no lockout)
  if none is present. (Fresh hosts are provisioned with the operator's key.)
- Debian/Ubuntu with the `sshd_config.d/` drop-in directory (default on current releases).
