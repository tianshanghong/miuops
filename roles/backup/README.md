# roles/backup

Host-side, **stop-consistent** Docker volume backup to S3. A host `systemd`
timer runs a bash script that, for each configured volume:

1. stops the volume's writing containers (so the on-disk data is at rest),
2. streams a `tar` of the volume through optional client-side encryption
   **straight to S3** (nothing staged on local disk),
3. restarts the containers.

There is no backup container and nothing mounts the Docker socket into a
container. The job runs as a host process using the host's own `docker` CLI.

Opt-in per host. The whole role is a no-op unless `backup_enabled: true`.

## What it is (and isn't) for

Use it for the **volumes around** your apps — uploads, content directories,
config volumes, caches. For PostgreSQL, prefer a log-shipping tool such as
WAL-G (continuous archiving) and leave its data volume out of this list; a
stop-the-world tar of a live database volume is a crash-consistent snapshot at
best. This job's strength is that it can take an at-rest snapshot by stopping
the writer first.

## Quick start

1. Create the shared S3 bucket + this server's scoped IAM user (Object Lock +
   lifecycle): `scripts/setup-s3-backup.sh --server <server>` (one bucket is
   shared by the whole fleet and with WAL-G; each server gets its own prefix +
   IAM user — see the repo README and the **Fleet isolation** section below).
2. Export the AWS **credentials** (the two secrets) in the shell you run miuOps from:

   ```bash
   export AWS_ACCESS_KEY_ID=AKIA...
   export AWS_SECRET_ACCESS_KEY=...
   ```

   The region is **config, not a secret** — set `backup_aws_region` in host_vars
   (step 3; it defaults to `us-west-2`), not via the environment.

3. Configure the host in `host_vars/<host>.yml` (see schema below).
4. Apply: `./miuops apply <host>` (or `ansible-playbook playbook.yml --tags backup --limit <host>`).

## Configuration (host_vars schema)

| Variable | Default | Description |
|---|---|---|
| `backup_enabled` | `false` | Master switch. Role is a no-op when false. |
| `backup_volumes` | `[]` | List of `{ name, stop }` items (below). |
| `backup_s3_bucket` | `""` | Destination bucket name (no `s3://`). One bucket for the whole fleet. Required. |
| `backup_s3_prefix` | `"{{ inventory_hostname }}/vol"` | Key prefix, rooted at this server's name. Objects land under `<server>/vol/<volume>/`. Must start with `<inventory_hostname>/` (the role asserts it). |
| `backup_schedule` | `"*-*-* 02:00:00"` | systemd `OnCalendar` expression. |
| `backup_randomized_delay_sec` | `"45m"` | `RandomizedDelaySec` to smear the start. |
| `backup_encryption` | `"none"` | `none` \| `age`. |
| `backup_age_recipients` | `[]` | age recipients (`age1...`, `ssh-ed25519`/`ssh-rsa`, or `age1yubikey1...`). |
| `backup_aws_access_key_id` | env `AWS_ACCESS_KEY_ID` | AWS key. Keep env-only. |
| `backup_aws_secret_access_key` | env `AWS_SECRET_ACCESS_KEY` | AWS secret. Keep env-only. |
| `backup_aws_region` | `us-west-2` | AWS region. **Config** — set in host_vars (not env). |
| `backup_s3_endpoint_url` | `""` | Optional S3-compatible endpoint override. |

Each `backup_volumes` item:

```yaml
- name: <docker volume name as shown by `docker volume ls`>
  stop: [<container names to stop before archiving, restart after>]   # empty/omit = hot copy
```

### Downtime and the `stop` list — read before listing a volume

A container in a volume's `stop` list is **down for the entire backup of that
volume**: stop + tar + encrypt + upload + restart. That window is proportional to
**volume size ÷ upload bandwidth**, not seconds — a 50 GiB volume on a 100 Mbit/s
uplink is offline for over an hour. Do **not** put a large, customer-facing writer
volume in `stop` and expect sub-minute downtime. For those, prefer a tool that
snapshots without stopping the writer (filesystem/LVM snapshot, or a
log-shipping/replication tool for databases) and leave the volume out of this
list, or accept a hot copy (empty `stop`) if its writer tolerates a fuzzy
snapshot.

**Set `restart: unless-stopped` on every backed-up container.** The script's trap
restarts containers it stopped, but it **cannot** catch `SIGKILL` or a host
reboot mid-backup. With `restart: unless-stopped`, Docker brings the container
back on its own after such an event; without it, a container could be left down
until the next manual intervention.

### Example

```yaml
# host_vars/<host>.yml
backup_enabled: true
backup_s3_bucket: "myfleet-backup"      # one bucket for the whole fleet
backup_aws_region: "us-west-2"          # config (not a secret); defaults to us-west-2
# backup_s3_prefix defaults to "{{ inventory_hostname }}/vol" — leave it unset
# unless you have a reason to change the trailing segment (keep the
# "<server>/" root or the role's assert fails).
backup_schedule: "*-*-* 02:00:00"
backup_encryption: "age"
backup_age_recipients:
  - "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
  # or an SSH public key:
  # - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
backup_volumes:
  - name: app_uploads        # stateful: stop the writer for an at-rest copy
    stop: [app]
  - name: caddy_data         # tolerant of a hot copy: no stop
    stop: []
```

AWS credentials are **not** in host_vars — export them as environment variables
(above) so they stay out of the repo. They are rendered on the host into
`/etc/miuops-backup/backup.env` (mode `0600`, root) and sourced by the script,
so they never appear in `ps` / the process table.

When `backup_age_recipients` includes a YubiKey identity (`age1yubikey1...`), the
role installs **age-plugin-yubikey** on the host automatically (pinned `.deb` +
checksum; amd64 only — `age` cannot encrypt to a plugin recipient without it).
Encryption uses only the public key, so the host needs no YubiKey and the daily
backup runs unattended — the YubiKey is required only to *decrypt* at restore
time, on the operator's machine.

## Files on the host

| Path | Mode | Purpose |
|---|---|---|
| `/usr/local/bin/miuops-backup` | `0700` root | the backup script |
| `/etc/miuops-backup/backup.env` | `0600` root | AWS credentials (sourced) |
| `/etc/miuops-backup/volumes.json` | `0600` root | volume list |
| `/etc/systemd/system/miuops-backup.service` | `0644` | oneshot unit |
| `/etc/systemd/system/miuops-backup.timer` | `0644` | schedule |

## Object naming

```
s3://<bucket>/<server>/vol/<volume>/backup-<UTC ISO8601>.tar[.age]
# e.g. s3://myfleet-backup/web1/vol/app_uploads/backup-20260624T020000Z.tar.age
```

The leading `<server>/` segment is `inventory_hostname` (the same identity used
for `host_vars/<server>.yml` and the GitHub Environment). WAL-G database backups
share the bucket under the symmetric `s3://<bucket>/<server>/db/<app>` prefix.

## Fleet isolation

One S3 bucket serves the whole fleet. Each server gets its own top-level prefix
`<server>/` **and** its own per-server IAM user `"<bucket>-<server>"` (created by
`scripts/setup-s3-backup.sh --server <server>`) whose inline policy is scoped to
that prefix only:

- `s3:ListBucket` on the bucket, **conditioned** to `s3:prefix` `<server>/*`;
- `s3:PutObject` + `s3:GetObject` on `arn:aws:s3:::<bucket>/<server>/*`;
- **no** `s3:DeleteObject`, **no** `s3:*`, **no** explicit `Deny`.

AWS default-deny means a compromised host's key can read/write **only** its own
backups — a `PutObject` to another server's prefix simply matches no `Allow` and
is denied. Immutability is enforced by omitting Delete and by the bucket Object
Lock. (Listing the bucket root from a server key is intentionally denied; an
operator lists their own data with `aws s3 ls s3://<bucket>/<server>/` and uses
an admin profile for a fleet-wide view.)

## Retention

The job **never deletes** anything. Retention is enforced entirely by S3:
Object Lock (Governance, 30 days) blocks deletion and the bucket lifecycle
transitions to Glacier at 30 days and expires at 90. This matches the WAL-G
side and means a compromised host (or a bug here) cannot erase history.

## Operations

```bash
# Trigger a backup now (does not wait for the timer)
systemctl start miuops-backup.service

# Watch it run
journalctl -u miuops-backup.service -f

# When does it next fire?
systemctl list-timers miuops-backup.timer

# What got uploaded? (this server's prefix)
aws s3 ls s3://<bucket>/<server>/vol/ --recursive --region <region>
```

## Restore

Run on the server so large backups download straight from S3 (no laptop
round-trip).

```bash
# 1. Pick a backup
aws s3 ls s3://<bucket>/<server>/vol/<volume>/ --region <region>

# 2. Download it
aws s3 cp s3://<bucket>/<server>/vol/<volume>/backup-<ts>.tar.age . --region <region>

# 3. Decrypt (skip if unencrypted)
#    age (identity file, SSH private key, or YubiKey-backed identity):
age --decrypt -i key.txt -o backup-<ts>.tar backup-<ts>.tar.age

# 4. Stop the consumers, extract into the target volume, restart.
#    --numeric-owner preserves UIDs/GIDs as numbers, so ownership is
#    deterministic even when restoring onto a host with different /etc/passwd.
docker stop <containers>
docker run --rm \
  -v <volume>:/restore \
  -v "$(pwd)/backup-<ts>.tar:/backup.tar:ro" \
  alpine sh -c "cd /restore && tar --numeric-owner -xf /backup.tar"
docker start <containers>
```

The tar is rooted at the volume's contents (created with
`tar -C .../_data --numeric-owner -cf - .`), so it extracts directly into the
target volume root.

See [docs/BACKUP_ENCRYPTION.md](../../docs/BACKUP_ENCRYPTION.md) and
[docs/DISASTER_RECOVERY.md](../../docs/DISASTER_RECOVERY.md) for the full
procedures and encryption key handling (including SSH-key and YubiKey-backed age).

## Why these choices

- **No socket mount / no container.** Mounting `docker.sock` into a container
  grants root-equivalent control of the host to that container. Running the job
  as a host process with the host CLI avoids handing that surface to anything.
- **awscli for upload.** A single small dependency that streams stdin to an
  object (`aws s3 cp - s3://...`), and AWS credentials are already the
  project's convention (shared with WAL-G). No extra config file format to
  template. The Debian/Ubuntu `awscli` package is **v1**, which handles the
  streamed `aws s3 cp - s3://...` upload fine. Note the ceiling: a single
  streamed object is capped at S3's 10 000-part multipart limit, ~**78 GiB** per
  object with the default chunk size. A volume that exceeds that fails **loud**
  (the upload stage returns non-zero, caught by the PIPESTATUS check), it is not
  silently truncated — but it means a very large volume needs a different
  approach (raise the CLI's `multipart_chunksize`, or split/snapshot the volume).
- **Asymmetric encryption only.** The private key never sits on the server, so
  a host compromise yields the backups but not the ability to read them.
- **Stream, never stage.** `tar | encrypt | upload` keeps no plaintext copy on
  disk and needs no scratch space sized to the volume.
