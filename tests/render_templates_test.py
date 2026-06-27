#!/usr/bin/env python3
"""Render the Ansible Jinja2 templates that carry observability/backup config +
secrets, with sample vars, and assert the rendered bytes.

STATELESS -- no host, no Ansible run -- so it is clean by construction and runs
in CI. This is the verification net for the config/secret-split work and the
SOPS-in-fleet migration: those change HOW these templates obtain their values
(env lookup -> versioned vars -> decrypted-at-converge), but the rendered output
must stay correct. A template edit that drops a secret, swaps a field, empties a
credential (a stray `| default('')`), duplicates a secret, or mis-gates a block
must FAIL here.

Templates use only stock Jinja2 (the `| length` filter + one `if`), so plain
jinja2 renders them faithfully. The Environment matches Ansible's template module
(trim_blocks=True, lstrip_blocks=False, keep_trailing_newline=True, StrictUndefined)
so the rendered bytes match a real converge.

Teeth (each proven to FAIL on the matching regression):
  - value placement: every secret/endpoint must land in its exact field;
  - occurrence count: a secret must appear EXACTLY where expected -- a duplicate
    (leak to a second place) changes the count and fails;
  - line-anchored env-file: trailing whitespace that would corrupt a sourced
    AWS_* value is rejected (a substring match would miss it);
  - required-var control: omitting ANY credential/endpoint must RAISE
    (StrictUndefined) -- this catches a rename, a drop, AND a `| default('')`
    that would otherwise silently render an EMPTY secret the placement asserts
    above cannot see.
"""
import sys
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
    from jinja2.exceptions import UndefinedError
except ImportError:
    # Fail loud, never a silent skip: a green that never ran is the worst signal.
    # jinja2 ships with Ansible; in CI run this AFTER the Ansible install step.
    print("FAIL: jinja2 not importable (install ansible, or `pip install jinja2`)")
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def render(relpath, variables):
    # Match Ansible's template module Jinja2 settings (trim_blocks=True,
    # lstrip_blocks=False, keep_trailing_newline=True) so the rendered bytes match
    # what a converge produces. These templates use only stock Jinja2 (no Ansible
    # filters or host facts), so this standalone render is faithful.
    tpl = ROOT / relpath
    env = Environment(
        loader=FileSystemLoader(str(tpl.parent)),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=False,
        keep_trailing_newline=True,
    )
    return env.get_template(tpl.name).render(**variables)


def assert_required_vars_raise_when_omitted(relpath, full_vars, required_names):
    """The net's teeth for the secret/split migration. Omitting any credential or
    endpoint must RAISE (StrictUndefined) -- which catches a renamed var (old name
    gone), a dropped reference, AND a `| default('')` added to it (the default
    would otherwise silently render an EMPTY value -- an empty secret or endpoint
    -- that the value-placement asserts cannot detect)."""
    for var in required_names:
        reduced = {k: v for k, v in full_vars.items() if k != var}
        try:
            render(relpath, reduced)
            check(False, f"{relpath}: omitting '{var}' rendered without error -- a "
                         f"rename or `| default(...)` on it would emit a value silently, not fail")
        except UndefinedError:
            pass  # expected -- this var is genuinely required


# ---------------------------------------------------------------- backup.env.j2
BACKUP = "roles/backup/templates/backup.env.j2"
bvars = dict(
    backup_aws_access_key_id="AKIA_SAMPLE_KEY",
    backup_aws_secret_access_key="SECRET_SAMPLE_VALUE",
    backup_aws_region="uswest2sample",
)
benv = render(BACKUP, bvars)
blines = benv.splitlines()
# Line-anchored (not substring): a trailing space / \r would corrupt the value that
# systemd's EnvironmentFile sources, yet a substring match would not see it.
check("AWS_ACCESS_KEY_ID=AKIA_SAMPLE_KEY" in blines, "backup.env: access key id is not an exact line (trailing drift?)")
check("AWS_SECRET_ACCESS_KEY=SECRET_SAMPLE_VALUE" in blines, "backup.env: secret access key is not an exact line")
check("AWS_DEFAULT_REGION=uswest2sample" in blines, "backup.env: region is not an exact line")
# Exactly once each -- a duplicate would leak the secret to a second place.
check(benv.count("SECRET_SAMPLE_VALUE") == 1, "backup.env: secret must appear exactly once (a duplicate is a leak)")
check(benv.count("AKIA_SAMPLE_KEY") == 1, "backup.env: access key id must appear exactly once")
assert_required_vars_raise_when_omitted(BACKUP, bvars, list(bvars))

# -------------------------------------------------------------- config.alloy.j2
ALLOY = "roles/observability/templates/config.alloy.j2"
gvars = dict(
    observability_scrape_interval="60s",
    observability_cloudflared_metrics="127.0.0.1:2000",
    grafana_cloud_prometheus_url="https://prom.example/api/prom/push",
    grafana_cloud_prometheus_user="promuser1111",
    grafana_cloud_loki_url="https://loki.example/loki/api/v1/push",
    grafana_cloud_loki_user="lokiuser2222",
    grafana_cloud_token="glc_SAMPLE_TOKEN",
)
alloy = render(ALLOY, gvars)
# Value placement -- quoted values, so trailing space inside the quotes breaks the match.
# Block-scoped placement: prometheus creds/endpoint must be in the METRICS section
# (remote_write), loki's in LOGS (loki.write). A prometheus<->loki swap -- the exact
# per-backend vars the secret-split/SOPS migration renames -- keeps every value's
# count and field-type but routes each to the WRONG backend; only a section-scoped
# check catches it (a global substring/count cannot).
metrics_half, _divider, logs_half = alloy.partition("//////////////////// LOGS")
check(_divider != "", "alloy: METRICS/LOGS divider missing -- cannot block-scope the endpoints")
check('url = "https://prom.example/api/prom/push"' in metrics_half, "alloy: prometheus url must be in the METRICS section (remote_write)")
check('username = "promuser1111"' in metrics_half, "alloy: prometheus user must be in the METRICS section")
check('url = "https://loki.example/loki/api/v1/push"' in logs_half, "alloy: loki url must be in the LOGS section (loki.write)")
check('username = "lokiuser2222"' in logs_half, "alloy: loki user must be in the LOGS section")
check('scrape_interval = "60s"' in alloy, "alloy: scrape interval not rendered")
check('password = "glc_SAMPLE_TOKEN"' in alloy, "alloy: token not rendered as a basic_auth password")
# Occurrence counts -- the token is the password for BOTH backends (exactly 2); every
# other credential/endpoint appears exactly once. A leak to an extra field changes it.
check(alloy.count("glc_SAMPLE_TOKEN") == 2, "alloy: token must appear exactly twice (prometheus + loki passwords)")
check(alloy.count("promuser1111") == 1, "alloy: prometheus user must appear exactly once")
check(alloy.count("lokiuser2222") == 1, "alloy: loki user must appear exactly once")
check(alloy.count("https://prom.example/api/prom/push") == 1, "alloy: prometheus url must appear exactly once")
check(alloy.count("https://loki.example/loki/api/v1/push") == 1, "alloy: loki url must appear exactly once")
# The per-host external_label that keeps identically-named series/containers distinct
# across hosts -- on BOTH the metrics remote_write and the loki.write.
check(alloy.count("host = constants.hostname") == 2, "alloy: per-host external_labels must be on both remote_write and loki.write")
# forward_to wiring: both metrics scrapes (node+containers, cloudflared) feed the
# grafana_cloud remote_write (2); container logs feed grafana_cloud loki.write (1).
# A mis-wired forward_to silently drops that whole signal.
check(alloy.count("[prometheus.remote_write.grafana_cloud.receiver]") == 2, "alloy: both metrics scrapes must forward to the grafana_cloud remote_write")
check(alloy.count("[loki.write.grafana_cloud.receiver]") == 1, "alloy: container logs must forward to the grafana_cloud loki.write")
# Cloudflared scrape block is gated ON when an address is configured.
check('prometheus.scrape "cloudflared"' in alloy, "alloy: cloudflared scrape missing when address set")
check('"__address__" = "127.0.0.1:2000"' in alloy, "alloy: cloudflared address not rendered")
# Same template with NO cloudflared address -> the block must be gated OUT.
alloy_nocf = render(ALLOY, {**gvars, "observability_cloudflared_metrics": ""})
check('prometheus.scrape "cloudflared"' not in alloy_nocf, "alloy: cloudflared block must be absent when address empty (gate broken)")
# Required credentials/endpoints: omitting any must raise (the empty-secret guard).
# NOT scrape_interval / cloudflared_metrics -- those are legitimately defaultable.
assert_required_vars_raise_when_omitted(ALLOY, gvars, [
    "grafana_cloud_prometheus_url", "grafana_cloud_prometheus_user",
    "grafana_cloud_loki_url", "grafana_cloud_loki_user", "grafana_cloud_token",
])

if fails:
    print("FAIL:")
    for m in fails:
        print("  -", m)
    sys.exit(1)
print("ALL TEMPLATE RENDER CHECKS PASSED")
