# Backup Encryption

Client-side encryption for the host-side Docker volume backups (the Ansible
`backup` role). The volume's tar stream is encrypted **before** it is uploaded to
S3, so backups are unreadable even if AWS credentials — or the objects
themselves — are compromised.

## Why encrypt backups?

- **Defense in depth**: S3 has server-side encryption (SSE-S3), but a compromised AWS credential can still read objects. Client-side encryption adds a second layer that the cloud provider's keys do not unlock.
- **Secrets in backups**: A backed-up volume may contain secrets, tokens, or personal data. Without encryption, anyone with S3 read access sees it in the clear.
- **Compliance**: Some environments require data-at-rest encryption under the application's control, not just the cloud provider's.

## How it works

The backup script pipes the volume tar through an encryption stage before the
upload: `tar → age → aws s3 cp`. Nothing is staged on disk and no plaintext copy
is written anywhere. Encrypted objects get a `.age` extension; the object key is
`vol/<volume>/backup-<UTC>.tar[.age]`.

Encryption is selected with `backup_encryption` in host_vars (`none` | `age`).
The `age` mode is **asymmetric (public-key) by design**: only a public key (the
recipient) lives on the server, so a host compromise yields the backups but not
the means to decrypt them. There is deliberately no passphrase-on-the-server
mode — a key the server holds is a key an attacker who owns the server also
holds.

## age (`backup_encryption: age`)

[age](https://github.com/FiloSottile/age) encrypts the tar stream to one or more
recipients with ChaCha20-Poly1305. List every recipient that should be able to
decrypt; the backup is readable by any **one** of them (so you can add a break-glass
key alongside your day-to-day one). The role installs `age` on the host
automatically when this mode is selected.

A recipient can be any of:

- a **native age public key** (`age1...`), generated with `age-keygen`;
- an **SSH public key** (`ssh-ed25519 ...` or `ssh-rsa ...`) — age accepts these
  directly, and you decrypt with the matching SSH **private** key. Handy for teams
  that already manage SSH keys and don't want a second key type;
- a **hardware-backed key** via the
  [`age-plugin-yubikey`](https://github.com/str4d/age-plugin-yubikey) plugin —
  the recipient is an `age1yubikey1...` string and the private key never leaves
  the YubiKey.

Because age covers both SSH keys and YubiKey (hardware) keys, the SSH- and
hardware-token workflows are supported here without needing gpg.

### Setup — native age key

Generate a key pair and keep the private half **off** the server:

```bash
age-keygen -o key.txt
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

Store `key.txt` somewhere safe (password manager, offline media). Configure the
public half in `host_vars/<host>.yml`:

```yaml
backup_encryption: age
backup_age_recipients:
  - "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
```

### Setup — SSH public key

No new key material needed: use the public key you already have. Only the public
key goes on the server; the matching private key decrypts.

```yaml
backup_encryption: age
backup_age_recipients:
  - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@laptop"
```

### Setup — YubiKey (hardware-backed key)

Install the plugin and generate an identity that lives on the YubiKey, then use
its recipient string on the server. The private key never exists as a file.

```bash
# On your workstation, YubiKey plugged in
age-plugin-yubikey            # interactive: creates an identity on the key
age-plugin-yubikey --list     # prints the recipient: age1yubikey1q...
```

```yaml
backup_encryption: age
backup_age_recipients:
  - "age1yubikey1qwt50d05nh5vutpdzmlg5wn80xq8aysptv7n8q6jvncxw3kn9x6qzhgz4n"
```

Decryption later requires the YubiKey (and `age-plugin-yubikey` installed on the
machine doing the restore).

## Decrypt

Run on a machine that holds the matching identity:

```bash
# native age identity file
age --decrypt -i key.txt -o backup.tar backup.tar.age

# SSH private key
age --decrypt -i ~/.ssh/id_ed25519 -o backup.tar backup.tar.age

# YubiKey-backed identity (age-plugin-yubikey installed; touch/PIN as configured)
age --decrypt -i <(age-plugin-yubikey --identity) -o backup.tar backup.tar.age
```

If you lose the only identity that can decrypt a backup, **that backup is
unrecoverable**. Keep a second recipient (a break-glass age key, or a printed
copy of `key.txt`) in a secure offline location, and add it to
`backup_age_recipients` so every object is encrypted to both.

## Restoring on a large volume

For a big backup, avoid round-tripping it through your laptop. Two options:

- **Decrypt on the server with a transferred identity.** Copy the age identity
  file (or SSH private key) to the server temporarily, decrypt in place, then
  remove it. Simple, but the key briefly lives on the host.
- **Decrypt on your laptop, stream to the server.** If the identity must never
  touch the server (e.g. a YubiKey), pull the object to your laptop, decrypt
  there, and pipe the plaintext tar back over SSH:

  ```bash
  aws s3 cp s3://PROJECT-backup/<server>/vol/VOLUME/backup-TS.tar.age - --region REGION \
    | age --decrypt -i ~/.ssh/id_ed25519 \
    | ssh user@server 'cat > /tmp/backup-TS.tar'
  ```

  Only the (encrypted) object and the resulting plaintext cross the wire; the
  private key stays on the laptop / YubiKey.

## Verifying encryption

After setting the encryption variable and applying the role, trigger a run and
confirm the uploaded object has the expected extension:

```bash
# Trigger a backup run on the server (don't wait for the timer)
systemctl start miuops-backup.service
journalctl -u miuops-backup.service -f

# Check S3 for the encrypted object
aws s3 ls s3://PROJECT-backup/<server>/vol/ --recursive --region REGION
# Should show: <server>/vol/<volume>/backup-YYYYMMDDTHHMMSSZ.tar.age
```

## Restoring encrypted backups

1. Download the backup from S3.
2. Decrypt it (see [Decrypt](#decrypt) above).
3. Extract the tar (it is **not** gzip-compressed).

```bash
# Download
aws s3 cp s3://PROJECT-backup/<server>/vol/VOLUME/backup-YYYYMMDDTHHMMSSZ.tar.age . --region REGION

# Decrypt (age — identity file, SSH private key, or YubiKey)
age --decrypt -i key.txt -o backup-YYYYMMDDTHHMMSSZ.tar backup-YYYYMMDDTHHMMSSZ.tar.age

# Extract (the tar is rooted at the volume's contents; --numeric-owner keeps
# ownership deterministic across hosts)
tar --numeric-owner -xf backup-YYYYMMDDTHHMMSSZ.tar
```

For full restore procedures (extracting straight into a Docker volume), see [Disaster Recovery](DISASTER_RECOVERY.md).
