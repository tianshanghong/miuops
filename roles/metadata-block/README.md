# Metadata-Block Role

Blocks **containers** from reaching the cloud metadata endpoint (`169.254.169.254`).

A compromised container that can reach the metadata service can read cloud instance metadata —
often including **credentials** (IAM role keys, API tokens). A request-forgery (SSRF) bug in
any web app then becomes cloud-account compromise. Blocking the endpoint at the container
boundary removes that path regardless of the app.

Some clouds (and link-local routing) already make metadata unreachable from a container, but
that is incidental and not portable — this role makes the block **explicit and host-agnostic**.

## What it does

- Installs `/usr/local/sbin/miuops-metadata-block.sh`, which inserts a DROP at the top of the
  `DOCKER-USER` chain for the link-local range `169.254.0.0/16` (which hosts every cloud
  metadata endpoint — `169.254.169.254` IMDS, the AWS ECS task-role endpoint `169.254.170.2`,
  …) and the AWS IPv6 endpoint `fd00:ec2::254` (best-effort). `DOCKER-USER` is the chain Docker
  traverses **first** in `FORWARD`, so the DROP beats Docker's own ACCEPT rules. The script is
  idempotent (`-C` before `-I`). The whole `/16` is blocked because bridge containers get
  RFC1918 addresses and have no legitimate use for link-local.
- Installs a oneshot systemd unit (`After=docker.service`, `PartOf=docker.service`) that runs
  the script on boot and re-applies it if Docker restarts. The converge also asserts the rule
  is present, so a silent failure surfaces loudly.

The **host's** own access to metadata is unaffected — the rule only filters Docker `FORWARD`
(container) traffic, not the host's `OUTPUT`.

## Scope

- **Host-network containers** (`network_mode: host`) are **not** covered — they share the host
  network namespace, so their traffic never enters `FORWARD`/`DOCKER-USER`. Such containers are
  root-equivalent anyway and are governed separately by the publish-time policy-check (which
  forbids host networking unless a service explicitly opts in).
- **IPv6:** the v6 block is best-effort and applies only when Docker IPv6 is enabled. Enabling
  Docker IPv6 later means revisiting `metadata_block_ipv6`.
- Clouds whose metadata endpoint is outside `169.254.0.0/16` (e.g. Alibaba `100.100.100.200`)
  are not covered by default; add them to `metadata_block_ipv4` if relevant.

## Requirements

- Docker (the `DOCKER-USER` chain is created by the Docker daemon). The role runs after the
  `docker` role.
