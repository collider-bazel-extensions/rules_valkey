#!/usr/bin/env bash
# valkey_config's validation action (launcher.py check): accepts the good
# config (with its ACL file standing in for the aclfile path); rejects
# bad values, unknown directives, a missing ACL file, and bad ACL rules,
# with valkey-server's own message.
#
# Argv: <launcher.py> <valkey.conf> <the toolchain's files...>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
r() {
  local c
  for c in "$TEST_SRCDIR/_main/$1" "$TEST_SRCDIR/${1#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  fail "not in runfiles: $1"
}
LAUNCHER="$(r "$1")"; D="$(dirname "$(r "$2")")"; shift 2
SERVER=""
for f in "$@"; do [[ "$f" == */bin/valkey-server ]] && SERVER="$(r "$f")"; done
[[ -n "$SERVER" ]] || fail "valkey-server not among the toolchain files"
m="$TEST_TMPDIR/marker"
check() { rm -f "$m"; python3 "$LAUNCHER" check --server "$SERVER" --marker "$m" "$@"; }

check --config "$D/valkey.conf" --acl "$D/users.acl" || fail "good config rejected"
[[ -f "$m" ]] || fail "no marker"
echo "ok: good config + ACL"

expect() {
  local want="$1"; shift
  local out
  if out=$(check "$@" 2>&1); then fail "accepted: $*"; fi
  grep -qF -- "$want" <<<"$out" || fail "want '$want' in: $out"
  [[ ! -f "$m" ]] || fail "marker written for: $*"
}
expect "argument must be a memory value" --config "$D/bad_value.conf"
expect ">>> 'maxmemory banana'" --config "$D/bad_value.conf"
expect "at line 2" --config "$D/bad_directive.conf"
expect "Bad directive or wrong number of arguments" --config "$D/bad_directive.conf"
# The config's aclfile path is the host's; without --acl there is no ACL file.
check --config "$D/valkey.conf" || fail "config without --acl rejected"
expect "Unknown command or category name in ACL" --config "$D/valkey.conf" --acl "$D/bad.acl"
echo "ok: refused with valkey-server's message"
echo "PASS"
