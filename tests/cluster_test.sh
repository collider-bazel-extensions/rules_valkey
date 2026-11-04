#!/usr/bin/env bash
# valkey_test(shards = 3, replicas = 1): six nodes, all slots covered,
# seeded through redirects, keys spread over the primaries, vk follows
# MOVED, vk_flush clears every primary.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"

IFS=, read -r -a nodes <<<"$VALKEY_CLUSTER_NODES"
[[ ${#nodes[@]} -eq 6 ]] || fail "want 6 nodes, got ${#nodes[@]}: $VALKEY_CLUSTER_NODES"
[[ "${nodes[0]}" == "$VALKEY_HOST:$VALKEY_PORT" ]] || fail "VALKEY_PORT is not the first node"
[[ -z "${VALKEY_SOCKET:-}" ]] || fail "VALKEY_SOCKET set in cluster mode"
info=$(vk CLUSTER INFO)
grep -q 'cluster_state:ok' <<<"$info" || fail "cluster_state: $info"
grep -q 'cluster_slots_assigned:16384' <<<"$info" || fail "slots: $info"
grep -q 'cluster_known_nodes:6' <<<"$info" || fail "known nodes: $info"
# Flags field: "master", "myself,master", "slave", ...
[[ $(vk CLUSTER NODES | grep -cE '[ ,]master ') -eq 3 && $(vk CLUSTER NODES | grep -cE '[ ,]slave ') -eq 3 ]] \
  || fail "want 3 primaries + 3 replicas: $(vk CLUSTER NODES)"
echo "ok: 3 primaries + 3 replicas, all slots"

[[ "$(vk GET app:greeting)" == "hello world" ]] || fail "seed via redirects"
[[ "$(vk ZSCORE leaderboard bob)" == 25 ]] || fail "seed zset"
for i in $(seq 1 30); do vk SET "k$i" "$i" >/dev/null; done
holders=0
for n in "${nodes[@]}"; do
  role=$(valkey-cli -h "${n%:*}" -p "${n#*:}" ROLE | head -1)
  [[ "$role" == master ]] || continue
  (( $(valkey-cli -h "${n%:*}" -p "${n#*:}" DBSIZE) > 0 )) && holders=$((holders + 1))
done
(( holders == 3 )) || fail "keys on $holders of 3 primaries"
echo "ok: keys spread over every primary; vk follows redirects"

vk_flush
for n in "${nodes[@]}"; do
  role=$(valkey-cli -h "${n%:*}" -p "${n#*:}" ROLE | head -1)
  [[ "$role" == master ]] || continue
  [[ "$(valkey-cli -h "${n%:*}" -p "${n#*:}" DBSIZE)" == 0 ]] || fail "vk_flush left keys on $n"
done
echo "ok: vk_flush on every primary"
echo "PASS"
