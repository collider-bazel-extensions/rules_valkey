#!/usr/bin/env bash
# valkey_stop / valkey_start: the client fails while stopped; the server
# comes back on the same port, with the same password, and its data comes
# back if persistence is on.
#
# Argv: kept | empty   (what the restart should find)
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"
want="$1"

port=$VALKEY_PORT
vk SET restart:key v1 >/dev/null
valkey_stop
rc=0; out=$(vk PING 2>&1) || rc=$?
[[ "$rc" != 0 || "$out" != PONG ]] || fail "server still answering after valkey_stop"
grep -q "Connection refused" <<<"$out" || fail "no connection error while stopped: $out"
echo "ok: stopped; clients fail"

valkey_start
valkey_start   # already running: no-op
[[ "$VALKEY_PORT" == "$port" ]] || fail "port changed"
[[ "$(vk PING)" == PONG ]] || fail "not answering after valkey_start"
got=$(vk GET restart:key)
case "$want" in
  kept)  [[ "$got" == v1 ]] || fail "data lost across the restart (got '$got')" ;;
  empty) [[ -z "$got" ]] || fail "no persistence, but the key came back: '$got'" ;;
esac
echo "ok: restarted on $port; data $want"

# Restart twice more: stop/start is repeatable, data still as expected.
vk SET restart:key v2 >/dev/null
valkey_stop && valkey_start
got=$(vk GET restart:key)
[[ "$want" == empty && -z "$got" || "$want" == kept && "$got" == v2 ]] || fail "second restart: '$got'"
echo "PASS"
