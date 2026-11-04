#!/usr/bin/env bash
# One cluster node restarted (valkey_stop 1 / valkey_start 1), then the
# whole cluster: the cluster is ok again and the data is all there.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"

for k in a b c d e f g h; do vk SET "k:$k" "$k" >/dev/null; done
check() {
  local k; for k in a b c d e f g h; do [[ "$(vk GET "k:$k")" == "$k" ]] || fail "$1: k:$k missing"; done
  vk CLUSTER INFO | grep -q cluster_state:ok || fail "$1: cluster not ok"
}
valkey_stop 1
valkey_start 1
check "node 1 restarted"
echo "ok: one node restarted, rejoined"
valkey_stop
valkey_start
check "whole cluster restarted"
echo "ok: whole cluster restarted"
rc=0; out=$(valkey_stop 9 2>&1) || rc=$?
[[ "$rc" != 0 ]] && grep -q "valkey_stop: 400: no node '9' (0..5)" <<<"$out" || fail "bad node index: $out"
echo "PASS"
