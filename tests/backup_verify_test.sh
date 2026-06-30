#!/usr/bin/env bash
#
# `miuops backup-verify --server <h> --volume <v> [--at <ts>]` -- confirm a backup
# in S3 is INTACT (catches a single flipped byte) WITHOUT a full restore to disk.
# It resolves the bucket + prefix, finds the object (latest or --at), downloads it,
# and verifies integrity end to end: an age object is decrypted to /dev/null (the
# ChaCha20-Poly1305 MAC authenticates every byte -- a flip fails it), a plaintext
# .tar is streamed through `tar -t` (structural check). This covers ongoing integrity
# (bit-rot, tamper) -- `aws s3 cp` already integrity-checks the PUT, so the value here
# is verifying a backup is still good months later.
#
# Every property is paired with a control:
#   * POSITIVE control -- an intact object verifies (exit 0).
#   * NEGATIVE fixture -- a single flipped byte MUST fail (never a silent pass).
# The AWS/S3 boundary is faked (a PATH-shimmed `aws`) and a throwaway age keypair
# stands in for the operator's identity. `is_real_failure` rejects exit 127 so the
# negatives stay RED before the command exists (no false green).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
is_real_failure() { [ "$1" != 0 ] && [ "$1" != 127 ]; }   # ran-and-rejected, not command-not-found

command -v age        >/dev/null 2>&1 || { echo "FATAL: age is required"; exit 2; }
command -v age-keygen >/dev/null 2>&1 || { echo "FATAL: age-keygen is required"; exit 2; }
command -v tar        >/dev/null 2>&1 || { echo "FATAL: tar is required"; exit 2; }

KEYDIR="$(mktemp -d)"; IDENT="${KEYDIR}/id.txt"
age-keygen -o "$IDENT" 2>/dev/null
RECIP="$(age-keygen -y "$IDENT" 2>/dev/null)"

S3ROOT="$(mktemp -d)"; BUCKET="wwang-fleet-backup"; SERVER="web1"; VOLUME="app_data"
VDIR="${S3ROOT}/${BUCKET}/${SERVER}/vol/${VOLUME}"; mkdir -p "$VDIR"

put_backup()       { tar -C "$2" --numeric-owner -cf - . | age -r "$RECIP" > "${VDIR}/backup-${1}.tar.age"; }
put_plain_backup() { tar -C "$2" --numeric-owner -cf - . > "${VDIR}/backup-${1}.tar"; }

BIN="$(mktemp -d)"
cat > "${BIN}/aws" <<AWSEOF
#!/usr/bin/env bash
set -uo pipefail
S3ROOT="${S3ROOT}"
args=(); while [ \$# -gt 0 ]; do case "\$1" in --endpoint-url) shift 2;; *) args+=("\$1"); shift;; esac; done
set -- "\${args[@]}"
[ "\$1" = "s3" ] || { echo "fake-aws: unsupported: \$*" >&2; exit 2; }
case "\$2" in
  ls)  d="\${S3ROOT}/\${3#s3://}"; d="\${d%/}"; [ -d "\$d" ] || exit 0
       for f in "\$d"/*; do [ -e "\$f" ] && printf '2026-06-29 00:00:00 %10d %s\n' "\$(wc -c < "\$f")" "\$(basename "\$f")"; done ;;
  cp)  f="\${S3ROOT}/\${3#s3://}"; [ -f "\$f" ] || { echo "fake-aws: NoSuchKey: \$3" >&2; exit 1; }
       if [ "\$4" = "-" ]; then cat "\$f"; else cp "\$f" "\$4"; fi
       # injected: the download streamed the FULL body then errored -- a non-last
       # pipeline stage fails while the consumer still got a complete object.
       if [ -f "\${f%/*}/.cp_fails" ]; then exit 1; fi ;;
  *)   echo "fake-aws: unsupported s3 op: \$2" >&2; exit 2 ;;
esac
AWSEOF
chmod +x "${BIN}/aws"

FLEET="$(mktemp -d)"; mkdir -p "${FLEET}/fleet/group_vars"
printf 'backup_s3_bucket: %s\n' "$BUCKET" > "${FLEET}/fleet/group_vars/all.yml"

run_verify() {  # [extra args...] -> echoes exit code
  local rc=0
  ( PATH="${BIN}:$PATH" MIUOPS_FLEET_DIR="${FLEET}/fleet" SOPS_AGE_KEY_FILE="$IDENT" \
      bash -c '
        . "'"$ROOT"'/miuops" --source-only 2>/dev/null
        require_sops() { :; }
        cmd_backup_verify --server '"$SERVER"' --volume '"$VOLUME"' '"$*"'
      ' >/dev/null 2>&1 ) || rc=$?
  printf '%s' "$rc"
}

# a source with a >64KB body so a flipped byte lands in the encrypted PAYLOAD (a late
# age chunk), not only the header -- proves the MAC authenticates the data, not just
# the header.
SRC="$(mktemp -d)"; head -c 200000 /dev/urandom > "${SRC}/big.bin"; printf 'hello\n' > "${SRC}/a.txt"
put_backup "20260629T010000Z" "$SRC"
put_backup "20260629T030000Z" "$SRC"   # a newer one for latest-selection

# 1. POSITIVE control -- an intact object verifies clean.
rc="$(run_verify --at 20260629T010000Z)"
[ "$rc" = 0 ] && ok "intact backup verifies (exit 0, positive control)" || bad "intact backup failed to verify (rc=$rc)"

# 2. NEGATIVE fixture -- a single flipped byte in the payload MUST fail (age MAC).
cp "${VDIR}/backup-20260629T010000Z.tar.age" "${VDIR}/backup-20260629T020000Z.tar.age"
flip="${VDIR}/backup-20260629T020000Z.tar.age"
sz=$(wc -c < "$flip"); printf 'X' | dd of="$flip" bs=1 seek=$((sz / 2)) conv=notrunc 2>/dev/null
rc="$(run_verify --at 20260629T020000Z)"
is_real_failure "$rc" && ok "single flipped byte: verify FAILS (negative fixture)" || bad "a flipped byte was not caught (rc=$rc)"

# 3. latest selection (no --at).
rc="$(run_verify)"
[ "$rc" = 0 ] && ok "no --at: verifies the latest backup" || bad "latest verify failed (rc=$rc)"

# 4. plaintext .tar passes the structural check (positive control). NOTE: tar -t
#    validates headers + completeness, NOT data bodies -- a flipped *body* byte in a
#    plaintext .tar is knowingly NOT caught (no body checksum); byte-level integrity
#    is the age path (case 2). So this is intentionally a structural positive only.
SRC2="$(mktemp -d)"; printf 'plain\n' > "${SRC2}/p.txt"
put_plain_backup "20260629T040000Z" "$SRC2"
rc="$(run_verify --at 20260629T040000Z)"
[ "$rc" = 0 ] && ok "unencrypted .tar passes the structural check (positive control)" || bad "plaintext structural verify failed (rc=$rc)"

# 4b. A plaintext .tar with a corrupted HEADER IS caught (tar -t validates the per-
#     header checksum), so the structural guarantee we DO claim for plaintext holds.
cp "${VDIR}/backup-20260629T040000Z.tar" "${VDIR}/backup-20260629T045000Z.tar"
printf 'X' | dd of="${VDIR}/backup-20260629T045000Z.tar" bs=1 seek=8 conv=notrunc 2>/dev/null   # flip in the first header's name field
rc="$(run_verify --at 20260629T045000Z)"
is_real_failure "$rc" && ok "plaintext .tar header corruption: verify FAILS (structural check works)" || bad "plaintext header corruption not caught (rc=$rc)"

# 5. missing backup -> clear failure.
rc="$(run_verify --volume nonexistent 2>/dev/null)"
is_real_failure "$rc" && ok "missing backup: fails non-zero" || bad "missing backup did not fail (rc=$rc)"

# 6. A NON-LAST stage fails while the last (tar) exits 0 -- verify MUST still fail.
#    Kills a "check only the last PIPESTATUS" regression: a download error that still
#    delivered a complete object would otherwise pass. The fake aws streams the full
#    valid object then exits non-zero, so PIPESTATUS = [aws=1, age=0, tar=0].
touch "${VDIR}/.cp_fails"
rc="$(run_verify --at 20260629T010000Z)"
is_real_failure "$rc" && ok "non-last stage fails though tar exits 0: verify FAILS (kills check-only-last-PIPESTATUS)" || bad "a non-last-stage failure was not caught (rc=$rc)"
rm -f "${VDIR}/.cp_fails"

rm -rf "$KEYDIR" "$S3ROOT" "$BIN" "$FLEET" "$SRC" "$SRC2" 2>/dev/null
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
