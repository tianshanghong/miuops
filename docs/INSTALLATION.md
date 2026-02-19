# Installation Guide

End-to-end walkthrough: from bare server to running services. For a condensed version, see the [README Quick Start](../README.md#quick-start).

## Prerequisites

| Requirement | Purpose |
|---|---|
| Cloudflare account with your domain(s) | DNS, CDN, WAF |
| Cloudflare API token | Tunnel creation and DNS records (scope to all zones you'll use) |
| Server with SSH access (Debian/Ubuntu) | Target machine |
| Local tools: `ansible`, `cloudflared`, `jq`, `curl`, `ssh` | The CLI checks these and guides you |
| aws CLI (configured with admin credentials) | Backup bucket setup (Step 2) |

### Create a Cloudflare API token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) > My Profile > [API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template
4. Scope it to the zone(s) you'll use
5. Save the token — you'll pass it as `CF_API_TOKEN` when running `./miuops up`

### Install local tools

```bash
# macOS
brew install ansible cloudflare/cloudflare/cloudflared jq

# Ubuntu/Debian
sudo apt update && sudo apt install ansible jq
# cloudflared: see https://pkg.cloudflare.com/
```

### Install aws CLI (for backups, Step 2)

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials
aws configure
```

## Step 1: Bootstrap the server

```bash
git clone https://github.com/tianshanghong/miuops
cd miuops

# Single domain
CF_API_TOKEN=your_token ./miuops up root@203.0.113.10 example.com

# Multiple domains
CF_API_TOKEN=your_token ./miuops up root@203.0.113.10 example.com example.org
```

The CLI handles everything:
1. Checks prerequisites (and tells you how to install any that are missing)
2. Looks up the Cloudflare Zone ID for each domain
3. Creates a Cloudflare Tunnel (or reuses an existing one)
4. Creates DNS CNAME records for all domains (Cloudflare API)
5. Generates `inventory.ini` and `group_vars/all.yml`
6. Installs Ansible Galaxy dependencies
7. Runs the playbook

The playbook provisions the server with:
- **iptables firewall** — default-DROP on INPUT and DOCKER-USER chains, rate-limited SSH
- **Docker CE + Compose** — hardened daemon (ICC disabled, userland proxy disabled)
- **Traefik directories + Docker network** — ready for compose deployment
- **cloudflared** — systemd service with tunnel config for all domains

### Dry run

Preview what would happen without making changes:

```bash
CF_API_TOKEN=your_token ./miuops up --dry-run root@203.0.113.10 example.com example.org
```

### Manual setup (alternative)

If you prefer to configure things manually instead of using the CLI:

<details>
<summary>Click to expand manual steps</summary>

```bash
# Install Ansible requirements
ansible-galaxy collection install -r requirements.yml

# Configure
cp inventory.ini.template inventory.ini
cp group_vars/all.yml.template group_vars/all.yml
# Edit inventory.ini with your server details
# Edit group_vars/all.yml with your domains and tunnel ID

# Create Cloudflare Tunnel (handled automatically by ./miuops up)
cloudflared tunnel create miuops-203-0-113-10
# Create DNS CNAME records in Cloudflare dashboard for each domain:
#   example.com     -> <tunnel-id>.cfargotunnel.com (Proxied)
#   *.example.com   -> <tunnel-id>.cfargotunnel.com (Proxied)
# Copy tunnel credentials JSON into files/

# Bootstrap server
ansible-playbook playbook.yml
```

</details>

## Step 2: Set up backups

```bash
./scripts/setup-s3-backup.sh
```

The script prompts for a project name and AWS region (default: `us-west-2`), then creates:
- S3 bucket `{project}-backup` with Object Lock (Governance, 30 days)
- Lifecycle rules: transition to Glacier at 30 days, expire at 90 days
- IAM user `{project}-backup` with PutObject/GetObject/ListBucket only (no Delete)
- Access key credentials

Save the output — you'll need `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, and the bucket name for your stack repo's `.env` file.

## Step 3: Create your stack repo

1. Go to **[miuops-stack-template](https://github.com/tianshanghong/miuops-stack-template)** and click **Use this template** > **Create a new repository** (private)

2. Configure GitHub Actions secrets in your new repo (Settings > Secrets > Actions):

   | Secret | Value |
   |---|---|
   | `SSH_HOST` | Your server IP or hostname |
   | `SSH_USER` | SSH user (same as `ansible_user`) |
   | `SSH_PRIVATE_KEY` | Contents of your SSH private key |

3. SSH into the server and fill in `/opt/stacks/.env` (pre-created by the Ansible bootstrap with secure permissions):

   ```bash
   ssh root@your-server nano /opt/stacks/.env
   ```

   Copy variables from `.env.example` and fill in real values — domains, backup credentials (from Step 2), and service-specific variables.

## Step 4: Deploy

Push to `main` to trigger the GitHub Actions deploy pipeline:

```bash
git add -A && git commit -m "Initial deploy" && git push
```

Verify your services are running:

```bash
curl -I https://yourdomain.com
```

You should see a response from Traefik routing to your services through Cloudflare Tunnel.

## Step 5: Add your first app

The stack template README documents how to add compose stacks for new services. The general pattern:

1. Create a compose file in `stacks/`
2. Add Traefik labels for routing
3. Push to `main` — GitHub Actions deploys automatically

See the [stack template documentation](https://github.com/tianshanghong/miuops-stack-template) for compose patterns and examples.

## Troubleshooting

### Tunnel not connecting

```bash
# Check cloudflared service on the server
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -f
```

### Services not reachable

```bash
# Check Traefik and your stacks on the server
docker ps
docker compose -f /path/to/stack/compose.yml logs -f
```

### Playbook fails on a specific role

Re-run with the role tag to isolate the issue:

```bash
ansible-playbook playbook.yml --tags firewall
ansible-playbook playbook.yml --tags docker
ansible-playbook playbook.yml --tags traefik
ansible-playbook playbook.yml --tags cloudflared
```
