# Firewall Role

Manages **only host-owned netfilter state** and never touches Docker's chains — this is
what lets it coexist with Docker 28+ (which restructured its iptables integration into
`DOCKER-FORWARD`, `DOCKER-CT`, `DOCKER-BRIDGE`, … chains).

## Ownership model

- **INPUT** — zero open inbound ports: default `DROP`, established/related accept, lo,
  management nets, SSH rate-limit, optional whitelist, trailing `DROP`. The IPv6 INPUT
  also carries the required ICMPv6/NDP allow block (without it `DROP` silently breaks
  all IPv6).
- **OUTPUT / FORWARD policy** — `OUTPUT ACCEPT`, `FORWARD DROP` (policy only; the role
  never adds rules to or flushes the FORWARD chain).
- **DOCKER-USER** — container isolation. Docker owns the chain itself and the
  `FORWARD → DOCKER-USER` jump; this role owns the *contents*. The catch-all `DROP`
  blocks all external ingress to published ports **regardless of bind address** (so a
  `-p 8080:80` / `0.0.0.0` publish is still not reachable from the internet).

Everything else in the `filter` table (`DOCKER`, `DOCKER-FORWARD`, `DOCKER-CT`,
`DOCKER-BRIDGE`, `DOCKER-INTERNAL`, `DOCKER-ISOLATION-*`) is **Docker-owned and never
modified**.

## How it's applied

A small applier (`/usr/local/sbin/miuops-firewall.sh <host|docker-user>`) is run by
three systemd units:

- `miuops-firewall-host.service` — ordered before networking/docker; sets the INPUT
  zero-port ruleset + policies. Fail-closed: it sets `-P INPUT DROP` first, validates
  with `iptables-restore --test`, then replaces INPUT via `iptables-restore --noflush`
  (so OUTPUT/FORWARD/Docker chains are never touched).
- `miuops-firewall-docker-user.service` — `After`/`PartOf=docker.service`; applies
  DOCKER-USER as one atomic `iptables-restore --noflush` transaction (so the catch-all `DROP` is never
  momentarily absent), and re-applies it after every Docker (re)start.
- `miuops-firewall-docker-user.timer` — periodically reconciles DOCKER-USER to self-heal
  drift (a no-op when already correct).

The applier asserts the Docker-owned `FORWARD → DOCKER-USER` jump is present and ordered
before `DOCKER-FORWARD`; if it's persistently missing (Docker-chain corruption) it is
**fail-closed: it emergency-restores the jump at the top of `FORWARD`** (so published ports
stay guarded by DOCKER-USER's DROP) and warns to repair with `systemctl restart docker`.

Docker is coupled to the host firewall **fail-closed**: a `docker.service` drop-in
(`Requires=`+`After=miuops-firewall-host.service`, plus an `ExecStartPre` that re-applies
the host firewall on every Docker start) means Docker refuses to start unless the firewall
applies cleanly — re-validated on each start, not trusted once. A firewall failure takes
the services offline rather than starting containers with their published ports unprotected.

This role does not use `netfilter-persistent`; persistence is the systemd units above.
(Migrating an older miuops box that used netfilter-persistent? Mask it and remove its
`/etc/iptables/rules.v{4,6}` once at cutover — its whole-table restore would otherwise
flush Docker's chains on the next boot.)

## Threat-model boundary

DOCKER-USER protects **bridge-networked** published ports. `network_mode: host` and
macvlan/ipvlan containers bypass FORWARD/DOCKER-USER and are governed by **INPUT
(default DROP)** — bind such services to loopback unless a port is intentionally
whitelisted.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `firewall_management_networks_v4` | IPv4 management network segments to allow | `[]` |
| `firewall_management_networks_v6` | IPv6 management network segments to allow | `[]` |
| `firewall_whitelist_ports_v4` | IPv4 ports to allow (besides SSH) | `[]` |
| `firewall_whitelist_ports_v6` | IPv6 ports to allow (besides SSH) | `[]` |
| `ssh_port` | SSH port opened / rate-limited | `"22"` |
| `firewall_ssh_ratelimit_enabled` | Rate-limit new SSH connections | `true` |
| `firewall_ssh_ratelimit_hits` | New conns allowed per window | `10` |
| `firewall_ssh_ratelimit_seconds` | Rate-limit window (seconds) | `60` |
| `firewall_reconcile_interval` | How often the DOCKER-USER reconcile timer runs | `"5min"` |

## Requirements

- `iptables` (nft backend) on the target (Debian/Ubuntu) — provides `iptables-restore`
  and the `iptables-nft` backend.
- Docker provides + owns the DOCKER-USER chain and its FORWARD jump.
