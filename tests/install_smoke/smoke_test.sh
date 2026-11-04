#!/usr/bin/env bash
# Full E2E install smoke for valkey_install(config = ...) in namespace
# `cache`:
#
#   1. The itest chain (kind → valkey_install) has applied the chart with
#      our valkey.conf and waited for deploy/valkey to roll out.
#   2. kubectl exec valkey-cli in the pod: our config is running
#      (maxmemory 64mb, allkeys-lru), and a write round-trips.
#   3. The Service answers from a second pod (valkey-cli in the same
#      image, against valkey.cache.svc).
set -euo pipefail

env_file="$TEST_TMPDIR/cluster.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")
NS=cache
fail() {
  echo "smoke: FAIL — $*" >&2
  "${KCTL[@]}" -n "$NS" get pods,svc -o wide >&2 || true
  "${KCTL[@]}" -n "$NS" logs deploy/valkey --tail=100 >&2 || true
  exit 1
}

CLI=("${KCTL[@]}" -n "$NS" exec deploy/valkey -c valkey -- valkey-cli)
[[ "$("${CLI[@]}" CONFIG GET maxmemory | tail -1)" == 67108864 ]] || fail "maxmemory: $("${CLI[@]}" CONFIG GET maxmemory)"
[[ "$("${CLI[@]}" CONFIG GET maxmemory-policy | tail -1)" == allkeys-lru ]] || fail "maxmemory-policy"
echo "smoke: our valkey.conf is running (maxmemory 64mb, allkeys-lru)"

"${CLI[@]}" SET smoke:key "from the smoke test" >/dev/null || fail "SET"
[[ "$("${CLI[@]}" GET smoke:key)" == "from the smoke test" ]] || fail "GET"
echo "smoke: write round-trips in the pod"

image=$("${KCTL[@]}" -n "$NS" get deploy valkey -o jsonpath='{.spec.template.spec.containers[0].image}')
got=$("${KCTL[@]}" -n "$NS" run smoke-client --rm -i --restart=Never --quiet --image="$image" \
      --command -- valkey-cli -h "valkey.$NS.svc" GET smoke:key) || fail "client pod: $got"
[[ "$got" == "from the smoke test" ]] || fail "Service read: '$got'"
echo "smoke: OK — valkey.$NS.svc serves our data to another pod"
