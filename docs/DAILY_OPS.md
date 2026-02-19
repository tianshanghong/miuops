# Daily Operations

Quick reference for day-to-day server management. All commands run over SSH to your server unless noted otherwise.

Stack directories are referenced as `$STACK_DIR` below — replace with the actual path (e.g., `/opt/stacks/myapp`).

## Connecting

```bash
ssh admin@your-server-ip
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

# Firewall (iptables)
sudo journalctl -k | grep iptables
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

### PostgreSQL (WAL-G base backup)

```bash
cd $STACK_DIR
docker compose exec postgres walg-backup.sh
```

### Volume backup (offen)

```bash
docker exec backup backup
```

### List existing backups

```bash
# PostgreSQL base backups
docker compose exec postgres wal-g backup-list

# Volume tarballs in S3 (run locally, not on server)
aws s3 ls s3://PROJECT-backup/vol/ --region REGION
```

## Deploying changes

Push to your stack repo's `main` branch. GitHub Actions handles deployment automatically:

```bash
# From your stack repo (local machine)
git add -A && git commit -m "Update config" && git push
```

To manually re-run a deploy without changes:

```bash
git commit --allow-empty -m "Redeploy" && git push
```

## Adding a domain to the tunnel

A single Cloudflare Tunnel can serve multiple domains. Re-run `./miuops up` with all domains — it's idempotent:

```bash
CF_API_TOKEN=your_token ./miuops up root@your-server existing.com newdomain.com
```

This registers DNS routes, updates the tunnel config, and re-runs the playbook. Existing domains are unaffected.

Then **add Traefik labels** in your stack repo's compose file with ``Host(`sub.newdomain.com`)`` and deploy.

The Cloudflare API token must have DNS edit permissions for all zones in the list (set this when [creating the token](INSTALLATION.md#create-a-cloudflare-api-token)).

## Infrastructure upgrades

Run from your local machine (where Ansible is installed):

```bash
# Full playbook
ansible-playbook playbook.yml

# Single role
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
