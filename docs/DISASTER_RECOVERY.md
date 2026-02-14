# Disaster Recovery

Procedures for restoring services after failures. The backup system uses WAL-G (PostgreSQL continuous archiving) and offen (Docker volume tarballs), both writing to a single S3 bucket with Object Lock protection.

## Backup architecture

```
S3 bucket: {project}-backup
├── db/                    # WAL-G: base backups + WAL segments
│   ├── basebackups_005/
│   └── wal_005/
└── vol/                   # offen: volume tarballs
    └── backup-YYYYMMDDTHHMMSS.tar.gz
```

- **Object Lock** (Governance, 30 days) prevents deletion of any backup
- **Lifecycle**: transition to Glacier at 30 days, expire at 90 days
- **IAM policy**: PutObject + GetObject + ListBucket only (no DeleteObject)

## Scenario 1: Full server rebuild

The server is lost. You need a new machine running the same services with restored data.

### 1. Provision a new server

Ensure SSH access from your control machine. The server must run Debian or Ubuntu.

### 2. Update inventory

Edit `inventory.ini` with the new server's IP and SSH user:

```ini
[bare_metal]
server1 ansible_host=NEW_IP ansible_user=admin
```

### 3. Run the bootstrap playbook

```bash
ansible-playbook playbook.yml
```

This installs Docker, Traefik, cloudflared, and the firewall — same as initial setup.

### 4. Update GitHub Actions secrets

In your stack repo (Settings > Secrets > Actions), update:

| Secret | New value |
|---|---|
| `SSH_HOST` | New server IP or hostname |
| `SSH_USER` | New SSH user (if changed) |
| `SSH_PRIVATE_KEY` | New SSH private key (if changed) |

`ENV_FILE` stays the same unless credentials changed.

### 5. Deploy stacks

Push to your stack repo's `main` branch (or re-run the last workflow):

```bash
# From your stack repo
git commit --allow-empty -m "Redeploy to new server" && git push
```

### 6. Restore PostgreSQL from WAL-G

See [Scenario 2](#scenario-2-postgresql-point-in-time-recovery) below.

### 7. Restore volume data from offen

See [Scenario 3](#scenario-3-volume-data-restore) below.

## Scenario 2: PostgreSQL point-in-time recovery

Restore the database to its latest state (or a specific point in time) from WAL-G backups.

### Prerequisites

The PostgreSQL container must be running with AWS credentials and `WALG_S3_PREFIX` configured (these come from your `.env` file).

### Procedure

**1. Stop the database container:**

```bash
cd /path/to/stack
docker compose stop postgres
```

**2. Clear the data directory:**

```bash
# Remove existing data from the postgres volume
docker run --rm -v STACK_postgres_data:/var/lib/postgresql/data alpine sh -c "rm -rf /var/lib/postgresql/data/*"
```

Replace `STACK_postgres_data` with your actual volume name (`docker volume ls` to check).

**3. Fetch the latest base backup:**

```bash
docker compose run --rm -e PGDATA=/var/lib/postgresql/data postgres \
  wal-g backup-fetch /var/lib/postgresql/data LATEST
```

To restore a specific backup, replace `LATEST` with the backup name from `wal-g backup-list`.

**4. List available backups (optional):**

```bash
docker compose run --rm postgres wal-g backup-list
```

**5. Configure WAL replay:**

```bash
docker run --rm -v STACK_postgres_data:/var/lib/postgresql/data alpine sh -c "
  touch /var/lib/postgresql/data/recovery.signal
  cat >> /var/lib/postgresql/data/postgresql.auto.conf << 'EOF'
restore_command = 'wal-g wal-fetch %f %p'
EOF
"
```

For point-in-time recovery to a specific timestamp, add:

```bash
docker run --rm -v STACK_postgres_data:/var/lib/postgresql/data alpine sh -c "
  cat >> /var/lib/postgresql/data/postgresql.auto.conf << 'EOF'
recovery_target_time = '2025-01-15 14:30:00 UTC'
recovery_target_action = 'promote'
EOF
"
```

**6. Start the database:**

Start via `docker compose` (not bare `docker run`) so WAL-G picks up the AWS credentials from the compose environment:

```bash
docker compose up -d postgres
```

**7. Verify recovery:**

```bash
docker compose logs -f postgres
# Look for: "database system is ready to accept connections"

docker compose exec postgres psql -U postgres -c "SELECT pg_is_in_recovery();"
# Should return 'f' (false) after recovery completes
```

## Scenario 3: Volume data restore

Restore Docker volume data from offen backup tarballs stored in S3. Run all commands **on the server** — download directly from S3 to avoid double-transferring large backups through your laptop.

**1. List available backups:**

```bash
aws s3 ls s3://PROJECT-backup/vol/ --region REGION
```

If encrypted, files will have a `.gpg` or `.age` extension (e.g. `backup-YYYYMMDDTHHMMSS.tar.gz.gpg`).

**2. Download the backup:**

```bash
# Unencrypted
aws s3 cp s3://PROJECT-backup/vol/backup-YYYYMMDDTHHMMSS.tar.gz . --region REGION

# Encrypted (include the .gpg or .age extension)
aws s3 cp s3://PROJECT-backup/vol/backup-YYYYMMDDTHHMMSS.tar.gz.gpg . --region REGION
```

**3. Decrypt the backup (if encrypted):**

```bash
# GPG (symmetric or asymmetric)
gpg --decrypt backup-YYYYMMDDTHHMMSS.tar.gz.gpg > backup-YYYYMMDDTHHMMSS.tar.gz

# Age (symmetric — passphrase)
age --decrypt -o backup-YYYYMMDDTHHMMSS.tar.gz backup-YYYYMMDDTHHMMSS.tar.gz.age

# Age (asymmetric — identity file)
age --decrypt -i key.txt -o backup-YYYYMMDDTHHMMSS.tar.gz backup-YYYYMMDDTHHMMSS.tar.gz.age
```

If using Age: `apt install age` (Debian/Ubuntu) or download from [github.com/FiloSottile/age](https://github.com/FiloSottile/age). GPG is pre-installed on most systems. For asymmetric methods, you'll need the private key or identity file — transfer it to the server temporarily and remove it after decryption.

See [Backup Encryption](BACKUP_ENCRYPTION.md) for details on each method.

**4. Stop the affected services:**

```bash
cd /path/to/stack
docker compose stop
```

**5. Extract to the target volume:**

```bash
docker run --rm \
  -v STACK_volume_name:/restore \
  -v $(pwd)/backup-YYYYMMDDTHHMMSS.tar.gz:/backup.tar.gz \
  alpine sh -c "cd /restore && tar xzf /backup.tar.gz"
```

**6. Restart services:**

```bash
docker compose up -d
```

**Note:** The `.env` file (containing all secrets) is included in the backup tarball under `dotenv/.env`. If you need to recover it, extract it from the tarball:

```bash
tar xzf backup-YYYYMMDDTHHMMSS.tar.gz dotenv/.env
```

## Scenario 4: Credential rotation

If an AWS access key is compromised, rotate it immediately.

### 1. Create a new access key

```bash
aws iam create-access-key --user-name PROJECT-backup
```

Save the new `AccessKeyId` and `SecretAccessKey`.

### 2. Delete the old key

```bash
aws iam delete-access-key --user-name PROJECT-backup --access-key-id OLD_KEY_ID
```

### 3. Update the stack repo

Update your `.env` file with the new credentials:

```
AWS_ACCESS_KEY_ID=new_key_id
AWS_SECRET_ACCESS_KEY=new_secret_key
```

Update the `ENV_FILE` secret in GitHub Actions (Settings > Secrets > Actions) with the new `.env` contents.

### 4. Redeploy

Push to `main` (or re-run the deploy workflow) so containers pick up the new credentials:

```bash
git commit --allow-empty -m "Rotate AWS credentials" && git push
```

### 5. Verify

```bash
# Check that backups still work
ssh user@server "docker compose -f /path/to/stack/compose.yml exec postgres walg-backup.sh"
```

## Testing backups

Backups that haven't been tested are not backups. Periodically verify:

1. **WAL-G backup list** — Confirm recent base backups exist:
   ```bash
   docker compose exec postgres wal-g backup-list
   ```

2. **WAL-G restore test** — Spin up a throwaway container from the latest backup and run a query against it.

3. **offen backup list** — Confirm volume tarballs exist in S3:
   ```bash
   aws s3 ls s3://PROJECT-backup/vol/ --region REGION
   ```

4. **Object Lock verification** — Confirm backups cannot be deleted:
   ```bash
   aws s3api get-object-lock-configuration --bucket PROJECT-backup --region REGION
   ```
