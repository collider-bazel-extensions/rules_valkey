# rules_valkey

Bazel rules for [Valkey](https://valkey.io), the open-source key-value store that continues Redis 7.2. They check configs at build time, run a hermetic Valkey (a single server or a sharded cluster) in tests, and install Valkey into a cluster. Three families in one repo:

- **Config (build time)**
  - `valkey_config` — a `valkey.conf`, plus an optional ACL file. valkey-server itself loads it as a validation action, so an unknown directive, a bad value or a broken ACL rule fails `bazel build` with Valkey's own message.
- **Hermetic server (test time)**
  - `valkey_server` — a long-running valkey-server on a free port, or with `shards` a Valkey Cluster. It optionally runs seed commands, loads a `dump.rdb` and requires a password, then writes `$TEST_TMPDIR/<name>.env` once ready.
  - `valkey_health_check` — pairs with `valkey_server` for `itest_service`.
  - `valkey_test` — `sh_test` macro with an auto-launched server and `vk` helpers.
- **Cluster install (kind / production-shaped)**
  - `valkey_install` — applies the pinned official [valkey-io Helm chart](https://github.com/valkey-io/valkey-helm), optionally with your config, and waits for `deploy/valkey`.
  - `valkey_install_health_check` — paired readiness probe.

No host `valkey-server` or compiler needed. The binaries come from a pinned, SHA-256-verified conda-forge closure: valkey-server plus OpenSSL, and on Linux the GCC runtime. They need nothing from the host beyond libc. The rules need `python3` on the host.

## Install (Bzlmod)

```python
bazel_dep(name = "rules_valkey", version = "0.1.0")
git_override(
    module_name = "rules_valkey",
    remote = "https://github.com/collider-bazel-extensions/rules_valkey",
    tag = "v0.1.0",
)

# rules_valkey depends on rules_kubectl, which isn't in the BCR either.
bazel_dep(name = "rules_kubectl", version = "0.2.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "81b60ab80df46b64c612f2576ffef0a7af98ccb6",  # v0.2.0
)

valkey = use_extension("@rules_valkey//:extensions.bzl", "valkey")
valkey.version(version = "9.1.3")
use_repo(
    valkey,
    "valkey_9_1_3_darwin_amd64",
    "valkey_9_1_3_darwin_arm64",
    "valkey_9_1_3_linux_amd64",
    "valkey_9_1_3_linux_arm64",
)
```

To pin by archive and integrity instead of a git tag, replace the first `git_override` with:

```python
archive_override(
    module_name = "rules_valkey",
    urls = ["https://github.com/collider-bazel-extensions/rules_valkey/archive/refs/tags/v0.1.0.tar.gz"],
    strip_prefix = "rules_valkey-0.1.0",
    integrity = "sha256-",
)
```

The `valkey` extension only honours the root module's `version` tags (the `mod.is_root` guard used across this organization), so declare it in your own `MODULE.bazel`. rules_valkey registers the toolchains itself.

## Config

```python
load("@rules_valkey//:defs.bzl", "valkey_config")

valkey_config(
    name = "config",
    src = "valkey.conf",
    acl = "users.acl",        # optional; used whatever path `aclfile` names
)
```

- **One config everywhere.** Check it in, and the same file is checked on every build, run by `valkey_server` / `valkey_test`, and installed by `valkey_install`.
- **Host paths are overridden, not rejected.** A production config names host paths and settings: `dir`, `logfile`, `pidfile`, `aclfile`, `unixsocket`, `daemonize`, `supervised`, `cluster-config-file`. rules_valkey comments these out in a staged copy, keeping line numbers, and supplies its own values. Everything else (memory limits, eviction policy, persistence, keyspace events, …) applies as written.
- **Errors are Valkey's own**, for example:

  ```
  valkey_config: tests/testdata/bad_value.conf: valkey-server refused it:
    *** FATAL CONFIG FILE ERROR (Version 9.1.3) ***
    Reading the configuration file, at line 1
    >>> 'maxmemory banana'
    argument must be a memory value
  ```

- **No network.** The check runs with TCP off, on a unix socket only. It works with `--sandbox_default_allow_network=false`.

## Hermetic server

### `valkey_test`

```python
load("@rules_valkey//:defs.bzl", "valkey_test")

valkey_test(
    name = "cache_test",
    srcs = ["cache_test.sh"],
    config = ":config",
    seed = ["fixtures.valkey"],
    data = [":my_service"],
)

valkey_test(
    name = "cluster_test",            # a 3-primary / 3-replica Valkey Cluster
    srcs = ["cluster_test.sh"],
    shards = 3,
    replicas = 1,
)
```

```sh
# cache_test.sh
source "$VALKEY_TESTLIB"
./my_service --valkey "$VALKEY_URL" &
vk_wait "ready" GET service:status          # wait for the service to write it
[[ "$(vk HGET user:1 name)" == ada ]]
vk_flush
```

Seed files hold one valkey-cli command per line, run in order. Quoting follows valkey-cli's rules:

```
SET app:greeting "hello world"
HSET app:user:1 name ada email ada@example.com
ZADD leaderboard 10 alice 25 bob
```

Any error reply fails the start and names the file. In a cluster, seed commands follow redirects.

What the test sees:

| Variable | |
|---|---|
| `VALKEY_HOST`, `VALKEY_PORT` | the server; in a cluster, the first primary |
| `VALKEY_URL` | `redis://[:password@]127.0.0.1:<port>` (Redis and Valkey clients accept it) |
| `VALKEY_SOCKET` | unix socket (standalone only) |
| `VALKEY_CLUSTER_NODES` | `127.0.0.1:<p1>,127.0.0.1:<p2>,…` (cluster only; every node) |
| `VALKEY_PASSWORD`, `VALKEYCLI_AUTH` | with `password` (valkey-cli reads `VALKEYCLI_AUTH`) |
| `VALKEY_CLI`, `VALKEY_SERVER` | the binaries; `valkey-cli` is also on `PATH` |
| `VALKEY_TESTLIB` | shell helpers (below) |

| Helper | |
|---|---|
| `vk ARGS…` | `valkey-cli` against the server, raw output; follows redirects in a cluster |
| `vk_wait EXPECTED ARGS…` | waits until `vk ARGS` prints `EXPECTED` (`$VK_WAIT_TIMEOUT`, default 30 s) |
| `vk_flush` | `FLUSHALL` on every primary |

| `valkey_test` / `valkey_server` argument | Default | |
|---|---|---|
| `config` | none | a `valkey_config` (host paths overridden) |
| `password` | none | `requirepass` (and `masterauth` in a cluster) |
| `seed` | `[]` | valkey-cli command files, run in order |
| `rdb` | none | a `dump.rdb` to start from (standalone only) |
| `shards` | `0` | `0` = one server; `N` ≥ 3 = a Valkey Cluster of N primaries |
| `replicas` | `0` | replicas per primary (cluster only) |
| `ready_timeout` | `30` | seconds to wait for the server or cluster |
| `extra_args` | `[]` | extra valkey-server options, e.g. `["--maxmemory", "32mb"]` |
| `args`, `env`, `data`, `deps`, `size`, `timeout`, `tags`, … | | as for `sh_test` (`valkey_test` only) |

**Readiness.** The server counts as ready when:
- every node answers `PING` (not `-LOADING`);
- in a cluster, every node also reports `cluster_state:ok` with all nodes known;
- the seeds have run.

A standalone server is ready in about 0.2 s, a 3-shard cluster in about 2 s.

**Failures.** The test fails, names the cause and shows the server's log if the server refuses its config, exits, or isn't ready within `ready_timeout`, or if a seed command fails. The test body never runs. Each test gets its own server(s), with their own ports and data, so tests are safe under `--jobs=N`. The servers are stopped when the test ends.

### `valkey_server` + `valkey_health_check` (rules_itest)

```python
valkey_server(name = "valkey", config = ":config", seed = ["fixtures.valkey"], tags = ["manual"])
valkey_health_check(name = "valkey_health", server = ":valkey", tags = ["manual"])

itest_service(
    name = "valkey_svc",
    exe = ":valkey",
    health_check = ":valkey_health",
)
```

The server writes `$TEST_TMPDIR/valkey.env` (named after the target) with the variables above. A service or test in any language reads it, or takes `VALKEY_URL` from a wrapper. SIGTERM stops every node, removes the file and exits 0.

## Cluster install

```python
load("@rules_valkey//:defs.bzl", "valkey_install", "valkey_install_health_check")

valkey_install(name = "valkey_install", config = ":config", namespace = "cache", tags = ["manual"])
valkey_install_health_check(name = "valkey_install_health", namespace = "cache", tags = ["manual"])

itest_service(
    name = "valkey_install_svc",
    exe = ":valkey_install",
    health_check = ":valkey_install_health",
    deps = [":kind_svc"],
)
```

- **What's rendered:** the official `valkey` chart with one primary, no replicas and no persistence (`config/valkey-values.yaml`). Every object is named `valkey`: a Deployment and a Service on port 6379.
- **Namespace:** the rendered objects carry none, so `namespace` really places them (default `valkey`).
- **Your config:** with `config`, the chart's `valkey-config` ConfigMap is replaced at build time by your `valkey.conf`. Before that:
  - host paths (`dir`, `logfile`, …) are commented out;
  - so are `port`, `bind` and `protected-mode`, because the chart's init container supplies its base config (port 6379, bind `*`, dir `/data`) and appends yours.

  A config with an ACL file is refused, because the pre-rendered chart mounts only `valkey.conf`.
- **Smoke test:** `tests/install_smoke/` installs into kind (namespace `cache`). It checks that the config runs and that data written in the pod reads back through the Service from a second pod.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| valkey-server (+ valkey-cli, check-rdb/aof) | `9.1.3` | conda-forge `valkey-server` closure (`private/conda_versions.bzl`) |
| Helm chart | `valkey-0.12.1` (appVersion 9.1.3) | https://github.com/valkey-io/valkey-helm/releases (asset digest) |

Maintainer flows:
- **New binaries:** run `python3 tools/update_conda_versions.py --refresh <version> > private/conda_versions.bzl`. It resolves the closure for all four platforms from conda-forge's repodata, with SHA-256s.
- **Chart:** edit `tools/versions.bzl` and `tools/BUILD.bazel`, then run `tools/render_valkey.sh <version>`. No host helm is needed. CI fails if the committed manifest drifts from the render.

## Development

```sh
bazel test //tests/...                                                # no container runtime
bazel test //tests/install_smoke:smoke_test --test_output=streamed    # needs Docker or podman
```

See [DESIGN.md](DESIGN.md) for the architecture and trade-offs.
