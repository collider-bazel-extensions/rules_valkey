#!/usr/bin/env bash
# Fails when any conda pin in private/conda_versions.bzl lacks a 64-hex
# SHA-256, or a platform has no valkey-server package. No network.
set -euo pipefail

f="${TEST_SRCDIR}/_main/private/conda_versions.bzl"
urls=$(grep -cE '"url":' "$f" || true)
pinned=$(grep -cE '"sha256":[[:space:]]*"[0-9a-f]{64}"' "$f" || true)
servers=$(grep -cE '"name":[[:space:]]*"valkey-server"' "$f" || true)
echo "urls=$urls pinned=$pinned valkey-server=$servers"
if [[ "$urls" -eq 0 || "$pinned" -ne "$urls" || "$servers" -ne 4 ]]; then
  echo "FAIL: every URL needs a 64-hex SHA-256, and each of the 4 platforms a valkey-server" \
       "(python3 tools/update_conda_versions.py --refresh <version> > private/conda_versions.bzl)" >&2
  exit 1
fi
echo "PASS"
