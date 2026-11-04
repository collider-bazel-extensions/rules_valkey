#!/usr/bin/env bash
# valkey_test(password = ...): requirepass; VALKEYCLI_AUTH lets vk and
# valkey-cli log in; unauthenticated clients are refused; URL carries it.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"

[[ "$VALKEY_PASSWORD" == "s3cret pass" && "$VALKEYCLI_AUTH" == "s3cret pass" ]] || fail "password vars"
[[ "$VALKEY_URL" == "redis://:s3cret pass@127.0.0.1:$VALKEY_PORT" ]] || fail "VALKEY_URL=$VALKEY_URL"
[[ "$(vk PING)" == PONG ]] || fail "vk with VALKEYCLI_AUTH"
[[ "$(vk GET app:greeting)" == "hello world" ]] || fail "seeded with the password"
[[ "$(env -u VALKEYCLI_AUTH valkey-cli -p "$VALKEY_PORT" PING 2>&1)" == *NOAUTH* ]] || fail "unauthenticated PING accepted"
echo "PASS"
