# Backup Encryption

Client-side encryption for Docker volume backups. Encrypts the entire tarball **before** uploading to S3, so backups are unreadable even if AWS credentials are compromised.

## Why encrypt backups?

- **Defense in depth**: S3 has server-side encryption (SSE-S3), but a compromised AWS credential can still read objects. Client-side encryption adds a second layer.
- **Secrets in backups**: The `.env` file (containing all credentials) is included in the backup tarball. Without encryption, anyone with S3 access can read every secret.
- **Compliance**: Some environments require data-at-rest encryption under the application's control, not just the cloud provider's.

## How it works

The backup sidecar ([offen/docker-volume-backup](https://github.com/offen/docker-volume-backup)) supports four encryption methods via environment variables. Set **exactly one** — they are mutually exclusive. Setting more than one will cause the backup to fail with an error. When none is set, backups are uploaded unencrypted.

The sidecar encrypts the tarball after compression and before upload. Encrypted backups get a `.gpg` or `.age` file extension appended automatically.

## Methods

### GPG symmetric (`GPG_PASSPHRASE`)

Encrypts with AES-256 using a passphrase. Simplest to set up.

**Trade-off**: The passphrase lives on the server (in `.env`). If the server is compromised, the attacker has both the backups and the key to decrypt them. Still protects against S3-only credential leaks.

**Setup**:

```bash
# Generate a strong passphrase
openssl rand -base64 32
```

Add to your `.env`:

```
GPG_PASSPHRASE=your-generated-passphrase
```

**Decrypt**:

```bash
gpg --decrypt --batch --passphrase "your-passphrase" backup.tar.gz.gpg > backup.tar.gz
```

### GPG asymmetric (`GPG_PUBLIC_KEY_RING_FILE`)

Encrypts with a GPG public key. The private key never touches the server — only someone with the private key can decrypt.

**Best for**: Maximum security. Compatible with YubiKey and other hardware security keys for private key storage.

**Note**: This method uses a key **file** (not an env var) because PGP keys are multiline and `.env` files don't support multiline values.

**Setup**:

```bash
# Generate a key pair (if you don't already have one)
gpg --full-generate-key

# Export the public key to a file
gpg --armor --export your-key-id > public_key.asc

# Copy the key file to the server
scp public_key.asc user@server:/opt/stacks/gpg-public-key.asc
```

Then edit `stacks/backup/docker-compose.yml` in your stack repo to add the env var and volume mount:

```yaml
services:
  backup:
    environment:
      GPG_PUBLIC_KEY_RING_FILE: /keys/public_key.asc
    volumes:
      - /opt/stacks/gpg-public-key.asc:/keys/public_key.asc:ro
```

**Decrypt**:

```bash
# With the private key in your local GPG keyring
gpg --decrypt backup.tar.gz.gpg > backup.tar.gz

# With a YubiKey (private key on hardware)
gpg --decrypt backup.tar.gz.gpg > backup.tar.gz
# GPG will prompt for the YubiKey PIN
```

### Age symmetric (`AGE_PASSPHRASE`)

Encrypts with ChaCha20-Poly1305 using a passphrase. Modern alternative to GPG symmetric.

**Trade-off**: Same as GPG symmetric — passphrase lives on the server.

**Setup**:

```bash
# Generate a strong passphrase
openssl rand -base64 32
```

Add to your `.env`:

```
AGE_PASSPHRASE=your-generated-passphrase
```

**Decrypt**:

```bash
age --decrypt -o backup.tar.gz backup.tar.gz.age
# age will prompt for the passphrase
```

### Age asymmetric (`AGE_PUBLIC_KEYS`)

Encrypts with an Age public key. Supports native Age keys and SSH keys (`ssh-ed25519`, `ssh-rsa`).

**Best for**: Teams already using SSH keys. No GPG keyring management needed.

**Setup with Age keys**:

```bash
# Generate an Age key pair
age-keygen -o key.txt
# Output: public key: age1...
```

Add the public key to your `.env`:

```
AGE_PUBLIC_KEYS=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

**Setup with SSH keys**:

```bash
# Use an existing SSH public key
cat ~/.ssh/id_ed25519.pub
```

Add the SSH public key to your `.env`:

```
AGE_PUBLIC_KEYS=ssh-ed25519 AAAA...
```

**Decrypt**:

```bash
# With Age identity file
age --decrypt -i key.txt -o backup.tar.gz backup.tar.gz.age

# With SSH private key
age --decrypt -i ~/.ssh/id_ed25519 -o backup.tar.gz backup.tar.gz.age
```

## Choosing a method

| | GPG symmetric | GPG asymmetric | Age symmetric | Age asymmetric |
|---|---|---|---|---|
| Env var | `GPG_PASSPHRASE` | `GPG_PUBLIC_KEY_RING_FILE` | `AGE_PASSPHRASE` | `AGE_PUBLIC_KEYS` |
| Config via | `.env` | Key file + compose edit | `.env` | `.env` |
| Algorithm | AES-256 | AES-256 | ChaCha20-Poly1305 | ChaCha20-Poly1305 |
| Secret on server | Passphrase | Public key only | Passphrase | Public key only |
| Hardware key support | No | YubiKey | No | SSH keys |
| Setup complexity | Low | Medium | Low | Low |
| Decrypt tooling | `gpg` | `gpg` | `age` | `age` |
| Best for | Simple setups | Maximum security | Simple setups | SSH-based teams |

**Recommendation**: Use **GPG asymmetric** if you want maximum security (private key never on server, YubiKey compatible). Use **Age asymmetric with SSH keys** if your team already has SSH keys and wants minimal setup.

## YubiKey integration

GPG asymmetric encryption works with YubiKey (or other OpenPGP smartcards). The private key lives on the YubiKey and never exists as a file — only the public key is needed on the server for encryption.

### How it works

- **Encryption** (automated daily backup): Uses only the public key file on the server. No YubiKey involved.
- **Decryption** (manual disaster recovery): Requires the YubiKey. GPG talks to the smartcard to perform the decryption operation.

### Setup

Follow the [GPG asymmetric setup](#gpg-asymmetric-gpg_public_key_ring_file) above. If your key pair already lives on a YubiKey, just export the public key:

```bash
gpg --armor --export your-key-id > public_key.asc
scp public_key.asc user@server:/opt/stacks/gpg-public-key.asc
```

### Decrypting with a YubiKey

You have two options for decryption during a restore:

**Option A: Decrypt on your laptop, transfer the tarball**

Simplest approach. Download the encrypted backup to your laptop, decrypt locally (YubiKey plugged in), then upload the decrypted tarball to the server:

```bash
# On your laptop
aws s3 cp s3://PROJECT-backup/vol/backup.tar.gz.gpg . --region REGION
gpg --decrypt backup.tar.gz.gpg > backup.tar.gz   # YubiKey prompts for PIN
scp backup.tar.gz user@server:/tmp/
```

Trade-off: the backup transits through your laptop. Impractical for very large backups.

**Option B: GPG agent forwarding over SSH (recommended for large backups)**

Forward your local `gpg-agent` socket to the server so `gpg --decrypt` on the server uses the YubiKey plugged into your laptop. The backup data stays on the server — only the crypto operations travel over SSH.

1. **Import your public key on the server** (one-time setup, so GPG knows which smartcard to ask for):

   ```bash
   # On the server
   gpg --import /opt/stacks/gpg-public-key.asc
   ```

2. **Enable agent forwarding in the server's sshd_config** (one-time setup):

   ```
   # /etc/ssh/sshd_config
   StreamLocalBindUnlink yes
   ```

   Restart sshd: `sudo systemctl restart sshd`

3. **SSH in with agent forwarding**:

   ```bash
   # Find your local agent socket
   gpgconf --list-dir agent-extra-socket
   # e.g. /Users/you/.gnupg/S.gpg-agent.extra

   # Find the remote agent socket
   ssh user@server gpgconf --list-dir agent-socket
   # e.g. /run/user/1000/gnupg/S.gpg-agent

   # Connect with forwarding
   ssh -R /run/user/1000/gnupg/S.gpg-agent:/Users/you/.gnupg/S.gpg-agent.extra user@server
   ```

4. **Decrypt on the server** (YubiKey prompts for PIN on your laptop):

   ```bash
   gpg --decrypt backup.tar.gz.gpg > backup.tar.gz
   ```

**Tip**: Add the forwarding to your `~/.ssh/config` so you don't have to type the socket paths each time:

```
Host myserver
    HostName 203.0.113.10
    User admin
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/you/.gnupg/S.gpg-agent.extra
```

### Notes

- If your YubiKey has a touch policy for decryption, you'll need to touch the key when GPG prompts during `--decrypt`.
- The YubiKey PIN stays on your laptop: `pinentry` prompts for it locally, passes it to `gpg-agent`, which sends it to the YubiKey over USB. Only the decryption request and result travel over the SSH tunnel — the PIN never crosses the network.
- If you lose the YubiKey and have no backup of the private key, **encrypted backups are unrecoverable**. Keep a backup key in a secure offline location (e.g. a second YubiKey or a printed paperkey stored in a safe).

## Verifying encryption

After setting an encryption variable, trigger a manual backup and confirm the output file has the expected extension:

```bash
# Trigger a manual backup
docker exec backup backup

# Check S3 for the encrypted file
aws s3 ls s3://PROJECT-backup/vol/
# Should show: backup-YYYYMMDDTHHMMSS.tar.gz.gpg (or .age)
```

## Restoring encrypted backups

1. Download the backup from S3
2. Decrypt (see the method-specific instructions above)
3. Extract the tarball as usual

```bash
# Download
aws s3 cp s3://PROJECT-backup/vol/backup-YYYYMMDDTHHMMSS.tar.gz.gpg . --region REGION

# Decrypt (example: GPG symmetric)
gpg --decrypt --batch --passphrase "your-passphrase" backup-YYYYMMDDTHHMMSS.tar.gz.gpg > backup-YYYYMMDDTHHMMSS.tar.gz

# Extract
tar xzf backup-YYYYMMDDTHHMMSS.tar.gz
```

The `.env` file is in the tarball at `dotenv/.env`.

For full restore procedures, see [Disaster Recovery](DISASTER_RECOVERY.md).
