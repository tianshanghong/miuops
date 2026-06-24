# Firewall Role

Host inbound firewall via **ufw**: zero open inbound ports except SSH. Docker manages its
own `FORWARD`/NAT chains and is not touched.

## Model

- **INPUT** — `ufw default deny incoming`; only SSH is allowed (rate-limited via `ufw limit`),
  plus optional management networks and a port whitelist. IPv6 inbound is denied too, with
  ufw's built-in ICMPv6/NDP allows (so `deny` does not break IPv6).
- **OUTPUT** — `allow outgoing`.
- **FORWARD** — left at policy `DROP` (`DEFAULT_FORWARD_POLICY="DROP"`). Docker inserts its
  own explicit `FORWARD` ACCEPT rules at the top of the chain and re-sets the FORWARD policy
  to DROP itself, so container forwarding/egress works before the default policy is reached
  (verified on-host). The role never adds FORWARD rules.

Container **published ports are kept off the public interface by the stacks policy**
(`127.0.0.1:` binds + the CI policy-check), not by this firewall. ufw is not relied on to
filter Docker's published ports.

## Coexistence with Docker

ufw owns INPUT; Docker owns FORWARD plus its NAT chains. On a fresh host this role runs
before Docker is installed, so ufw is already enabled by the time Docker starts and builds
its chains. `ufw enable`/`ufw reload` resets the filter table, so when the ufw config changes
on a re-converge of a host where Docker is already running, the role restarts Docker once to
rebuild its chains.

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `firewall_management_networks_v4` | IPv4 management nets allowed inbound (bypass rate-limit) | `[]` |
| `firewall_management_networks_v6` | IPv6 management nets allowed inbound | `[]` |
| `firewall_whitelist_ports_v4` | Extra inbound ports to allow besides SSH | `[]` |
| `firewall_whitelist_ports_v6` | Extra inbound ports (`ufw allow` covers both families) | `[]` |
| `ssh_port` | SSH port allowed / rate-limited | `"22"` |
| `firewall_ssh_ratelimit_enabled` | Use `ufw limit` (~6/30s) for SSH instead of plain allow | `true` |

## Requirements

- Debian/Ubuntu with `ufw` available.
- `community.general` collection (provides the `ufw` module).
