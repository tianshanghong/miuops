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

# Supply chain: the .deb comes from the PINNED upstream repo, is sha256-verified
# (fail-closed), and the version var is the single source of truth (interpolated
# into BOTH url and dest -- no drift).
grep -qF 'https://github.com/str4d/age-plugin-yubikey/releases/download/' "$T" \
    || fail "plugin .deb must download from the pinned upstream repo (github.com/str4d/age-plugin-yubikey)"
grep -qE 'checksum:[[:space:]]*"sha256:' "$T" \
    || fail "plugin .deb must be sha256-verified"
ver_uses=$(grep -c 'backup_age_plugin_yubikey_version' "$T" || true)
[ "${ver_uses:-0}" -ge 2 ] \
    || fail "url + dest must both interpolate backup_age_plugin_yubikey_version (found ${ver_uses})"
grep -qE 'backup_age_plugin_yubikey_deb_sha256:[[:space:]]*"[0-9a-f]{64}"' "$D" \
    || fail "backup_age_plugin_yubikey_deb_sha256 must be a 64-hex sha256"

# Architecture guard: upstream ships an amd64 Linux build only; a YubiKey
# recipient on another arch must fail fast, not 404 mid-download.
grep -qF "'x86_64'" "$T" \
    || fail "plugin install must assert the host architecture (x86_64)"

echo "ALL BACKUP ROLE LINT CHECKS PASSED"
