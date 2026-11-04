#!/usr/bin/env bash
# valkey_server run directly (as rules_itest would): env file, extra_args,
# caller VALKEYCLI_AUTH ignored, SIGTERM.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"
VALKEYCLI_AUTH=wrong REDISCLI_AUTH=wrong "$SERVER" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [[ -f "$env_file" ]] && break; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a
unset VALKEYCLI_AUTH
[[ "$("$VALKEY_CLI" -p "$VALKEY_PORT" CONFIG GET maxmemory | tail -1)" == 33554432 ]] || fail "extra_args not applied"
[[ "$("$VALKEY_CLI" -p "$VALKEY_PORT" GET app:greeting)" == "hello world" ]] || fail "not seeded"
echo "ok: configured server"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
if (exec 3<>"/dev/tcp/127.0.0.1/$VALKEY_PORT") 2>/dev/null; then fail "port still open"; fi
[[ ! -e "$VALKEY_SOCKET" ]] || fail "socket left: $VALKEY_SOCKET"
echo "ok: SIGTERM stops valkey, exit 0, env file and socket removed"
echo "PASS"
