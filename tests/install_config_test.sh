#!/usr/bin/env bash
# valkey_install(config = ...) replaces exactly the chart's `valkey-config`
# ConfigMap data with our valkey.conf and leaves every other document
# byte-for-byte unchanged.
set -euo pipefail

root="$TEST_SRCDIR/$TEST_WORKSPACE"
orig="$root/$1"
got="$root/$2"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $(grep -c '^kind: ' "$got") -eq $(grep -c '^kind: ' "$orig") ]] || fail "document count changed"
cm=$(awk '/^kind: ConfigMap/{p=1} p && /^---/{exit} p' "$got")
grep -q '^  name: valkey-config$' <<<"$cm" || fail "first ConfigMap is not valkey-config"
grep -q '^  valkey.conf: |$' <<<"$cm" || fail "no valkey.conf key"
grep -q '^    maxmemory 64mb$' <<<"$cm" || fail "our config not indented under the key"
grep -q '^    maxmemory-policy allkeys-lru$' <<<"$cm" || fail "policy missing"
grep -q '^    aclfile' <<<"$cm" && fail "aclfile line should have been dropped by the genrule"
# Host paths are commented out: the chart's /data and port 6379 apply.
grep -q '^    # rules_valkey overrides: dir /var/lib/valkey$' <<<"$cm" || fail "dir not neutralized"
grep -q '^    # rules_valkey overrides: logfile ' <<<"$cm" || fail "logfile not neutralized"
grep -qE '^    (dir|logfile|port|bind) ' <<<"$cm" && fail "a host or network directive is still active"
grep -q 'rules_valkey default' <<<"$cm" && fail "chart's default config still present"

# Everything outside valkey-config is unchanged.
strip_cm() { awk '/^  name: valkey-config$/{skip=1} /^---/{skip=0} !skip' "$1"; }
diff <(strip_cm "$orig") <(strip_cm "$got") || fail "documents other than valkey-config changed"
echo "PASS"
