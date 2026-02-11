# Installation Guide

End-to-end walkthrough: from bare server to running services. For a condensed version, see the [README Quick Start](../README.md#quick-start).

## Prerequisites

| Requirement | Purpose |
|---|---|
| Cloudflare account with your domain | DNS, CDN, WAF |
| Cloudflare API token (Zone:DNS:Edit) | Ansible creates DNS records |
| Server with SSH access (Debian/Ubuntu) | Target machine |
| Ansible >= 2.10 on your local machine | Runs the bootstrap playbook |
| aws CLI (configured with admin credentials) | Backup bucket setup |

### Create a Cloudflare API token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) > My Profile > API Tokens
2. Click **Create Token**
3. Use the **Edit zone DNS** template (or create a custom token with Zone:DNS:Edit)
4. Scope it to the zone(s) you'll use
5. Save the token — you'll need it for `group_vars/all.yml`

### Install Ansible

```bash
# macOS
brew install ansible

# Ubuntu/Debian
sudo apt update && sudo apt install ansible

# pip
pip install ansible
```

### Install aws CLI

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

### Clone this repository

```bash
git clone https://github.com/tianshanghong/miuops
cd miuops
```

### Install Ansible requirements

```bash
ansible-galaxy collection install -r requirements.yml
```

### Configure inventory

```bash
cp inventory.ini.template inventory.ini
```

Edit `inventory.ini` with your server details:

```ini
[bare_metal]
server1 ansible_host=192.0.2.10 ansible_user=admin
```

### Configure variables

```bash
cp group_vars/all.yml.template group_vars/all.yml
```

Edit `group_vars/all.yml`:

```yaml
ssh_port: 22

domains:
  - domain: "example.com"
    zone_id: "your_cloudflare_zone_id"

cf_api_token: "your_cloudflare_api_token"
tunnel_id: ""           # filled after tunnel creation
# credentials_file defaults to /opt/cloudflared/{{ tunnel_id }}.json
```

### Create a Cloudflare Tunnel

```bash
./scripts/create-tunnel.sh
```

The script will:
1. Ensure `cloudflared` and `jq` are installed
2. Log in to Cloudflare (if needed)
3. Create a tunnel and download credentials to `files/`
4. Output the tunnel ID and domain

Copy the tunnel ID and credentials file path into `group_vars/all.yml`:

```yaml
tunnel_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# credentials_file is derived from tunnel_id automatically
```

### Check prerequisites

```bash
./scripts/check-prereqs.sh
```

### Run the playbook

```bash
ansible-playbook playbook.yml
```

This provisions the server with:
- **iptables firewall** — default-DROP on INPUT and DOCKER-USER chains, rate-limited SSH
- **Docker CE + Compose** — hardened daemon (ICC disabled, userland proxy disabled)
- **Traefik directories + Docker network** — ready for compose deployment
- **cloudflared** — systemd service, wildcard + root CNAME DNS records

## Step 2: Set up backups

```bash
./scripts/setup-s3-backup.sh
```

The script prompts for a project name and AWS region (default: `us-west-2`), then creates:
- S3 bucket `{project}-backup` with Object Lock (Compliance, 30 days)
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
   | `ENV_FILE` | Contents of your `.env` file (see below) |

3. Clone your stack repo and fill in `.env` from `.env.example`:

   ```bash
   git clone https://github.com/yourorg/yourstack
   cd yourstack
   cp .env.example .env
   ```

   The `.env` file includes domains, backup credentials (from Step 2), and service-specific variables. See the stack template README for the full variable reference.

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
