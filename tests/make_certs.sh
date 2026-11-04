#!/usr/bin/env bash
# make_certs.sh OUT_DIR <toolchain files...>: a CA, a server certificate for
# 127.0.0.1 and a client certificate, with the toolchain's openssl.
set -euo pipefail
out="$1"; shift
openssl=""
for f in "$@"; do [[ "$f" == */bin/openssl ]] && openssl="$f"; done
[[ -n "$openssl" ]] || { echo "make_certs: no bin/openssl among the toolchain files" >&2; exit 1; }
openssl="$(cd "$(dirname "$openssl")" && pwd)/openssl"
mkdir -p "$out"; cd "$out"
printf '[req]\ndistinguished_name = dn\n[dn]\n' > openssl.cnf
export OPENSSL_CONF="$PWD/openssl.cnf"
"$openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=rules_valkey fixture CA" \
  -keyout ca.key -out ca.crt -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,keyCertSign,cRLSign -addext subjectKeyIdentifier=hash 2>/dev/null
leaf() {  # leaf NAME EKU [SAN]
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n%s\n' "$2" "${3:-}" > "$1.ext"
  "$openssl" req -newkey rsa:2048 -nodes -subj "/CN=rules_valkey fixture $1" -keyout "$1.key" -out "$1.csr" 2>/dev/null
  "$openssl" x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
    -extfile "$1.ext" -out "$1.crt" 2>/dev/null
}
leaf server serverAuth,clientAuth "subjectAltName=IP:127.0.0.1,DNS:localhost"
leaf client clientAuth
rm -f ca.key ./*.csr ./*.ext ca.srl openssl.cnf
