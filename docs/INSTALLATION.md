# Installation Guide

End-to-end walkthrough: from bare server to running services. For a condensed version, see the [README Quick Start](../README.md#quick-start).

## Prerequisites

| Requirement | Purpose |
|---|---|
| Cloudflare account with your domain(s) | DNS, CDN, WAF |
| Cloudflare API token | DNS records — zone lookup + CNAME management (scope to all zones you'll use) |
| Server with SSH access (Debian/Ubuntu) | Target machine |
| Local tools: `ansible`, `cloudflared`, `jq`, `curl`, `ssh` | The CLI checks these and guides you |
| aws CLI (configured with admin credentials) | Backup bucket setup (Step 2) |

### Create a Cloudflare API token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) > My Profile > [API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template
4. Scope it to the zone(s) you'll use
5. Save the token — you'll pass it as `CF_API_TOKEN` when running `miuops up`

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

## Step 1: Create your fleet repo

Go to **[miuops-fleet-template](https://github.com/tianshanghong/miuops-fleet-template)**,
click **Use this template** > **Create a new repository** (private), then clone it. This is
your fleet repo — it describes every server you run (`fleet/inventory.ini`,
`fleet/host_vars/<server>.yml`, encrypted `fleet/secrets/`, and per-server stacks under
`fleet/stacks/<server>/<stack>/`) and consumes miuOps as a dependency.

Install the `miuops` CLI locally (clone [miuops](https://github.com/tianshanghong/miuops) and
put it on your `PATH`, or symlink the `miuops` script). The CLI reads the fleet config from the
fleet repo's working directory.

## Step 2: Bootstrap the server

From your fleet repo root, run the CLI with your Cloudflare token and the domains this server
serves:

```bash
# Single domain
CF_API_TOKEN=your_token miuops up root@203.0.113.10 example.com

# Multiple domains
CF_API_TOKEN=your_token miuops up root@203.0.113.10 example.com example.org
```

The CLI handles everything:
1. Checks prerequisites (and tells you how to install any that are missing)
2. Looks up the Cloudflare Zone ID for each domain
3. Creates a Cloudflare Tunnel (or reuses an existing one)
4. Creates DNS CNAME records for all domains (Cloudflare API)
5. Writes `fleet/inventory.ini` and `fleet/host_vars/<server>.yml` (plaintext config), and
   stores the tunnel credential SOPS-encrypted at `fleet/secrets/<tunnel_id>.json`
6. Installs Ansible Galaxy dependencies
7. Runs the playbook

The playbook provisions the server with:
- **ufw firewall** — default-deny inbound, only rate-limited SSH open
- **Docker CE + Compose** — hardened daemon (loopback-published ports, `userns-remap`, ICC off, API never on TCP)
- **Traefik** — non-root host binary reading Docker via a read-only socket-proxy
- **cloudflared** — systemd service with tunnel config for all domains
- **SSH hardening** — key-only login (`PasswordAuthentication no`)
- **Metadata block** — containers blocked from the cloud metadata endpoint
- **Unattended security upgrades** — automatic, no auto-reboot

### Dry run

Preview what would happen without making changes:

```bash
CF_API_TOKEN=your_token miuops up --dry-run root@203.0.113.10 example.com example.org
```

### Manual setup (alternative)

If you prefer to configure things manually instead of using the CLI, edit the fleet repo's
`fleet/` config directly:

<details>
<summary>Click to expand manual steps</summary>

```bash
# Install Ansible requirements
ansible-galaxy collection install -r requirements.yml

# Configure (in your fleet repo)
# Add the server's line to fleet/inventory.ini (the host alias)
# Create fleet/host_vars/<server>.yml with that host's domains and tunnel ID

# Create Cloudflare Tunnel (handled automatically by miuops up)
cloudflared tunnel create miuops-203-0-113-10
# Create DNS CNAME records in Cloudflare dashboard for each domain:
#   example.com     -> <tunnel-id>.cfargotunnel.com (Proxied)
#   *.example.com   -> <tunnel-id>.cfargotunnel.com (Proxied)
# SOPS-encrypt the tunnel credential JSON to fleet/secrets/<tunnel_id>.json

# Bootstrap server
ansible-playbook playbook.yml
```

</details>

## Step 3: Set up backups

```bash
./scripts/setup-s3-backup.sh
```

The script prompts for a project name and AWS region (default: `us-west-2`), then creates:
- S3 bucket `{project}-backup` with Object Lock (Governance, 30 days)
- Lifecycle rules: transition to Glacier at 30 days, expire at 90 days
- IAM user with PutObject/GetObject/ListBucket only (no Delete)
- Access key credentials

One bucket serves the whole fleet; each server backs up under its own
`<server>/` prefix (`<server>/db/…` for WAL-G, `<server>/vol/…` for volume
tarballs), with a per-server prefix-scoped IAM user so a compromised server can
touch only its own backups.

Save the output — you'll need `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, and the bucket name for the server's encrypted
`fleet/secrets/<server>.env`.

## Step 4: Wire the deploy environment and app secrets

Each server deploys through its own [GitHub Environment](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment),
so a compromised or buggy deploy holds only that one server's key — no lateral movement.

1. **Generate a deploy keypair and install only the public half.** You generate the keypair
   (`ssh-keygen`); the tool installs the **public** key into the deploy user's
   `authorized_keys`. The tool never handles a private key.

2. **Create a per-server GitHub Environment** named after the server handle (e.g. `server-01`,
   matching `fleet/inventory.ini`), and set these environment secrets (Settings > Environments):

   | Secret | Required | Value |
   |--------|----------|-------|
   | `SSH_HOST` | Yes | Server IP or hostname |
   | `SSH_USER` | Yes | SSH username (the deploy user) |
   | `SSH_PRIVATE_KEY` | Yes | The deploy **private** key (full PEM) |
   | `SSH_PORT` | No | SSH port (default: 22) |
   | `SSH_KNOWN_HOSTS` | No | Pinned host keys (`ssh-keyscan -p <port> <host>`); set it for production |

   The deploy workflow targets `environment: <server>`, so each server reads only its own
   environment's secrets.

3. **Fill in app secrets, encrypted.** Copy the env template, fill in real values (domains,
   backup credentials from Step 3, and service-specific variables), encrypt it in place with
   SOPS, and commit the ciphertext:

   ```bash
   cp .env.example fleet/secrets/server-01.env
   #   …edit fleet/secrets/server-01.env…
   sops -e -i fleet/secrets/server-01.env
   git add fleet/secrets/server-01.env
   ```

   The encrypted file is committed; it is unreadable without your age key. The age key never
   enters CI — SOPS decryption happens locally at setup, and the per-server `.env` is installed
   to `/opt/stacks/.env` on the server (the deploy excludes it from the sync).

## Step 5: Deploy

Push to `main` to trigger the GitHub Actions deploy pipeline:

```bash
git add -A && git commit -m "Initial deploy" && git push
```

The caller workflow invokes the miuOps reusable `deploy.yml`, which discovers the servers whose
stacks changed and syncs each changed server's `fleet/stacks/<server>/` over SSH. Verify your
services are running:

```bash
curl -I https://yourdomain.com
```

You should see a response from Traefik routing to your services through Cloudflare Tunnel.

## Step 6: Add your first app

The fleet template README documents how to add compose stacks for new services. The general
pattern:

1. Create a compose file at `fleet/stacks/<server>/<stack>/docker-compose.yml`
2. Add Traefik labels for routing
3. Push to `main` — GitHub Actions deploys automatically

See the [fleet template documentation](https://github.com/tianshanghong/miuops-fleet-template) for compose patterns and examples.

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
