#!/usr/bin/env bash
# Helpers for valkey_test scripts:  source "$VALKEY_TESTLIB"
#
#   vk ARGS...                  valkey-cli against the server, raw output
#                               (follows redirects in a cluster)
#   vk_wait EXPECTED ARGS...    wait until `vk ARGS` prints EXPECTED
#                               ($VK_WAIT_TIMEOUT seconds, default 30)
#   vk_flush                    FLUSHALL on every primary
#
# `valkey-cli` is also on PATH, and VALKEYCLI_AUTH is set when the server
# has a password.

vk() {
  local cluster=()
  [[ -z "${VALKEY_CLUSTER_NODES:-}" ]] || cluster=(-c)
  "$VALKEY_CLI" -h "$VALKEY_HOST" -p "$VALKEY_PORT" "${cluster[@]}" "$@"
}

vk_wait() {
  local want="$1"; shift
  local deadline=$(( $(date +%s) + ${VK_WAIT_TIMEOUT:-30} )) got
  while :; do
    got="$(vk "$@" 2>&1)" || true
    [[ "$got" == "$want" ]] && return 0
    if (( $(date +%s) >= deadline )); then
      echo "vk_wait: \`$*\` printed '$got', not '$want', after ${VK_WAIT_TIMEOUT:-30}s" >&2
      return 1
    fi
    sleep 0.1
  done
}

vk_flush() {
  if [[ -n "${VALKEY_CLUSTER_NODES:-}" ]]; then
    "$VALKEY_CLI" --cluster call "$VALKEY_HOST:$VALKEY_PORT" FLUSHALL --cluster-only-masters >/dev/null
  else
    vk FLUSHALL >/dev/null
  fi
}
