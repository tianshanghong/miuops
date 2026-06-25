# Unattended-Upgrades Role

Applies **unattended security upgrades with NO automatic reboot**.

A tunnel-only host should patch its own security holes without an operator babysitting it —
but it must never reboot itself unattended: a surprise reboot drops the Cloudflare tunnel and
every running stack until someone notices.

## What it does

- Installs `unattended-upgrades`.
- Deploys `/etc/apt/apt.conf.d/52-miuops-unattended.conf`:
  - `APT::Periodic::Update-Package-Lists "1";` + `APT::Periodic::Unattended-Upgrade "1";` —
    refresh + apply on the `apt-daily` timer.
  - `Unattended-Upgrade::Automatic-Reboot "false";` — **never reboot unattended**.
- Enables `apt-daily-upgrade.timer`.

**Origins:** left at the distro default — the `-security` pocket plus the base release pocket,
and **not** `-updates` / `-proposed` / backports. The `-security` pocket carries the security
fixes; the base release pocket changes only at point releases (which fold in stable-updates),
so in normal operation the only automatic upgrades are security ones. (apt.conf list semantics
let a drop-in only *append* to `Allowed-Origins`, never remove the default entries, so the role
relies on the default rather than rewriting it — and the default already excludes `-updates`.)

## Maintenance

Because the host never reboots itself, a security upgrade that needs a reboot (kernel, glibc)
or a service restart leaves it patched-on-disk but still running the old code until the
operator acts. `unattended-upgrades` writes `/var/run/reboot-required` when a reboot is owed —
check it (or alert on it via the observability role) and reboot in a maintenance window.

## Requirements

- Debian/Ubuntu with the `unattended-upgrades` package available + the `apt-daily` systemd
  timers (default on current releases).
