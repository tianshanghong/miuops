# Observability — Grafana Alloy → Grafana Cloud

Optional, opt-in per host. Each enabled server runs a **Grafana Alloy** container that
ships **metrics + logs** to **Grafana Cloud**. It is egress-only (no inbound port; the
agent pushes out), so it fits the tunnel-only model.

**Collected:** host metrics (CPU/mem/disk/net), per-container metrics (cAdvisor),
cloudflared metrics (`127.0.0.1:2000`), and all Docker container logs (apps + Traefik).
Disabled by default — a host without `observability_enabled: true` is untouched.

## 1. Get the connection details from Grafana Cloud

In your Grafana Cloud stack collect these (free tier is fine):

- **Prometheus** (Connections → Prometheus): remote-write URL + username (instance ID)
- **Loki** (Connections → Logs): push URL + username (instance ID)
- **Token** (Administration → Cloud access policies): create an access policy scoped to
  `metrics:write` + `logs:write`, then create a token under it.

## 2. Configure (environment variables — nothing stored on disk)

Provide the connection via environment variables at deploy time. The role reads them at
runtime; nothing is written to a vars file. The exact names:

```bash
export GRAFANA_CLOUD_PROM_URL="https://prometheus-prod-XX-REGION.grafana.net/api/prom/push"
export GRAFANA_CLOUD_PROM_USER="0000000"
export GRAFANA_CLOUD_LOKI_URL="https://logs-prod-XX.grafana.net/loki/api/v1/push"
export GRAFANA_CLOUD_LOKI_USER="0000000"
export GRAFANA_CLOUD_TOKEN="glc_..."
```

The **token is never stored on disk** — supply it via the env var each deploy (same
posture as `CF_API_TOKEN`). The URLs + instance IDs are not secret; if you tire of
exporting them you may instead set the matching `grafana_cloud_*` vars in gitignored
config (they override the env-lookup defaults) — but keep the token env-only.

## 3. Enable a host

Set this in that host's gitignored `host_vars/<host>.yml`:

```yaml
observability_enabled: true
```

## 4. Deploy

With the env vars from step 2 exported in your shell:

```bash
./miuops apply <host>      # or: ansible-playbook playbook.yml --limit <host> --tags observability
```

Within a few minutes the host's metrics and logs appear in Grafana Cloud. Enable the
Grafana Cloud **Docker / Linux Node** integrations for ready-made dashboards.

## Notes

- The token is rendered into `/etc/alloy/config.alloy` on the server at mode `0600`.
- If `observability_enabled` is true but any required value is unset, the play
  **fails fast and prints the exact env var names** to export — so a forgotten or
  misspelled variable is caught with a clear hint, not a half-started agent.
- **Known benign log noise:** cadvisor may log `failed to identify the read-write
  layer ID` for some containers. This only affects the per-container writable-layer
  *size* metric; container CPU/memory/network metrics are collected normally.
- **Follow-ups (not yet wired):** Traefik Prometheus metrics (requires enabling
  Traefik's metrics endpoint), host/systemd (journald) logs, CI deployment, and
  alert rules.
