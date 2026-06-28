# Observability — Grafana Alloy → Grafana Cloud

On by default. Each server runs **Grafana Alloy** as a host systemd service that ships
**metrics + logs** to **Grafana Cloud**. It is egress-only (no inbound port; the agent
pushes out), so it fits the tunnel-only model.

**Collected:** host metrics (CPU/mem/disk/net), per-container metrics (cAdvisor),
cloudflared metrics (`127.0.0.1:2000`), and all Docker container logs (apps + Traefik).
On by default — it activates once the connection (below) is configured; an
enabled-but-unconfigured host skips with a warning, so a fleet that hasn't set up Grafana
Cloud still converges. Opt a host out with `observability_enabled: false`.

## 1. Get the connection details from Grafana Cloud

In your Grafana Cloud stack collect these (free tier is fine):

- **Prometheus** (Connections → Prometheus): remote-write URL + username (instance ID)
- **Loki** (Connections → Logs): push URL + username (instance ID)
- **Token** (Administration → Cloud access policies): create an access policy scoped to
  `metrics:write` + `logs:write`, then create a token under it.

## 2. Configure — endpoints are versioned config, the token is the one secret

The push **endpoints + user IDs are CONFIG** (not secret, identical across the fleet).
Set them once in your fleet's `group_vars/all.yml` (see `group_vars/all.yml.example`) —
versioned, never via per-apply env:

```yaml
# fleet/group_vars/all.yml
grafana_cloud_prometheus_url:  "https://prometheus-prod-XX-REGION.grafana.net/api/prom/push"
grafana_cloud_prometheus_user: "0000000"
grafana_cloud_loki_url:        "https://logs-prod-XX.grafana.net/loki/api/v1/push"
grafana_cloud_loki_user:       "0000000"
```

The **token is the one secret** — it is never versioned. SOPS-encrypt it in the fleet,
where the converge decrypts it with your age key — no per-apply env:

```bash
printf '{ "grafana_cloud_token": "glc_..." }\n' > fleet/secrets/all.vars.json
sops --encrypt --in-place fleet/secrets/all.vars.json
```

(A bare `export GRAFANA_CLOUD_TOKEN=...` still works as a fallback. See [Secret Model](SECRETS.md) — including the plaintext-before-commit caveat.)

## 3. On by default — opt out per host

Observability is **on by default** and activates once the connection above is set. To
turn it off for a specific host, set in that host's gitignored `host_vars/<host>.yml`:

```yaml
observability_enabled: false
```

## 4. Deploy

With your age key unlocked (the converge decrypts the token from `all.vars.json`; the endpoints come from `group_vars/all`):

```bash
miuops apply <host>        # or: ansible-playbook playbook.yml --limit <host> --tags observability
```

Within a few minutes the host's metrics and logs appear in Grafana Cloud. Enable the
Grafana Cloud **Docker / Linux Node** integrations for ready-made dashboards.

## Notes

- The token is rendered into `/etc/alloy/config.alloy` on the server at mode `0600`.
- On by default but unconfigured (no Grafana endpoint) → the role **skips with a
  warning**, so the converge still succeeds. A **partial** config (the endpoint set but
  another value missing) **fails fast** — set all endpoints in `group_vars/all` and
  the token in `fleet/secrets/all.vars.json` (SOPS); a half-configured agent is never
  shipped.
- **Docker 29+ (overlayfs):** Docker 29 made `overlayfs` the default storage driver,
  which dropped the on-disk layer layout the old cAdvisor read. cAdvisor v0.54+
  (bundled in Alloy >= 1.14) instead resolves each container's read-write layer
  through containerd, so this role pins a new-enough Alloy package version. Alloy runs
  as a host process (root) and reads the host `containerd.sock` directly. On older Alloy
  the agent logs `failed to identify the read-write layer ID` and drops **all**
  per-container metrics (not just writable-layer size).
- **Follow-ups (not yet wired):** Traefik Prometheus metrics (requires enabling
  Traefik's metrics endpoint), host/systemd (journald) logs, CI deployment, and
  alert rules.
