#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where valkey listened.
set -euo pipefail
echo "$VALKEY_PORT" > "$RECORD_FILE"
