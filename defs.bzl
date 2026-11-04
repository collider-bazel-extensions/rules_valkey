"""Public API for rules_valkey.

Config (build time):
  valkey_config        — valkey.conf (+ ACL file), loaded by valkey-server
                         itself as a validation action on every build.

Hermetic server (test-time):
  valkey_server        — long-running valkey-server, standalone or a
                         sharded Valkey Cluster; writes
                         $TEST_TMPDIR/<name>.env once ready and seeded.
  valkey_health_check  — pairs with valkey_server for itest_service.
  valkey_test          — sh_test macro: auto-launched server.

Cluster install:
  valkey_install / valkey_install_health_check — the pinned official
                         valkey-io Helm chart, optionally with your config.
"""

load("//private:config.bzl", _valkey_config = "valkey_config")
load("//private:install.bzl",
     _valkey_install = "valkey_install",
     _valkey_install_health_check = "valkey_install_health_check")
load("//private:providers.bzl",
     _ValkeyBinaryInfo = "ValkeyBinaryInfo",
     _ValkeyConfigInfo = "ValkeyConfigInfo")
load("//private:server.bzl",
     _ValkeyServerInfo = "ValkeyServerInfo",
     _valkey_health_check = "valkey_health_check",
     _valkey_server = "valkey_server")
load("//private:test.bzl", _valkey_test = "valkey_test")

valkey_config = _valkey_config
valkey_server = _valkey_server
valkey_health_check = _valkey_health_check
valkey_test = _valkey_test
valkey_install = _valkey_install
valkey_install_health_check = _valkey_install_health_check
ValkeyBinaryInfo = _ValkeyBinaryInfo
ValkeyConfigInfo = _ValkeyConfigInfo
ValkeyServerInfo = _ValkeyServerInfo
