#!/usr/bin/env bash
# valkey_test with a config + ACL file + seed: environment, seeded data,
# config applied, ACL users enforced, unix socket, helpers, args.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"

[[ $# -eq 2 && "$1" == one && "$2" == "two words" ]] || fail "args: $# [$*]"
for k in VALKEY_HOST VALKEY_PORT VALKEY_URL VALKEY_SOCKET VALKEY_CLI VALKEY_SERVER; do
  [[ -n "${!k:-}" ]] || fail "$k not set"
done
[[ "$VALKEY_URL" == "redis://127.0.0.1:$VALKEY_PORT" ]] || fail "VALKEY_URL=$VALKEY_URL"
[[ -z "${VALKEY_CLUSTER_NODES:-}" && -z "${VALKEY_PASSWORD:-}" ]] || fail "cluster/password vars set"
[[ "$(command -v valkey-cli)" == "$VALKEY_CLI" ]] || fail "valkey-cli not on PATH"
[[ "$("$VALKEY_SERVER" --version)" == *"v=9.1.3"* ]] || fail "not valkey 9.1.3"
echo "ok: environment"

[[ "$(vk GET app:greeting)" == "hello world" ]] || fail "seed string"
[[ "$(vk HGET app:user:1 email)" == "ada@example.com" ]] || fail "seed hash"
[[ "$(vk LRANGE app:queue 0 -1 | tr '\n' ' ')" == "job-1 job-2 job-3 " ]] || fail "seed list"
[[ "$(vk ZRANGE leaderboard 0 -1 | tr '\n' ' ')" == "alice carol bob " ]] || fail "seed zset"
echo "ok: seeded"

[[ "$(vk CONFIG GET maxmemory | tail -1)" == 67108864 ]] || fail "maxmemory from config"
[[ "$(vk CONFIG GET maxmemory-policy | tail -1)" == allkeys-lru ]] || fail "policy from config"
[[ "$(vk CONFIG GET dir | tail -1)" != /var/lib/valkey ]] || fail "host dir not overridden"
echo "ok: config applied, host paths overridden"

app() { "$VALKEY_CLI" -p "$VALKEY_PORT" --user app --pass app-secret --no-auth-warning "$@"; }
[[ "$(app GET app:greeting)" == "hello world" ]] || fail "app user read"
[[ "$(app GET other:secret)" == *NOPERM* ]] || fail "app user read outside app:*: $(app GET other:secret)"
[[ "$(app FLUSHALL)" == *NOPERM* ]] || fail "app user ran a dangerous command"
reader() { "$VALKEY_CLI" -p "$VALKEY_PORT" --user reader --pass reader-secret --no-auth-warning "$@"; }
[[ "$(reader SET app:x 1)" == *NOPERM* ]] || fail "reader wrote"
echo "ok: ACL users from users.acl enforced"

[[ "$("$VALKEY_CLI" -s "$VALKEY_SOCKET" PING)" == PONG ]] || fail "unix socket"
echo "ok: unix socket"

( sleep 0.3; vk SET later done >/dev/null ) &
vk_wait done GET later || fail "vk_wait"
if VK_WAIT_TIMEOUT=1 vk_wait never GET later 2>/dev/null; then fail "vk_wait did not time out"; fi
vk_flush
[[ "$(vk DBSIZE)" == 0 ]] || fail "vk_flush"
echo "ok: vk_wait, vk_flush"
echo "PASS"
