# Traefik → read-only docker-socket-proxy

Traefik discovers services from container labels, which needs the Docker API. The raw
`/var/run/docker.sock` is **root-equivalent**: anything that can talk to it can start a
privileged container and own the host. So Traefik must **not** mount the raw socket.
Instead, a small **read-only proxy** mounts the socket and exposes only the read-only API
Traefik needs; Traefik talks to the proxy over TCP on an internal network.

A compromised Traefik then reaches only `GET`/`HEAD` on a few endpoints — it cannot
start/exec/modify containers or read swarm secrets.

## What the stack must look like

The proxy and Traefik live in the **stack repo** (the GitOps-deployed compose), not in
miuops. Configure them like this:

```yaml
services:
  docker-socket-proxy:
    # Pin a digest (see hub.docker.com/r/tecnativa/docker-socket-proxy/tags).
    image: tecnativa/docker-socket-proxy:latest
    x-miuops-docker-socket-proxy: true     # opt in to the policy-check exception
    cap_drop: [ALL]
    read_only: true
    restart: unless-stopped
    environment:
      CONTAINERS: 1     # Traefik lists/inspects containers
      EVENTS: 1         # Traefik watches for changes
      PING: 1           # health
      POST: 0           # read-only: only GET/HEAD reach the daemon
      # everything else (SECRETS, CONFIGS, AUTH, EXEC, IMAGES, NETWORKS, …) stays off (0)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [socket_proxy]

  traefik:
    image: traefik:v3   # pin a digest
    # NO docker.sock mount here.
    command:
      - --providers.docker.endpoint=tcp://docker-socket-proxy:2375
      - --providers.docker.exposedByDefault=false
    networks: [socket_proxy, traefik_default]
    # ports / labels / ingress networks as before
    depends_on: [docker-socket-proxy]

networks:
  socket_proxy:
    internal: true     # proxy↔traefik only; no egress, no app stacks
  traefik_default: {}
```

## Why those exact settings (policy-check enforced)

The stack policy-check (`tests/stack_policy_check.py`) forbids any `docker.sock` mount
**except** a service that proves it is a read-only proxy. A compose file is rejected unless
the only `docker.sock`-mounting service:

- carries `x-miuops-docker-socket-proxy: true` (explicit opt-in),
- mounts the socket `:ro`,
- publishes no host port (it is reached only over the internal network, never re-exposed),
- sets `POST: 0` (no write methods reach the daemon), and
- enables none of `SECRETS` / `CONFIGS` / `AUTH` / `EXEC` (no secret read / no exec).

`POST: 0` blocks every write/exec verb — create/start/stop/exec are all `POST`, so they are
refused even if those sections are enabled. It does **not** block `GET` reads of `/secrets`,
`/configs`, `/auth`, so the policy-check requires those sections off *independently* of
`POST`. Verified on a host: with `POST=0` and those sections off, the proxy answers
`GET /containers/json` and `/_ping` (200) but returns `403` on `POST /containers/create`
and `GET /secrets`.

## Network isolation

Put the proxy on an `internal: true` network shared only with Traefik. The proxy needs no
outbound network of its own, and no application stack should be able to reach it — only
Traefik. Keep Traefik on that internal network **plus** its normal ingress networks.
