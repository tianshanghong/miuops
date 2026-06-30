# Daily Operations

Quick reference for day-to-day server management. All commands run over SSH to your server unless noted otherwise.

Stack directories are referenced as `$STACK_DIR` below — replace with the actual path (e.g., `/opt/stacks/myapp`).

## Connecting

```bash
ssh admin@your-server-ip
```

## Managing containers with LazyDocker

[LazyDocker](https://github.com/jesseduffield/lazydocker) is the recommended TUI for
inspecting containers, logs, and resource usage. Point it at the server through a
Docker context over SSH (no extra daemon port exposed):

```bash
docker context create myserver --docker "host=ssh://admin@your-server"
docker context use myserver
lazydocker
```

## Viewing logs

```bash
# All containers
docker ps
docker logs -f CONTAINER_NAME

# Per stack (from the stack directory)
cd $STACK_DIR
docker compose logs -f

# Specific service within a stack
docker compose logs -f SERVICE_NAME

# cloudflared tunnel
sudo journalctl -u cloudflared -f

# Firewall (ufw)
sudo ufw status verbose
```

## Checking status

```bash
# All running containers
docker ps

# Specific stack
cd $STACK_DIR
docker compose ps

# cloudflared tunnel
sudo systemctl status cloudflared

# Disk usage
df -h
docker system df
```

## Restarting services

```bash
# Restart a specific service within a stack
cd $STACK_DIR
docker compose restart SERVICE_NAME

# Restart all services in a stack
docker compose restart

# Restart cloudflared
sudo systemctl restart cloudflared
```

## Manual backup trigger

miuOps backs up Docker volumes only; databases are outsourced to managed Postgres
(see the provider's tooling for database backups).

### Volume backup (host-side `backup` role)

```bash
# Trigger a run now (does not wait for the timer)
systemctl start miuops-backup.service
journalctl -u miuops-backup.service -f   # watch it

# When does it next fire?
systemctl list-timers miuops-backup.timer
```

### List existing backups

```bash
# Volume tarballs in S3 (one prefix per volume)
aws s3 ls s3://PROJECT-backup/<server>/vol/ --recursive --region REGION
```

## Deploying changes

Push to your fleet repo's `main` branch. GitHub Actions handles deployment automatically:

```bash
# From your fleet repo (local machine)
git add -A && git commit -m "Update config" && git push
```

To manually re-run a deploy without changes:

```bash
git commit --allow-empty -m "Redeploy" && git push
```

## Adding a domain

Use `add-domain` — it's additive: only the new domain's DNS is created, existing
domains are untouched.

```bash
CF_API_TOKEN=your_token miuops add-domain <host> newdomain.com
```

`<host>` is the server's alias in `fleet/inventory.ini`. This creates the `newdomain.com`
and `*.newdomain.com` CNAMEs, merges the domain into the host's `fleet/host_vars`, and
re-converges. Then **add Traefik labels** in your fleet repo's compose file with
``Host(`sub.newdomain.com`)`` and deploy.

The Cloudflare API token needs DNS edit permission for the domain's zone (set this
when [creating the token](INSTALLATION.md#create-a-cloudflare-api-token)).

## Removing a domain

Use `remove-domain` — it drops the domain from the host's `fleet/host_vars`, **deletes the
orphaned CNAMEs** (`d` and `*.d`) for you, and re-converges:

```bash
CF_API_TOKEN=your_token miuops remove-domain <host> example.org
```

No manual Cloudflare dashboard cleanup needed. A server must keep at least one
domain — removing the last one is refused unless you pass `--force`.

## Deleting a tunnel

To fully remove a Cloudflare Tunnel and decommission:

**1. Delete the tunnel** (from your local machine where `cert.pem` exists):

```bash
cloudflared tunnel list                    # find the tunnel name/ID
cloudflared tunnel delete <tunnel-name>    # e.g. miuops-203-0-113-10
```

**2. Remove DNS CNAME records** from the [Cloudflare dashboard](https://dash.cloudflare.com):

For each domain, delete the two CNAME records pointing to `<tunnel-id>.cfargotunnel.com`:
- `example.com` → `<tunnel-id>.cfargotunnel.com`
- `*.example.com` → `<tunnel-id>.cfargotunnel.com`

**3. Clean up local files:**

```bash
rm -f fleet/secrets/<tunnel-id>.json
rm -f fleet/host_vars/<host>.yml
# remove the host's line from fleet/inventory.ini — or `rm -f fleet/inventory.ini` only if it was your only server
```

The next `miuops up` will create a fresh tunnel.

## Reconfiguring servers (apply)

Re-converge a server (or the whole fleet) after changing `fleet/host_vars` or pulling
tool updates — run from your local machine. `apply` only re-runs the playbook; it
doesn't touch DNS, so no `CF_API_TOKEN` is needed.

```bash
miuops apply <host>     # one server
miuops apply            # the whole fleet

# Single role (add --limit <host> to scope to one server):
ansible-playbook playbook.yml --tags firewall
ansible-playbook playbook.yml --tags docker
ansible-playbook playbook.yml --tags traefik
ansible-playbook playbook.yml --tags cloudflared
```

## Cleanup

```bash
# Remove unused images, containers, networks
docker system prune -f

# Also remove unused volumes (careful — check first)
docker volume ls
docker system prune --volumes -f
```
