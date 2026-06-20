# Managing a fleet of servers

MiuOps manages multiple servers from a single checkout. Each server has:

- one line in `inventory.ini` (under `[bare_metal]`), and
- one `host_vars/<name>.yml` holding its `domains` + `tunnel_id`.

Globals (`ssh_port`, `credentials_file`, firewall rate-limit defaults) come from
role defaults, so a per-server file stays tiny. Converge one server, several, or
all with `--limit`:

```bash
miuops apply server-a        # one server
miuops apply                 # the whole fleet
ansible-playbook playbook.yml --limit server-a   # equivalent
```

## Migrating an existing single-server setup

1. `mkdir -p host_vars`
2. Create `host_vars/<inventory_hostname>.yml` with the `domains` and `tunnel_id`
   from your old `group_vars/all.yml` (see `host_vars/server1.yml.example`).
3. Delete `group_vars/all.yml`.
4. Ensure `inventory.ini` lists the host (flat, under `[bare_metal]`).
5. `ansible-playbook playbook.yml --limit <host>` — should report `changed=0`.

From separate clones: do the above once per server in a single checkout, import
each server's `files/<tunnel_id>.json`, then retire the old clones.
