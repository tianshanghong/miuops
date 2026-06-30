#!/usr/bin/env bash
#
# `miuops backup-restore --server <h> --volume <v> [--at <ts>] --target <dir>`
# — the INVERSE of the host backup role's `tar | age | s3 cp` pipeline. It
# resolves the bucket from versioned config, finds the volume's object in S3
# (s3://<bucket>/<server>/vol/<volume>/backup-<ts>.tar[.age]), downloads it,
# decrypts (age) when needed, and untars it to --target byte-identical to the
# original volume data.
#
# "A backup you cannot restore is not a backup": this is the verification net
# that lets the home-grown host role replace an in-stack volume-backup container.
# Every property is paired with a control:
#   * POSITIVE control — a clean round-trip restores byte-identical content.
#   * NEGATIVE fixture  — a tampered .age object MUST fail (age's MAC), never a
#                         silent partial/garbage restore.
#   * selection         — `latest` picks the newest ts; `--at` picks an exact one.
#
# The AWS/S3 boundary is faked (a PATH-shimmed `aws` serving from a local dir)
# and a throwaway age keypair stands in for the operator's YubiKey/identity, so
# the round-trip is pinned with NO real AWS and NO real key. The encrypted path
# needs the `age` binary; if it is absent the age cases are reported as failures
# (not silently skipped) so a green run is meaningful — CI installs age.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# A "real" failure = the command RAN and rejected, NOT "command not found" (127).
# Without this, the negative/missing cases would pass in the RED phase (when
# cmd_backup_restore doesn't exist yet -> 127) -- a false green. They must stay
# RED until the command exists AND correctly rejects.
is_real_failure() { [ "$1" != 0 ] && [ "$1" != 127 ]; }

command -v age        >/dev/null 2>&1 || { echo "FATAL: age is required for the restore round-trip test"; exit 2; }
command -v age-keygen >/dev/null 2>&1 || { echo "FATAL: age-keygen is required"; exit 2; }
command -v tar        >/dev/null 2>&1 || { echo "FATAL: tar is required"; exit 2; }
command -v python3    >/dev/null 2>&1 || { echo "FATAL: python3 is required (builds the malicious-archive fixture)"; exit 2; }

# --- throwaway age identity (stands in for the operator's key/YubiKey) ---------
KEYDIR="$(mktemp -d)"
IDENT="${KEYDIR}/id.txt"
age-keygen -o "$IDENT" 2>/dev/null
RECIP="$(age-keygen -y "$IDENT" 2>/dev/null)"

# --- a local directory standing in for the S3 bucket --------------------------
# Layout mirrors real S3 keys: <s3root>/<bucket>/<server>/vol/<volume>/backup-<ts>.tar.age
S3ROOT="$(mktemp -d)"
BUCKET="wwang-fleet-backup"
SERVER="web1"
VOLUME="app_data"

# put_backup <ts> <src-dir> -> writes the encrypted tar object into the fake S3,
# byte-for-byte the way roles/backup/templates/miuops-backup.sh.j2 produces it.
put_backup() {
  local ts="$1" src="$2"
  local dir="${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}"
  mkdir -p "$dir"
  tar -C "$src" --numeric-owner -cf - . | age -r "$RECIP" > "${dir}/backup-${ts}.tar.age"
}

# put_plain_backup <ts> <src-dir> -> an UNENCRYPTED .tar object (the non-age branch).
put_plain_backup() {
  local ts="$1" src="$2"
  local dir="${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}"
  mkdir -p "$dir"
  tar -C "$src" --numeric-owner -cf - . > "${dir}/backup-${ts}.tar"
}

# --- a PATH-shimmed `aws` that serves s3 ls / s3 cp from the local S3 dir ------
BIN="$(mktemp -d)"
cat > "${BIN}/aws" <<AWSEOF
#!/usr/bin/env bash
# Minimal fake: supports the two calls backup-restore needs.
#   aws s3 ls s3://<bucket>/<prefix>/         -> list keys (one per line, real-ish)
#   aws s3 cp s3://<bucket>/<key> <dest|->    -> stream/copy the object out
set -uo pipefail
S3ROOT="${S3ROOT}"
# drop any --endpoint-url <x>
args=(); while [ \$# -gt 0 ]; do case "\$1" in --endpoint-url) shift 2;; *) args+=("\$1"); shift;; esac; done
set -- "\${args[@]}"
[ "\$1" = "s3" ] || { echo "fake-aws: unsupported: \$*" >&2; exit 2; }
case "\$2" in
  ls)
    uri="\$3"; path="\${uri#s3://}"
    dir="\${S3ROOT}/\${path%/}"
    [ -d "\$dir" ] || exit 0
    for f in "\$dir"/*; do [ -e "\$f" ] || continue; printf '2026-06-29 00:00:00 %10d %s\n' "\$(wc -c < "\$f")" "\$(basename "\$f")"; done
    ;;
  cp)
    src="\$3"; dest="\$4"; path="\${src#s3://}"; file="\${S3ROOT}/\${path}"
    [ -f "\$file" ] || { echo "fake-aws: NoSuchKey: \$src" >&2; exit 1; }
    if [ "\$dest" = "-" ]; then cat "\$file"; else cp "\$file" "\$dest"; fi
    # injected: an S3 download that streamed the FULL body but then errored (e.g. a
    # network drop after the bytes) -- aws exits non-zero though the consumer got a
    # complete archive. Lets a test make a non-last pipeline stage fail with tar=0.
    # (An if-block, not a test-then-exit one-liner: on the no-marker path the latter
    # leaves the failed-test status 1 as the script exit, breaking a normal cp.)
    if [ -f "\${file%/*}/.cp_fails" ]; then exit 1; fi
    ;;
  *) echo "fake-aws: unsupported s3 op: \$2" >&2; exit 2;;
esac
AWSEOF
chmod +x "${BIN}/aws"

# --- fake fleet so the bucket resolver finds wwang-fleet-backup ---------------
FLEET="$(mktemp -d)"
mkdir -p "${FLEET}/fleet/group_vars"
printf 'backup_s3_bucket: %s\n' "$BUCKET" > "${FLEET}/fleet/group_vars/all.yml"

# run_restore <target> [extra args...] -> echoes exit code; runs cmd_backup_restore
# with the AWS boundary faked + the age identity provided via SOPS_AGE_KEY_FILE.
run_restore() {
  local target="$1"; shift
  local rc=0
  ( PATH="${BIN}:$PATH" MIUOPS_FLEET_DIR="${FLEET}/fleet" SOPS_AGE_KEY_FILE="$IDENT" \
      bash -c '
        . "'"$ROOT"'/miuops" --source-only 2>/dev/null
        require_sops() { :; }   # sops binary not needed to unit-test restore
        cmd_backup_restore --server '"$SERVER"' --volume '"$VOLUME"' --target "'"$target"'" '"$*"'
      ' >/dev/null 2>&1 ) || rc=$?
  printf '%s' "$rc"
}

# content equality (data bytes + tree); not owners (untar runs non-root in CI).
same_tree() { diff -r "$1" "$2" >/dev/null 2>&1; }

# ============================================================================
# 1. POSITIVE control: clean round-trip restores byte-identical content
# ============================================================================
SRC="$(mktemp -d)"
mkdir -p "${SRC}/sub"
printf 'hello world\n'      > "${SRC}/a.txt"
printf '\x00\x01\x02binary' > "${SRC}/sub/b.bin"
ln -s a.txt "${SRC}/link"      2>/dev/null || true
put_backup "20260629T010000Z" "$SRC"

DST="$(mktemp -d)"
rc="$(run_restore "$DST")"
{ [ "$rc" = 0 ] && same_tree "$SRC" "$DST"; } \
  && ok "clean restore: byte-identical content (positive control)" \
  || bad "clean restore failed or content differs (rc=$rc)"

# ============================================================================
# 2. selection: latest of several timestamps
# ============================================================================
SRC2="$(mktemp -d)"; printf 'NEWEST\n' > "${SRC2}/marker"
put_backup "20260629T030000Z" "$SRC2"   # newest
DST2="$(mktemp -d)"
rc="$(run_restore "$DST2")"
{ [ "$rc" = 0 ] && [ -f "${DST2}/marker" ] && grep -qx NEWEST "${DST2}/marker"; } \
  && ok "no --at: restores the LATEST timestamp" \
  || bad "latest selection wrong (rc=$rc)"

# ============================================================================
# 3. selection: --at picks an exact (older) timestamp
# ============================================================================
DST3="$(mktemp -d)"
rc="$(run_restore "$DST3" --at 20260629T010000Z)"
{ [ "$rc" = 0 ] && same_tree "$SRC" "$DST3"; } \
  && ok "--at <ts>: restores that exact backup" \
  || bad "--at selection wrong (rc=$rc)"

# ============================================================================
# 4. NEGATIVE fixture: a tampered .age MUST fail, AND a partial extraction must be
#    WIPED. A multi-chunk (>64KB) payload + a late-byte flip makes age emit the
#    early chunks (tar writes a partial file) before the MAC fails -- so this
#    exercises the fail-closed WIPE, not merely "tar got an empty stream".
# ============================================================================
SRC4="$(mktemp -d)"
head -c 200000 /dev/urandom > "${SRC4}/big.bin"
printf 'edge\n'            > "${SRC4}/small.txt"
put_backup "20260629T040000Z" "$SRC4"
big4="${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}/backup-20260629T040000Z.tar.age"
sz4=$(wc -c < "$big4")
printf 'X' | dd of="$big4" bs=1 seek=$((sz4 - 80)) conv=notrunc 2>/dev/null
DST4="$(mktemp -d)"
rc="$(run_restore "$DST4" --at 20260629T040000Z)"
{ is_real_failure "$rc" && [ -z "$(ls -A "$DST4" 2>/dev/null)" ]; } \
  && ok "tampered multi-chunk .age: restore FAILS + partial extraction WIPED (negative fixture)" \
  || bad "tampered .age did not fail-close cleanly (rc=$rc, target populated?)"

# ============================================================================
# 5. missing backup: clear non-zero failure
# ============================================================================
DST5="$(mktemp -d)"
rc="$(run_restore "$DST5" --volume nonexistent_vol 2>/dev/null)"
is_real_failure "$rc" && ok "missing volume backup: fails non-zero" || bad "missing backup did not fail (rc=$rc)"

# ============================================================================
# 6. A NON-LAST pipeline stage fails while the last stage (tar) exits 0 -- the
#    restore MUST still fail. Guards against a "check only the last PIPESTATUS"
#    regression: a download/decrypt error that yields a complete-looking tar would
#    otherwise pass as success. Uses the UNENCRYPTED .tar path + a fake aws that
#    streams the FULL valid tar then exits non-zero, so PIPESTATUS = [aws=1, tar=0].
# ============================================================================
SRC6="$(mktemp -d)"; printf 'plain-data\n' > "${SRC6}/p.txt"
put_plain_backup "20260629T050000Z" "$SRC6"
PDIR="${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}"
touch "${PDIR}/.cp_fails"
DST6="$(mktemp -d)"
rc="$(run_restore "$DST6" --at 20260629T050000Z)"
{ is_real_failure "$rc" && [ -z "$(ls -A "$DST6" 2>/dev/null)" ]; } \
  && ok "non-last stage fails though tar exits 0: restore FAILS + wiped (kills check-only-last-PIPESTATUS)" \
  || bad "a non-last-stage failure was not caught (rc=$rc)"
rm -f "${PDIR}/.cp_fails"

# ============================================================================
# 7. Unencrypted .tar round-trip (the non-age branch) restores byte-identical.
# ============================================================================
DST7="$(mktemp -d)"
rc="$(run_restore "$DST7" --at 20260629T050000Z)"
{ [ "$rc" = 0 ] && same_tree "$SRC6" "$DST7"; } \
  && ok "unencrypted .tar: byte-identical round-trip (covers the non-age branch)" \
  || bad "unencrypted .tar round-trip failed (rc=$rc)"

# ============================================================================
# 8. Untrusted-archive containment: an object whose tar member tries to escape via
#    '../' must NOT write outside --target. python3 builds the malicious tar; age
#    encrypts it like a real object so it decrypts validly. Modern tar (GNU + bsd)
#    refuses or strips the escape; assert nothing landed in the parent dir.
# ============================================================================
nonce="esc$$"
python3 - "$RECIP" "${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}/backup-20260629T060000Z.tar.age" "$nonce" <<'PY'
import sys, io, tarfile, subprocess
recip, outpath, nonce = sys.argv[1], sys.argv[2], sys.argv[3]
buf = io.BytesIO(); t = tarfile.open(fileobj=buf, mode='w')
data = b'pwned\n'; ti = tarfile.TarInfo('../%s' % nonce); ti.size = len(data)
t.addfile(ti, io.BytesIO(data)); t.close()
enc = subprocess.run(['age', '-r', recip], input=buf.getvalue(),
                     stdout=subprocess.PIPE, check=True).stdout
open(outpath, 'wb').write(enc)
PY
DST8="$(mktemp -d)"
sentinel="$(dirname "$DST8")/${nonce}"; rm -f "$sentinel"
run_restore "$DST8" --at 20260629T060000Z >/dev/null 2>&1
[ ! -e "$sentinel" ] \
  && ok "malicious ../ archive: nothing written outside --target (traversal contained)" \
  || bad "PATH TRAVERSAL: a ../ member escaped --target"
rm -f "$sentinel"

# ============================================================================
# 9. A non-empty --target is refused (no clobber of existing data).
# ============================================================================
DST9="$(mktemp -d)"; printf 'keep\n' > "${DST9}/existing"
rc="$(run_restore "$DST9")"
{ is_real_failure "$rc" && [ -f "${DST9}/existing" ]; } \
  && ok "non-empty --target refused, existing data untouched" \
  || bad "non-empty target not refused (rc=$rc)"

# ============================================================================
# 10. Untrusted-archive containment, ABSOLUTE path: a member named with a leading
#     '/' must be stripped so it lands INSIDE --target, never at the real absolute
#     path. (Backs the code's "strips a leading /" claim with a test.)
# ============================================================================
ABS="$(mktemp -d)"; absnonce="abs$$"
python3 - "$RECIP" "${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}/backup-20260629T070000Z.tar.age" "${ABS}/${absnonce}" <<'PY'
import sys, io, tarfile, subprocess
recip, outpath, absname = sys.argv[1], sys.argv[2], sys.argv[3]
buf = io.BytesIO(); t = tarfile.open(fileobj=buf, mode='w')
data = b'pwned\n'; ti = tarfile.TarInfo(absname); ti.size = len(data)   # absname is absolute (/...)
t.addfile(ti, io.BytesIO(data)); t.close()
enc = subprocess.run(['age', '-r', recip], input=buf.getvalue(),
                     stdout=subprocess.PIPE, check=True).stdout
open(outpath, 'wb').write(enc)
PY
rm -f "${ABS}/${absnonce}"
DST10="$(mktemp -d)"
run_restore "$DST10" --at 20260629T070000Z >/dev/null 2>&1
# Contained (real abs path absent) AND actually processed (member landed inside the
# target) -- the second clause stops a restore that simply failed from false-passing.
{ [ ! -e "${ABS}/${absnonce}" ] && [ -n "$(ls -A "$DST10" 2>/dev/null)" ]; } \
  && ok "absolute-path archive member: stripped to inside --target, not the real path" \
  || bad "ABSOLUTE-PATH ESCAPE or unprocessed: a /<abs> member did not land safely inside"

# ----------------------------------------------------------------------------
rm -rf "$KEYDIR" "$S3ROOT" "$BIN" "$FLEET" "$SRC" "$SRC2" "$SRC4" "$SRC6" "$ABS" \
       "$DST" "$DST2" "$DST3" "$DST4" "$DST5" "$DST6" "$DST7" "$DST8" "$DST9" "$DST10" 2>/dev/null
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
