#!/usr/bin/env bash
# Lint the backup role's security-critical properties so a future edit that
# weakens encryption gating or the pinned-binary supply chain fails CI. Pure
# structural assertions over the YAML text -- the backup role is a no-op in the
# CI converge (backup_enabled is false there), so nothing else exercises it.
#
# This is a TRIPWIRE, not a proof: grep can be defeated by a determined edit
# (e.g. commenting out a gate). It catches the realistic regressions -- a
# dropped guard, a missing checksum, a drifted version, an off-pin URL, a
# loosened comparator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/roles/backup/tasks/main.yml"
D="$ROOT/roles/backup/defaults/main.yml"
fail() { echo "FAIL: $1"; exit 1; }

# Encryption gating must fail CLOSED: 'age' needs recipients; recipients with
# encryption=none must be rejected (else the backup uploads PLAINTEXT while the
# operator believes it is encrypted); recipients must be a LIST (a bare string
# is iterated per-character into bogus `-r` args -> a backup that fails only at
# 02:00 while every up-front assert called the config valid).
grep -qF "not (backup_encryption == 'age' and (backup_age_recipients | length == 0))" "$T" \
    || fail "encryption assert must reject 'age' without recipients"
grep -qF "not (backup_encryption == 'none' and (backup_age_recipients | length > 0))" "$T" \
    || fail "encryption assert must reject recipients with encryption=none (plaintext-upload guard)"
grep -qF "backup_age_recipients is sequence and backup_age_recipients is not string" "$T" \
    || fail "encryption assert must require backup_age_recipients to be a list (not a bare string)"

# age-plugin-yubikey is installed ONLY for a YubiKey recipient, and only with
# age. Pin the FULL gate expression (the comparator too) so a `> 0` -> `>= 0`
# loosening that makes every host install the plugin is caught.
grep -qF "select('match', '^age1yubikey') | list | length > 0" "$T" \
    || fail "plugin install must be gated on a YubiKey (age1yubikey) recipient"
grep -qF "backup_encryption == 'age'" "$T" \
    || fail "plugin install must be gated on backup_encryption == 'age'"

# Supply chain: the binary comes from the PINNED miuops CI release (transparent CI build,
# amd64 + arm64), is sha256-verified (fail-closed), and installed executable on PATH.
grep -qF '/releases/download/age-plugin-yubikey-v' "$T" \
    || fail "plugin binary must download from the miuops CI release (age-plugin-yubikey-v<ver>)"
grep -qF "{{ backup_age_plugin_yubikey_repo }}" "$T" \
    || fail "plugin binary URL must use the pinned repo var (backup_age_plugin_yubikey_repo)"
grep -qE 'checksum:[[:space:]]*"sha256:' "$T" \
    || fail "plugin binary must be sha256-verified"
grep -qF "dest: /usr/local/bin/age-plugin-yubikey" "$T" \
    || fail "plugin binary must install to /usr/local/bin/age-plugin-yubikey (on PATH)"
# root-owned (context-scoped to the get_url task: a bare `grep owner: root` would match any
# of the other tasks and pass even if this one dropped root ownership).
awk '/dest: \/usr\/local\/bin\/age-plugin-yubikey/{f=1}
     f&&/^[[:space:]]*- name:/{exit 1}
     f&&/owner:/{print;exit}' "$T" | grep -qF "owner: root" \
    || fail "plugin binary (get_url) must be owner: root (present + root, before the next task)"
grep -qF "mode: '0755'" "$T" \
    || fail "plugin binary must be installed executable (0755)"
grep -qF "name: libpcsclite1" "$T" \
    || fail "must install libpcsclite1 (the plugin's runtime .so dependency)"
grep -qF "age-plugin-yubikey --version" "$T" \
    || fail "must verify the plugin runs post-install (--version), not at restore time"

# Architecture: the CI build covers amd64 + arm64; the role maps the kernel arch and must
# accept aarch64/arm64 (the old amd64-only guard would reject ARM fleet hosts).
grep -qF "'aarch64': 'arm64'" "$T" \
    || fail "plugin install must map aarch64 -> arm64 (accept ARM fleet hosts)"

# Per-arch sha256: BOTH arches must be pinned (64-hex), fail-closed. The role asserts the
# sha is present before download, so a forgotten pin fails fast at apply (not at restore).
grep -qE 'amd64:[[:space:]]*"[0-9a-f]{64}"' "$D" \
    || fail "backup_age_plugin_yubikey_sha256.amd64 must be a pinned 64-hex sha256"
grep -qE 'arm64:[[:space:]]*"[0-9a-f]{64}"' "$D" \
    || fail "backup_age_plugin_yubikey_sha256.arm64 must be a pinned 64-hex sha256"

echo "ALL BACKUP ROLE LINT CHECKS PASSED"
