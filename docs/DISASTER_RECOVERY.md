# Disaster Recovery

Procedures for restoring services after failures. The backup system uses WAL-G (PostgreSQL continuous archiving) and a host-side Docker-volume backup (volume tarballs), both writing to a single S3 bucket with Object Lock protection.

## Backup architecture

```
S3 bucket: {project}-backup
├── db/                          # WAL-G: base backups + WAL segments
│   ├── basebackups_005/
│   └── wal_005/
└── vol/                         # host-side volume tarballs (backup role)
    └── {volume}/                #   one prefix per Docker volume
        └── backup-YYYYMMDDTHHMMSSZ.tar[.age]
```

- **Volume tarballs** are produced by the Ansible `backup` role: a host `systemd`
  timer stops each volume's writers, tars the volume, optionally encrypts it, and
  streams it to S3. One object per volume per run, keyed by UTC timestamp.
  See [roles/backup/README.md](../roles/backup/README.md).
- **Object Lock** (Governance, 30 days) prevents deletion of any backup
- **Lifecycle**: transition to Glacier at 30 days, expire at 90 days
- **IAM policy**: PutObject + GetObject + ListBucket only (no DeleteObject); the
  backup job never deletes — retention is enforced by S3 alone

## Scenario 1: Full server rebuild

The server is lost. You need a new machine running the same services with restored data.

### 1. Provision a new server

Ensure SSH access from your control machine. The server must run Debian or Ubuntu.

### 2. Restore this host's config

Edit `fleet/inventory.ini` with the new server's IP and SSH user:

```ini
[bare_metal]
server1 ansible_host=NEW_IP ansible_user=admin
```

Ensure `fleet/host_vars/server1.yml` (its `domains` + `tunnel_id`) exists and the
SOPS-encrypted tunnel credential `fleet/secrets/<tunnel_id>.json` is committed (reuse the
same tunnel ID — no need to recreate it in Cloudflare; it is decrypted locally and pushed to
the server at deploy).

### 3. Run the bootstrap playbook

```bash
ansible-playbook playbook.yml --limit server1
```

This installs Docker, Traefik, cloudflared, and the firewall — same as initial
setup. (`--limit server1` scopes the run to the rebuilt host; omit it to converge
the whole fleet.)

### 4. Update the server's deploy environment secrets

In your fleet repo, open the per-server GitHub Environment (Settings > Environments >
`<server>`) and update:

| Secret | New value |
|---|---|
| `SSH_HOST` | New server IP or hostname |
| `SSH_USER` | New SSH user (if changed) |
| `SSH_PRIVATE_KEY` | New SSH private key (if changed) |
| `SSH_KNOWN_HOSTS` | Re-pin the new host keys (`ssh-keyscan -p <port> <host>`) — a rebuilt server has new host keys |

The app `.env` lives on the **server** at `/opt/stacks/.env` (provisioned locally from the
SOPS-encrypted `fleet/secrets/<server>.env`, never a GitHub secret) — restore it on the
rebuilt server as in [INSTALLATION.md](INSTALLATION.md).

### 5. Deploy stacks

Push to your fleet repo's `main` branch (or re-run the last workflow):

```bash
# From your fleet repo
git commit --allow-empty -m "Redeploy to new server" && git push
```

### 6. Restore PostgreSQL from WAL-G

See [Scenario 2](#scenario-2-postgresql-point-in-time-recovery) below.

### 7. Restore volume data

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

Restore Docker volume data from the host-side volume tarballs stored in S3. Run all commands **on the server** — download directly from S3 to avoid double-transferring large backups through your laptop.

Each Docker volume has its own prefix (`vol/{volume}/`), and each run uploads one
tarball keyed by UTC timestamp. The tar is rooted at the volume's contents (it is created with
`tar -C "$(docker volume inspect <volume> --format '{{.Mountpoint}}')" --numeric-owner -cf - .`
— the daemon's real `_data` mountpoint, which `userns-remap` relocates under
`/var/lib/docker/<subuid>.<subgid>/volumes/`), so it extracts directly into the target
volume's root — there is no wrapper
directory. The archive is **not gzip-compressed** (extract with `tar -xf`, not
`-xzf`). Extract with `--numeric-owner` too (below) so UIDs/GIDs are restored as
numbers — deterministic ownership even when the restore host has a different
`/etc/passwd` than the source.

**1. List backups for the volume:**

```bash
aws s3 ls s3://PROJECT-backup/<server>/vol/VOLUME_NAME/ --region REGION
```

If encrypted, files have a `.age` extension (e.g. `backup-YYYYMMDDTHHMMSSZ.tar.age`).

**2. Download the backup:**

```bash
# Unencrypted
aws s3 cp s3://PROJECT-backup/<server>/vol/VOLUME_NAME/backup-YYYYMMDDTHHMMSSZ.tar . --region REGION

# Encrypted (include the .age extension)
aws s3 cp s3://PROJECT-backup/<server>/vol/VOLUME_NAME/backup-YYYYMMDDTHHMMSSZ.tar.age . --region REGION
```

**3. Decrypt the backup (if encrypted):**

```bash
# age (asymmetric — identity file, SSH private key, or YubiKey-backed identity)
age --decrypt -i key.txt -o backup-YYYYMMDDTHHMMSSZ.tar backup-YYYYMMDDTHHMMSSZ.tar.age
```

Install age with `apt install age` (Debian/Ubuntu) or download it from
[github.com/FiloSottile/age](https://github.com/FiloSottile/age). The role
encrypts to a public key only, so decryption needs the matching private key or
identity file — transfer it to the server temporarily and remove it afterward, or
keep the key off the host and decrypt on your laptop while streaming the plaintext
over SSH (see [Backup Encryption](BACKUP_ENCRYPTION.md)). For a YubiKey-backed
recipient, decrypt where the key is plugged in, with `age-plugin-yubikey`
installed.

**4. Stop the consumers of the volume:**

```bash
docker stop CONTAINER [CONTAINER...]
```

**5. Extract into the target volume:**

`--numeric-owner` keeps the restored files' UIDs/GIDs as numbers, so ownership is
correct even when this host's `/etc/passwd` differs from the source host's.

```bash
docker run --rm \
  -v VOLUME_NAME:/restore \
  -v "$(pwd)/backup-YYYYMMDDTHHMMSSZ.tar:/backup.tar:ro" \
  alpine sh -c "cd /restore && tar --numeric-owner -xf /backup.tar"
```

To restore into a clean volume, clear it first (inside the same `alpine` shell:
`rm -rf /restore/* /restore/..?* 2>/dev/null; tar --numeric-owner -xf /backup.tar`).

**6. Restart the consumers:**

```bash
docker start CONTAINER [CONTAINER...]
```

### Notes on the backup job (`stop` list, downtime, restart policy)

- A container listed in a volume's `stop` is **down for that whole volume's**
  stop + tar + encrypt + upload + restart — a window proportional to
  **volume size ÷ upload bandwidth**, not seconds. Don't put a large,
  customer-facing writer volume in `stop` expecting sub-minute downtime; use a
  snapshot/replication approach for those instead.
- Give every backed-up container `restart: unless-stopped`. The backup script's
  trap restarts containers it stopped, but it **cannot** catch `SIGKILL` or a
  host reboot mid-backup; with `restart: unless-stopped`, Docker brings the
  container back on its own after such an event.
- A failure on one volume no longer aborts the run: the job restarts that
  volume's containers, logs the error, continues with the remaining volumes, and
  exits non-zero at the end. Check `journalctl -u miuops-backup.service` for any
  per-volume `ERROR` lines after a non-zero run.

## Scenario 4: Credential rotation

If a server's AWS backup key is compromised (or on a routine schedule), rotate it
with one command from your fleet repo:

```bash
miuops backup-rotate --server <server>
```

`miuops backup-rotate` does the whole dance safely:

1. mints a new access key for the server's scoped IAM user;
2. writes it into `fleet/secrets/<server>.vars.json` (host volume backups) **and**,
   if the server runs WAL-G, syncs it into `fleet/secrets/<server>.env` (the stack
   env WAL-G reads) — both SOPS-encrypted, merged not clobbered;
3. runs `miuops apply <server>` to push the new key to the host;
4. and **only after that apply succeeds** deletes the old key.

Because both credential locations are updated and pushed *before* the old key is
deleted, neither the host volume backup nor WAL-G is ever stranded on a dead key.
If the apply fails it stops **before** the delete, so the server keeps a working key
— re-run `miuops apply <server>`, then the old key can be removed. It refuses unless
the IAM user has exactly one key, so a rotation is never ambiguous. Commit the
updated `fleet/secrets/<server>.*` afterward.

### Verify

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

3. **Volume backup list** — Confirm recent volume tarballs exist in S3 (one
   prefix per volume):
   ```bash
   aws s3 ls s3://PROJECT-backup/<server>/vol/ --recursive --region REGION
   ```
   You can also trigger a run on demand and watch it:
   ```bash
   systemctl start miuops-backup.service
   journalctl -u miuops-backup.service -f
   ```

4. **Object Lock verification** — Confirm backups cannot be deleted:
   ```bash
   aws s3api get-object-lock-configuration --bucket PROJECT-backup --region REGION
   ```
