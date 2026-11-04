#!/usr/bin/env bash
# Helpers for valkey_test scripts:  source "$VALKEY_TESTLIB"
#
#   vk ARGS...                  valkey-cli against the server, raw output
#                               (follows redirects in a cluster)
#   vk_wait EXPECTED ARGS...    wait until `vk ARGS` prints EXPECTED
#                               ($VK_WAIT_TIMEOUT seconds, default 30)
#   vk_flush                    FLUSHALL on every primary
#   valkey_stop / valkey_start  stop the server / start it again (below)
#
# `valkey-cli` is also on PATH, and VALKEYCLI_AUTH is set when the server
# has a password.

# valkey-cli's connection options for this server: TLS (CA, and a client
# certificate with tls_auth_clients) when VALKEY_TLS=1.
vk_opts() {
  printf '%s\n' -h "$VALKEY_HOST" -p "$VALKEY_PORT"
  if [[ "${VALKEY_TLS:-}" == 1 ]]; then
    printf '%s\n' --tls --cacert "$VALKEY_TLS_CA"
    [[ -z "${VALKEY_TLS_CERT:-}" ]] || printf '%s\n' --cert "$VALKEY_TLS_CERT" --key "$VALKEY_TLS_KEY"
  fi
}

vk() {
  local opts=() o
  while IFS= read -r o; do opts+=("$o"); done < <(vk_opts)
  [[ -z "${VALKEY_CLUSTER_NODES:-}" ]] || opts+=(-c)
  "$VALKEY_CLI" "${opts[@]}" "$@"
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
    local opts=() o
    while IFS= read -r o; do opts+=("$o"); done < <(vk_opts | tail -n +5)
    "$VALKEY_CLI" ${opts[@]+"${opts[@]}"} --cluster call "$VALKEY_HOST:$VALKEY_PORT" FLUSHALL --cluster-only-masters >/dev/null
  else
    vk FLUSHALL >/dev/null
  fi
}

# valkey_stop [NODE]   stop the server (in a cluster: node NODE, default all).
#                      SIGTERM, as SHUTDOWN: an RDB is saved first when save
#                      points are configured (Valkey's default), AOF fsynced.
# valkey_start [NODE]  start it again on the same port(s), with the same
#                      password, TLS and data dir; waits until it answers
#                      (and, in a cluster, cluster_state:ok).
valkey_stop()  { _vk_control /stop "${1:-}"; }
valkey_start() { _vk_control /start "${1:-}"; }

_vk_control() {  # _vk_control /stop|/start [NODE]
  local url="$VALKEY_CONTROL_URL$1"
  [[ -z "$2" ]] || url="$url?node=$2"
  python3 - "$url" "valkey_${1#/}" <<'PY'
import sys, urllib.error, urllib.request
url, helper = sys.argv[1:]
try:
    urllib.request.urlopen(urllib.request.Request(url, data=b"", method="POST"), timeout=300)
except urllib.error.HTTPError as e:
    sys.exit(f"{helper}: {e.code}: {e.read().decode().strip()}")
PY
}
