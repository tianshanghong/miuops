# Disaster Recovery

Procedures for restoring services after failures. The backup system is a host-side
Docker-volume backup (volume tarballs) writing to a single S3 bucket with Object Lock
protection. Databases are outsourced to managed Postgres — miuOps does not back them
up; recover a database through your managed provider's point-in-time recovery.

## Backup architecture

```
S3 bucket: {project}-backup
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
| `SSH_KNOWN_HOSTS` | Re-pin new host keys after comparing fingerprints with the server console; ssh-keyscan alone is not verification |

The app `.env` lives on the **server** at `/opt/stacks/.env` (provisioned locally from the
SOPS-encrypted `fleet/secrets/<server>.env`, never a GitHub secret) — restore it on the
rebuilt server as in [INSTALLATION.md](INSTALLATION.md).

### 5. Deploy stacks

Push to your fleet repo's `main` branch (or re-run the last workflow):

```bash
# From your fleet repo
git commit --allow-empty -m "Redeploy to new server" && git push
```

### 6. Restore volume data

See [Scenario 3](#scenario-3-volume-data-restore) below. (Databases are managed
externally — recover them via your managed Postgres provider's point-in-time recovery.)

## Scenario 2: Database recovery

Databases are outsourced to managed Postgres; miuOps does not back them up. Recover the
database through your managed provider's point-in-time recovery (see the provider's
runbook) — the app reconnects automatically via `DATABASE_URL`.

## Scenario 3: Volume data restore

Restore Docker volume data from the host-side volume tarballs stored in S3. Run all commands **on the server** — download directly from S3 to avoid double-transferring large backups through your laptop.

Each Docker volume has its own prefix (`vol/{volume}/`), and each run uploads one
tarball keyed by UTC timestamp. The tar is rooted at the volume's contents (it is created with
`tar -C "$(docker volume inspect <volume> --format '{{.Mountpoint}}')" --numeric-owner -cf - .`
— the daemon's real `_data` mountpoint, which `userns-remap` relocates under
`/var/lib/docker/<subuid>.<subgid>/volumes/`), so it extracts directly into the target
volume's root — there is no wrapper
directory. The archive is **not gzip-compressed** (extract with `tar -xf`, not
`-xzf`). The safe restore command ignores archive ownership. Apply trusted application
UIDs/GIDs explicitly rather than trusting backup headers or the host user database.

> **Check a backup is intact without restoring it:**
> `miuops backup-verify --server SERVER --volume VOLUME_NAME [--at <ts>]` streams the
> object through an integrity check and exits non-zero on corruption. Run it
> periodically — `aws s3 cp` already checks the upload, so this confirms a backup is
> still good (and decryptable with the current key) months later. **Strength depends on
> the format:** an **age** object is fully byte-level verified (its MAC authenticates
> every byte); a **plaintext `.tar`** is only structurally verified (`tar -t` — the
> per-header checksum, catching header damage but **not** a flipped data byte or
> trailing-data truncation that leaves the headers parseable, as uncompressed tar has no
> body checksum). For byte-level integrity, set `backup_encryption: age`. *Backups that haven't been verified aren't backups.*

**1. Restore the volume's data to a staging directory.** `miuops backup-restore`
resolves the bucket from your fleet config, finds the volume's object (the latest, or
`--at <ts>`), downloads it, decrypts it (age) with your operator identity, and untars
it into an empty `--target`. Use an unprivileged account with Python 3.9+.
File contents and contained links are restored. Archive UID/GID and extended
metadata are not applied. Safe directory read/search permissions are retained,
with owner access ensured for recovery and cleanup. setuid/setgid entries, devices, FIFOs,
links outside the target, dangling links and link chains are rejected. The staging
directory is private (0700); ordinary files lose group/world write permissions.

```bash
miuops backup-restore --server SERVER --volume VOLUME_NAME --target ./restored
#   --at 20260629T030000Z    # an exact backup; omit for the latest encrypted one
#   --allow-plaintext        # explicit opt-in for legacy unencrypted backups
```

Download, decryption and extraction errors abort recovery and wipe the partial
target. Plaintext tar has no authenticated content checksum. Neither successful age
decryption nor S3 Object Lock proves who produced a backup: verify the selected
object/version against a trusted recovery record, especially after a key compromise. Decryption uses your age
identity (`SOPS_AGE_KEY_FILE` / default `keys.txt` / a plugged-in YubiKey); the host
only ever held the public recipient. List what is available first with
`aws s3 ls s3://PROJECT-backup/SERVER/vol/VOLUME_NAME/ --region REGION` if needed.

**2. Stop the consumers of the volume:**

```bash
docker stop CONTAINER [CONTAINER...]
```

**3. Replace the volume's contents with the restored data.** Set the intended
UID/GID from trusted application configuration (inside the container namespace,
so Docker userns-remap applies). Replace APP_UID and APP_GID below with those
numeric IDs. For a volume with multiple owners, apply a trusted ownership mapping
instead of the single-owner example. Do not infer ownership from archive headers:

```bash
# Stream from private staging; remapped container root cannot read a 0700 host bind.
set -o pipefail
tar -C restored -cf - . | docker run --rm -i -v VOLUME_NAME:/v alpine \
  sh -ec 'find /v -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar -xof - -C /v; chown -R "$1:$2" /v' sh APP_UID APP_GID
```

**4. Restart the consumers:**

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
2. writes it into `fleet/secrets/<server>.vars.json` (host volume backups),
   SOPS-encrypted, merged not clobbered;
3. runs `miuops apply <server>` to push the new key to the host;
4. and **only after that apply succeeds** deletes the old key.

The host volume backup reloads `backup.env` on every (oneshot) run, so it uses the new
key immediately on its next scheduled backup — nothing else to redeploy.

If the apply fails it stops **before** the delete, so the server keeps a working key
— re-run `miuops apply <server>`, then the old key can be removed. It refuses unless
the IAM user has exactly one key, so a rotation is never ambiguous. Commit the updated
`fleet/secrets/<server>.*` afterward.

### Verify

```bash
# Trigger the host volume backup and confirm it runs clean with the new key
ssh user@server "systemctl start miuops-backup.service && journalctl -u miuops-backup.service -n 20 --no-pager"
```

## Testing backups

Backups that haven't been tested are not backups. Periodically verify:

1. **Volume backup list** — Confirm recent volume tarballs exist in S3 (one
   prefix per volume):
   ```bash
   aws s3 ls s3://PROJECT-backup/<server>/vol/ --recursive --region REGION
   ```
   You can also trigger a run on demand and watch it:
   ```bash
   systemctl start miuops-backup.service
   journalctl -u miuops-backup.service -f
   ```

2. **Object Lock verification** — Confirm backups cannot be deleted:
   ```bash
   aws s3api get-object-lock-configuration --bucket PROJECT-backup --region REGION
   ```
