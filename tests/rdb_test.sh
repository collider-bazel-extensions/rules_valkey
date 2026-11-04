#!/usr/bin/env bash
# valkey_test(rdb = ...): starts from the dump.
set -euo pipefail
source "$VALKEY_TESTLIB"
[[ "$(vk GET from:rdb)" == "loaded from dump.rdb" ]] || { echo "FAIL: rdb not loaded" >&2; exit 1; }
[[ "$(vk SCARD from:rdb:set)" == 3 ]] || { echo "FAIL: rdb set" >&2; exit 1; }
echo PASS
