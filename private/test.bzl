"""valkey_test — sh_test macro with an auto-launched Valkey.

Each target gets its own valkey_server (own ports, own data dir), so
tests are safe under `--jobs=N`.

The trampoline (valkey_test_trampoline.sh) starts the server, waits for
its env file, sources it (VALKEY_HOST, VALKEY_PORT, VALKEY_URL,
VALKEY_SOCKET or VALKEY_CLUSTER_NODES, VALKEY_PASSWORD / VALKEYCLI_AUTH,
VALKEY_CLI, VALKEY_SERVER), puts valkey-cli on PATH, exports
VALKEY_TESTLIB and runs the test with the target's args. It runs the
test rather than exec'ing it, so it can stop the server when the test
ends.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "valkey_server")

def valkey_test(
        name,
        srcs,
        config = None,
        password = None,
        seed = None,
        rdb = None,
        shards = 0,
        replicas = 0,
        ready_timeout = 30,
        extra_args = None,
        tls = False,
        tls_auth_clients = False,
        tls_cert = None,
        tls_key = None,
        tls_ca = None,
        tls_client_cert = None,
        tls_client_key = None,
        deps = None,
        data = None,
        args = None,
        size = "small",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched Valkey (standalone or cluster).

    Args:
      name: target name.
      srcs: the test script (one file).
      config: a valkey_config.
      password: requirepass for the server.
      seed: files of valkey-cli commands run before the test.
      rdb: a dump.rdb to start from (standalone only).
      shards: 0 for a standalone server; N >= 3 for a Valkey Cluster.
      replicas: replicas per primary in a cluster.
      ready_timeout: seconds to wait for the server.
      extra_args: extra valkey-server options.
      tls: TLS-only server (generated test CA unless tls_cert/tls_key/tls_ca).
      tls_auth_clients: require client certificates (mutual TLS).
      tls_cert: server certificate (with tls_key, tls_ca).
      tls_key: server key.
      tls_ca: CA certificate.
      tls_client_cert: client certificate (tls_auth_clients with your own CA).
      tls_client_key: client key.
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the
        sh_test, so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "small".
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, ...).
    """
    tags = tags or []
    server_name = name + "_valkey"
    valkey_server(
        name = server_name,
        config = config,
        password = password or "",
        seed = seed or [],
        rdb = rdb,
        shards = shards,
        replicas = replicas,
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tls = tls,
        tls_auth_clients = tls_auth_clients,
        tls_cert = tls_cert,
        tls_key = tls_key,
        tls_ca = tls_ca,
        tls_client_cert = tls_client_cert,
        tls_client_key = tls_client_key,
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:valkey_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
            "$(rootpath {})".format(Label("//private:testlib.sh")),
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + server_name,
            ":" + inner_name,
            Label("//private:testlib.sh"),
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
