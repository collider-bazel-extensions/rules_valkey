# rules_valkey — design notes

rules_valkey follows the shape of rules_prometheus, rules_alertmanager and rules_flagd: a toolchain, a build-time check run as a validation action, a launcher-based hermetic server with a health check and an `sh_test` macro, and an install over a pre-rendered chart. These notes cover what is specific to Valkey.

## Binaries: a conda-forge closure

Valkey's GitHub releases carry no binaries. download.valkey.io has Ubuntu (jammy and noble) tarballs for Linux only, and they link against the host's libssl 3, libsystemd and zlib. conda-forge's `valkey-server` covers linux and macOS on amd64 and arm64, at the same version on release day. It links only against OpenSSL and the GCC runtime from the same channel.

So the toolchain uses rules_pg's approach:
- `tools/update_conda_versions.py`, adapted from rules_pg, resolves the transitive closure from conda-forge's repodata and pins each package's URL and SHA-256 in `private/conda_versions.bzl`. That is 6 packages on Linux and 3 on macOS.
- The repository rule extracts every package into one tree. Conda binaries carry `RPATH=$ORIGIN/../lib`, so `bin/valkey-server` finds `lib/libssl.so.3` next to it, through runfiles symlinks too.
- Unlike rules_pg, it needs no host `unzip` or `zstd`. Bazel extracts both the `.conda` zip and the inner `pkg-*.tar.zst` itself.

`//tests:checksums_test` fails on an empty or malformed pin, or if a platform has no `valkey-server`.

## `valkey_config`: valkey-server as the checker

valkey-server has no "check config" command, so the validation action starts it on the config:
- TCP is off (`--port 0`) and the server listens on a unix socket in a short scratch dir.
- Socket paths must be under 108 bytes, and Bazel's tmpdirs are longer, so the scratch dir is under `/tmp`.
- Ready means its log says "Ready to accept connections". If it exits instead, its own error is the message: the `FATAL CONFIG FILE ERROR` block with line and directive, or the ACL error.

**Host directives.** A real config names host paths. valkey-server applies some of them *while parsing*: `dir` chdirs, and `logfile` is opened. So command-line overrides come too late; a missing `/var/lib/valkey` fails before they apply. The launcher therefore stages a copy with the host directives commented out *in place*, so line numbers in errors still match:
- `dir`, `logfile`, `pidfile`;
- `aclfile`, `unixsocket`, `unixsocketperm`;
- `daemonize`, `supervised`, `cluster-config-file`.

It then passes its own values. The ACL file comes from `valkey_config(acl = ...)` whatever path `aclfile` names.

The check runs on the conda binary with no network: loopback and a unix socket only.

## Hermetic server

- **Standalone:** one server on a free port, bound to 127.0.0.1, plus a unix socket in a short `/tmp` dir.
  - **Ready** means `PING` answers `+PONG`. With a password the launcher sends `AUTH` first. `-LOADING` (while a `dump.rdb` loads) is not ready. `-NOAUTH`/`-WRONGPASS` count as up, because an ACL file may leave the launcher no user it can log in as.
- **Cluster (`shards` ≥ 3):** `shards × (1 + replicas)` servers start with `cluster-enabled yes`. Each gets an explicit `--cluster-port`, a second free port, because the default port+10000 could collide. They are joined by `valkey-cli --cluster create --cluster-replicas R --cluster-yes`.
  - **Ready** means every node reports `cluster_state:ok` *and* knows every other node. One node's view isn't enough, because a client may connect to any of them.
- **Seeding:** each seed file goes through `valkey-cli --no-raw`, with `-c` in a cluster. `valkey-cli -e` doesn't fail on errors in piped input. In `--no-raw` mode, errors are printed as `(error) …` and string replies are quoted, so error lines are unambiguous. Any error reply fails the start, naming the file.
- **Environment:**
  - `VALKEY_URL` uses the `redis://` scheme, which Valkey and Redis clients accept.
  - `VALKEYCLI_AUTH` lets `valkey-cli` and `vk` log in without `-a`.
  - The server and seed steps scrub `VALKEYCLI_AUTH` / `REDISCLI_AUTH` from their own environment, so a sourced env file can't change them.
- **Shutdown and cleanup:**
  - Signal handlers are installed before start. Once ready, the handler only terminates the servers and arms kill timers; it must not `wait()`.
  - If any node dies, all are stopped.
  - The socket dir is removed on exit.

### Stop and start (v0.2, #1)

- **The endpoint.** The launcher runs a small HTTP control endpoint (`VALKEY_CONTROL_URL`: `POST /stop`, `/start`, optional `?node=N`), as rules_flagd and rules_otel do. HTTP rather than signals, because `/start` must report whether the server came back.
- **Stopping** is a SIGTERM: Valkey's `SHUTDOWN` path, which saves an RDB when save points are configured (the default) and fsyncs the AOF. The node is marked as stopped on request, so the launcher doesn't treat its exit as a crash.
- **Starting** reuses the node's exact argv (port, cluster bus port, data dir, password, TLS) and appends to its log. Readiness is judged on this start's part of the log and a real `PING`.
- **A taken port.** Each port is bind-checked (127.0.0.1 with `SO_REUSEADDR`, as valkey-server binds) before the start. A taken port is retried 5 times, 0.2 s apart, then reported as a 500 naming it. These are lessons from rules_flagd v0.3.0, where a failed bind cost a 5 s drain.
- **Cluster nodes** restart individually and rejoin from `nodes.conf`. After a start the launcher waits for `cluster_state:ok` on every node.

### TLS (v0.2, #1)

- **TLS only.** `tls = True` runs `--port 0 --tls-port P`: no plaintext listener and no unix socket. Clusters add `--tls-cluster yes --tls-replication yes`.
- **Certificates.** The conda closure ships `bin/openssl`, so the launcher makes a throwaway CA, a server certificate (SAN `127.0.0.1`, `localhost`; serverAuth + clientAuth, since replication connects with it) and a client certificate.
  - That openssl looks for its config under its build-time prefix, so the launcher passes a minimal `OPENSSL_CONF`.
  - The CA carries `basicConstraints=critical,CA:TRUE` and the leaves key identifiers. Python 3.13+ verifies strictly and rejects a CA without them.
- **Your own certificates:** `tls_cert` / `tls_key` / `tls_ca`, plus the client pair when `tls_auth_clients` is set. Analysis refuses incomplete sets.
- **Inside the launcher,** readiness `PING`s go through Python's `ssl`, and seeds through `valkey-cli --tls`.

### Watching the server

`valkey_test` uses rules_nats' fixed trampoline (v0.1.1):
- it removes its own arguments before the test sees `"$@"`;
- it runs the test rather than `exec`ing it, so its EXIT trap stops the servers;
- HUP, INT and TERM exit 129, 130 and 143.

`//tests:server_cleanup_test` fails if the trampoline `exec`s.

Since v0.2 (#1) the trampoline also watches the server:
- it runs the test in the background (stdin kept) and polls both pids, because bash 3.2 (macOS) has no `wait -n`;
- if the launcher exits first, which `valkey_stop` doesn't cause, it stops the test's whole process tree (walked with `pgrep -P`, exact parent pid). It then fails with the server's status and the tail of `$VALKEY_LOG`.

Otherwise the test's own exit status is returned. Killing only the test's shell isn't enough: in the first version an orphaned `sleep` kept the test's output open for a minute.

## Cluster install

- **The chart:** the official `valkey` chart (valkey-io/valkey-helm 0.12.1, appVersion 9.1.3), pinned by its release asset digest and rendered at maintainer time with rules_helm. The values give one primary with no persistence, and `fullnameOverride: valkey`. The render sets no `metadata.namespace`, so `valkey_install(namespace = ...)` places the objects; rules_kubectl applies with `-n`.
- **Custom config:** `valkey_install(config = ...)` replaces the data of the `valkey-config` ConfigMap with an awk pass, the same overlay as rules_prometheus. Every other document passes through unchanged, which `//tests:install_config_test` checks.
- **Neutralising for the chart.** The chart's init container writes a base config (`port 6379`, `protected-mode no`, `bind * -::*`, `dir /data`) and appends ours. So the overlay comments out the host directives and also `port`, `bind` and `protected-mode`, which the Service depends on.

  The first kind smoke run caught this: the test config's `dir /var/lib/valkey` stopped the pod from starting. The build-time check hadn't seen it, because it neutralises host paths for itself.
- **ACL files.** A config with an ACL file is refused for the install, because the pre-rendered chart mounts only `valkey.conf`.

## What this repo does not (yet) do

- **Sentinel** and Valkey modules (`loadmodule`; conda-forge ships no modules).
- **TLS on the unix socket** and per-client certificate subjects (ACL `CN` mapping).
- **Replicas or persistence in the install**, and the chart's `auth.aclUsers`. These would need re-rendering with other values.
- **Non-shell `valkey_test`.** Use `valkey_server` + `valkey_health_check` through rules_itest.
