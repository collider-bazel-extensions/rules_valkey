#!/usr/bin/env bash
# A server that can't start, isn't ready in time, or whose seed fails
# exits non-zero, names the cause, and writes no env file; valkey_test
# fails before running the test body.
#
# Argv: <bad_flag server> <bad_seed server> <slow server> <trampoline>
#       <failing_valkey_test server> <failing_valkey_test inner> <testlib.sh>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  local name="$1" path="$TEST_SRCDIR/_main/$2" rc=0
  out=$(timeout 120 "$path" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail "$name: exited 0. Output: $out"
  [[ "$rc" != 124 ]] || fail "$name: hung. Output: $out"
  [[ ! -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file written"
}

run bad_flag_server "$1"
grep -q "valkey-server exited with status 1 before it was ready" <<<"$out" || fail "bad_flag: cause: $out"
grep -q "Bad directive or wrong number of arguments" <<<"$out" || fail "bad_flag: server message: $out"
echo "ok: valkey-server that can't start"

run bad_seed_server "$2"
grep -q "seed .*bad_seed.valkey failed" <<<"$out" || fail "bad_seed: file not named: $out"
grep -q "ERR wrong number of arguments for 'incr' command" <<<"$out" || fail "bad_seed: error not shown: $out"
# The server had started (the seed ran against it); it must be gone now.
port=$(sed -n 's/.*Running mode=standalone, port=\([0-9]*\).*/\1/p' "$TEST_TMPDIR/valkey-bad_seed_server/valkey.log")
[[ -n "$port" ]] || fail "bad_seed: no port in the server log"
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "bad_seed: server left running on $port"; fi
echo "ok: failing seed"

run slow_server "$3"
grep -q "valkey-server was not ready within 0.001s" <<<"$out" || fail "slow: cause: $out"
echo "ok: readiness timeout"

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" timeout 120 "$TEST_SRCDIR/_main/$4" "$5" "$6" failing_valkey_test_valkey "$7" 2>&1) || rc=$?
[[ "$rc" != 0 && "$rc" != 124 ]] || fail "failing valkey_test: status $rc: $out"
grep -q "valkey_test: Valkey server exited" <<<"$out" || fail "valkey_test: cause: $out"
if grep -q "TEST BODY RAN" <<<"$out"; then fail "valkey_test ran the test body"; fi
echo "ok: valkey_test fails before the test runs"
echo "PASS"
