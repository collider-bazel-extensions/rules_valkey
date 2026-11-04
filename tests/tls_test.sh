#!/usr/bin/env bash
# tls = True: TLS only on VALKEY_PORT; vk and a plain TLS client with
# VALKEY_TLS_CA work; plaintext is refused. With mutual TLS, a client
# without a certificate is refused too.
#
# Argv: standalone | cluster | mutual | provided
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$VALKEY_TESTLIB"
mode="$1"

[[ "$VALKEY_TLS" == 1 && -f "$VALKEY_TLS_CA" ]] || fail "VALKEY_TLS / VALKEY_TLS_CA"
[[ "$VALKEY_URL" == rediss://* ]] || fail "URL: $VALKEY_URL"
[[ -z "${VALKEY_SOCKET:-}" ]] || fail "a plaintext unix socket is exported under TLS"
if [[ "$mode" == mutual || "$mode" == provided ]]; then
  [[ -f "$VALKEY_TLS_CERT" && -f "$VALKEY_TLS_KEY" ]] || fail "client cert/key not exported"
else
  [[ -z "${VALKEY_TLS_CERT:-}" ]] || fail "client cert exported without tls_auth_clients"
fi

for k in a b c d e; do vk SET "t:$k" "$k" >/dev/null; done
for k in a b c d e; do [[ "$(vk GET "t:$k")" == "$k" ]] || fail "t:$k over TLS"; done
echo "ok: vk over TLS"

# Plaintext on the same port is refused.
if out=$("$VALKEY_CLI" -h 127.0.0.1 -p "$VALKEY_PORT" PING 2>&1) && [[ "$out" == PONG ]]; then
  fail "plaintext PING answered"
fi
echo "ok: plaintext refused ($out)"

# Any TLS client: Python's ssl with the exported CA (and client cert).
python3 - <<'PY' || fail "python TLS client"
import os, socket, ssl
ctx = ssl.create_default_context(cafile=os.environ["VALKEY_TLS_CA"])
if os.environ.get("VALKEY_TLS_CERT"):
    ctx.load_cert_chain(os.environ["VALKEY_TLS_CERT"], os.environ["VALKEY_TLS_KEY"])
cmd = b""
if os.environ.get("VALKEY_PASSWORD"):
    pw = os.environ["VALKEY_PASSWORD"].encode()
    cmd += b"*2\r\n$4\r\nAUTH\r\n$%d\r\n%s\r\n" % (len(pw), pw)
cmd += b"*1\r\n$4\r\nPING\r\n"
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(os.environ["VALKEY_PORT"]))),
                     server_hostname="127.0.0.1") as s:
    s.sendall(cmd)
    data = s.recv(1024)
assert data.endswith(b"+PONG\r\n"), data
PY
echo "ok: a TLS client with VALKEY_TLS_CA"

if [[ "$mode" == mutual || "$mode" == provided ]]; then
  if "$VALKEY_CLI" -h 127.0.0.1 -p "$VALKEY_PORT" --tls --cacert "$VALKEY_TLS_CA" PING 2>/dev/null | grep -q PONG; then
    fail "a client without a certificate was accepted"
  fi
  echo "ok: no client certificate, refused"
fi
if [[ "$mode" == cluster ]]; then
  vk CLUSTER INFO | grep -q cluster_state:ok || fail "cluster over TLS"
  echo "ok: cluster bus and replication over TLS"
fi

valkey_stop && valkey_start
[[ "$(vk GET t:a)" == a ]] || fail "restart under TLS"
echo "ok: restart under TLS"
echo "PASS"
