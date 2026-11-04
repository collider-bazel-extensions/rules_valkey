#!/usr/bin/env bash
# Inner test for server_died_test: kills the server (not via valkey_stop),
# then would carry on.
source "$VALKEY_TESTLIB"
vk SHUTDOWN NOSAVE >/dev/null 2>&1 || true
sleep 60
echo "BODY FINISHED"
