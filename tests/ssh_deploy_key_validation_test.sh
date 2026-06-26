#!/usr/bin/env bash
# Oracle for the ssh role's deploy-key validation (fail-closed).
#
# The ssh role installs only PUBLIC keys into a server's authorized_keys. It must
# POSITIVELY validate every supplied value against an allowlist of public-key
# prefixes AND refuse anything containing the substring 'PRIVATE KEY' — so a private
# key fed in by mistake is rejected, never written, never committed.
#
# This script reimplements the EXACT same allowlist/refusal logic that
# roles/ssh/tasks/main.yml asserts, then exercises it with good keys (accepted) and
# bad inputs (refused). Each assertion can genuinely FAIL: a positive control that
# refused, or a negative control that was accepted, flips `fail` to 1 and exits 1.
#
# Keeping the predicate here in lockstep with the Ansible assert means a regression
# in either (loosening the allowlist, dropping the PRIVATE KEY guard) is caught by a
# fixture that this test asserts on.
set -u

fail=0

# is_public_key <value> -> exit 0 if the value is an acceptable PUBLIC key, else 1.
#
# Mirrors the role assert, which requires BOTH:
#   (a) the value starts with one of the allowlisted public-key types, AND
#   (b) the value does NOT contain the substring 'PRIVATE KEY'.
# Any value failing either clause (including unrecognized forms) is refused.
is_public_key() {
  local v="$1"

  # one entry == one key: reject any multi-line value. ansible.posix.authorized_key
  # splits on newlines and installs each line separately, so a multi-line value
  # could smuggle a back-door key past a valid first line. Count lines with Python
  # splitlines() -- the SAME boundary the role assert (item.splitlines()) and the
  # install module (key.splitlines()) use -- so the test tracks the gate on exotic
  # separators too (\r, \f, \v, U+2028, U+0085), not only \n.
  [ "$(printf '%s' "$v" | python3 -c 'import sys;print(len(sys.stdin.read().splitlines()))')" -le 1 ] || return 1

  # fail-closed, CASE-INSENSITIVE: never accept anything carrying private-key material.
  printf '%s' "$v" | grep -qi 'PRIVATE KEY' && return 1

  # positive allowlist of public-key prefixes (the only accepted forms; trailing
  # space on the space-delimited types so a glued suffix / bare type is refused).
  case "$v" in
    "ssh-rsa "*) return 0 ;;
    "ssh-ed25519 "*) return 0 ;;
    "ssh-dss "*) return 0 ;;
    "ecdsa-sha2-"*) return 0 ;;
    "sk-ssh-ed25519@openssh.com "*) return 0 ;;
    "sk-ecdsa-sha2-"*) return 0 ;;
    *) return 1 ;;
  esac
}

accept() { # $1=label  $2=value : the value MUST be accepted
  if is_public_key "$2"; then
    echo "ok   (accept): $1"
  else
    echo "FAIL (accept): expected '$1' to be accepted but it was refused"; fail=1
  fi
}

refuse() { # $1=label  $2=value : the value MUST be refused
  if is_public_key "$2"; then
    echo "FAIL (refuse): expected '$1' to be refused but it was accepted"; fail=1
  else
    echo "ok   (refuse): $1"
  fi
}

# All key fixtures below are SYNTHETIC: real-FORMAT headers / type-prefixes (so the
# allowlist + the 'PRIVATE KEY' guard are exercised honestly) with literal
# 'testkey' / 'legit' / 'backdoor' filler bodies. NO real, usable, or in-use key
# material exists anywhere in this file — the private-key blocks are recognizable
# stubs (e.g. the OpenSSH one is ~132B vs ~400B for a real ed25519 key; its secret
# scalar is literally 'testkey…'), not generated or copied keys.
# --- Positive controls: well-formed PUBLIC keys (synthetic), every allowlisted type, accepted ---
accept "ssh-ed25519" \
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtESTKEYtestkeytestkeytestkeytestkey ci-deploy@web1"
accept "ssh-rsa" \
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDtestkeytestkeytestkeytestkey deploy@web1"
accept "ssh-dss" \
  "ssh-dss AAAAB3NzaC1kc3MAAACBtestkeytestkeytestkeytestkey deploy@web1"
accept "ecdsa-sha2-nistp256" \
  "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTZtestkey deploy@web1"
accept "sk-ssh-ed25519 (FIDO2)" \
  "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29ttestkey deploy@web1"
accept "sk-ecdsa-sha2 (FIDO2)" \
  "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZ0estkey deploy@web1"

# --- Negative controls: bad inputs, each refused ---------------------------------
# A synthetic OpenSSH PRIVATE KEY block (recognizable header, filler body) — the kind of
# value an operator might paste by mistake, which we must refuse.
refuse "OpenSSH private key block" \
  "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQy
NTUxOQAAACDtestkeytestkeytestkeytestkeytestkeytestkeytestkey
-----END OPENSSH PRIVATE KEY-----"
# A synthetic PEM RSA private key (different banner, same 'PRIVATE KEY' substring).
refuse "PEM RSA private key block" \
  "-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAtestkeytestkeytestkeytestkeytestkeytestkeytestkey
-----END RSA PRIVATE KEY-----"
refuse "empty string"          ""
refuse "random string"         "this is not a key at all"
refuse "looks-like-but-bogus"  "ssh-elgamal AAAAsomethingbogus deploy@web1"
# A value that LOOKS public but smuggles private-key material must still be refused.
refuse "public prefix + PRIVATE KEY substring" \
  "ssh-ed25519 AAAA... -----BEGIN OPENSSH PRIVATE KEY-----"
# Glued suffix (no delimiter after the type) and a bare type with no key body.
refuse "glued prefix (no delimiter)"    "ssh-rsaEVILSUFFIX"
refuse "bare type, no key body"         "ssh-rsa"
# Multi-line value: legit first line, back-door key on the second — the module would
# install BOTH, so the whole value must be refused.
refuse "multi-line smuggles a 2nd key"  "ssh-ed25519 AAAAlegit ci@web1
ssh-rsa AAAAbackdoor attacker@evil"
# Lower-case private-key banner must still be caught (case-insensitive guard).
refuse "lowercase private-key banner"   "-----begin openssh private key-----"
# Exotic separators (the boundary the install module's splitlines() actually uses):
# a CR-glued back-door must be REFUSED, a single valid key with a trailing newline
# must be ACCEPTED (it installs exactly one key — the trailing empty line is dropped).
crval=$'ssh-ed25519 AAAAlegit ci@web1\rssh-rsa AAAAbackdoor attacker@evil'
refuse "CR-glued back-door key"         "$crval"
nlval=$'ssh-ed25519 AAAAvalidbody ci@web1\n'
accept "valid key, trailing newline"    "$nlval"

if [ "$fail" -eq 0 ]; then
  echo "ALL SSH DEPLOY-KEY VALIDATION TESTS PASSED"
else
  echo "SSH DEPLOY-KEY VALIDATION TESTS FAILED"
fi
exit "$fail"
