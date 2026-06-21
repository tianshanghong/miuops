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

## 2. Configure (non-secret bits in gitignored config)

Put the URLs + instance IDs in your gitignored `group_vars/all.yml` (one Cloud stack
for the whole fleet):

```yaml
# group_vars/all.yml  (gitignored)
grafana_cloud_prometheus_url:  "https://prometheus-prod-XX-REGION.grafana.net/api/prom/push"
grafana_cloud_prometheus_user: "0000000"
grafana_cloud_loki_url:        "https://logs-prod-XX.grafana.net/loki/api/v1/push"
grafana_cloud_loki_user:       "0000000"
# grafana_cloud_token: "..."   # optional: set here (gitignored) instead of the env var
```

The **token is secret**. Either set it in the gitignored config above, or pass it at
deploy time via the `GRAFANA_CLOUD_TOKEN` environment variable. Never commit it.

## 3. Enable a host

Set this in that host's gitignored `host_vars/<host>.yml`:

```yaml
observability_enabled: true
```

## 4. Deploy

```bash
export GRAFANA_CLOUD_TOKEN=glc_xxx...     # skip if you set it in group_vars
./miuops apply <host>                      # or: ansible-playbook playbook.yml --limit <host> --tags observability
```

Within a few minutes the host's metrics and logs appear in Grafana Cloud. Enable the
Grafana Cloud **Docker / Linux Node** integrations for ready-made dashboards.

## Notes

- The token is rendered into `/etc/alloy/config.alloy` on the server at mode `0600`.
- If `observability_enabled` is true but the connection settings are incomplete, the
  play **fails fast** (it will not start a misconfigured agent).
- **Follow-ups (not yet wired):** Traefik Prometheus metrics (requires enabling
  Traefik's metrics endpoint), host/systemd (journald) logs, CI deployment, and
  alert rules.
