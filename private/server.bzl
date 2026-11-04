"""valkey_server + valkey_health_check — hermetic Valkey test fixtures.

`valkey_server` is a long-running executable (see launcher.py): one
valkey-server on a free 127.0.0.1 port, or with `shards` a Valkey Cluster
of that many primaries (plus `replicas` each). Once every node answers
and the seed files have run, it writes `$TEST_TMPDIR/<name>.env`:

    VALKEY_HOST=127.0.0.1
    VALKEY_PORT                   (the first primary in a cluster)
    VALKEY_URL=redis://[:<password>@]127.0.0.1:<port>
    VALKEY_SOCKET                 (standalone only)
    VALKEY_CLUSTER_NODES          (cluster only: host:port,...)
    VALKEY_PASSWORD, VALKEYCLI_AUTH   (with `password`)
    VALKEY_CLI, VALKEY_SERVER

and runs until SIGTERM. `valkey_health_check` exits 0 iff that file
exists; it drops into `itest_service.health_check`.
"""

load(":providers.bzl", "ValkeyConfigInfo")

_TOOLCHAIN = "//toolchain:valkey"

ValkeyServerInfo = provider(
    doc = "A valkey_server target.",
    fields = {
        "binary":   "ValkeyBinaryInfo: the toolchain's binaries.",
        "shards":   "int: cluster primaries (0 = standalone).",
        "replicas": "int: replicas per primary.",
    },
)

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label, repr(value)))
    return raw

def _resolved(flag, path):
    # Resolved into a variable first: a failing $(resolve) inside an
    # argument list would not stop the script under `set -e`.
    return "p=\"$(resolve {})\"; opts+=({} \"$p\")".format(_shell_quote(path), flag)

def _valkey_server_impl(ctx):
    vk = ctx.toolchains[_TOOLCHAIN].valkey
    shards, replicas = ctx.attr.shards, ctx.attr.replicas
    if shards != 0 and shards < 3:
        fail("{}: shards = {}: a Valkey Cluster needs at least 3 primaries (0 = standalone).".format(
            ctx.label, shards))
    if replicas < 0 or (replicas and not shards):
        fail("{}: replicas = {}: replicas apply to a cluster (shards >= 3).".format(ctx.label, replicas))
    if shards and ctx.file.rdb:
        fail("{}: rdb is for a standalone server; seed a cluster with `seed`.".format(ctx.label))
    if "\n" in ctx.attr.password:
        fail("{}: password must be one line.".format(ctx.label))
    tls_given = [a for a in ("tls_cert", "tls_key", "tls_ca") if getattr(ctx.file, a)]
    client_given = [a for a in ("tls_client_cert", "tls_client_key") if getattr(ctx.file, a)]
    if (tls_given or client_given or ctx.attr.tls_auth_clients) and not ctx.attr.tls:
        fail("{}: {} need tls = True.".format(
            ctx.label, ", ".join(tls_given + client_given + (["tls_auth_clients"] if ctx.attr.tls_auth_clients else []))))
    if tls_given and len(tls_given) != 3:
        fail("{}: give tls_cert, tls_key and tls_ca together (or none: generated).".format(ctx.label))
    if client_given and (len(client_given) != 2 or not tls_given):
        fail("{}: tls_client_cert and tls_client_key go together, with tls_cert/tls_key/tls_ca.".format(ctx.label))
    if tls_given and ctx.attr.tls_auth_clients and not client_given:
        fail("{}: tls_auth_clients with your own certificates needs tls_client_cert and " +
             "tls_client_key (signed by tls_ca) for the launcher and the test.".format(ctx.label))

    lines = []
    files = []
    if ctx.attr.config:
        cfg = ctx.attr.config[ValkeyConfigInfo]
        lines.append(_resolved("--config", cfg.config.short_path))
        files.append(cfg.config)
        if cfg.acl:
            lines.append(_resolved("--acl", cfg.acl.short_path))
            files.append(cfg.acl)
    if ctx.file.rdb:
        lines.append(_resolved("--rdb", ctx.file.rdb.short_path))
        files.append(ctx.file.rdb)
    for f in ctx.files.seed:
        lines.append(_resolved("--seed", f.short_path))
        files.append(f)
    for a in ("tls_cert", "tls_key", "tls_ca", "tls_client_cert", "tls_client_key"):
        f = getattr(ctx.file, a)
        if f:
            lines.append(_resolved("--" + a.replace("_", "-"), f.short_path))
            files.append(f)
    if ctx.attr.tls:
        lines.append(_resolved("--openssl", vk.openssl.short_path))
    opts = []
    if ctx.attr.tls:
        opts.append("--tls")
    if ctx.attr.tls_auth_clients:
        opts.append("--tls-auth-clients")
    if ctx.attr.password:
        opts += ["--password", ctx.attr.password]
    if shards:
        opts += ["--shards", str(shards), "--replicas", str(replicas)]

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__":          ctx.label.name,
            "__LAUNCHER__":      ctx.file._launcher.short_path,
            "__SERVER__":        vk.server.short_path,
            "__CLI__":           vk.cli.short_path,
            "__READY_TIMEOUT__": check_timeout(ctx.label, ctx.attr.ready_timeout),
            "__FILES__":         "\n".join(lines),
            "__OPTS__":          " ".join([_shell_quote(o) for o in opts]),
            "__EXTRA_ARGS__":    " ".join([_shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._launcher] + files, transitive_files = vk.files)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        ValkeyServerInfo(binary = vk, shards = shards, replicas = replicas),
    ]

valkey_server = rule(
    implementation = _valkey_server_impl,
    executable = True,
    doc = """\
Long-running valkey-server (standalone or a Valkey Cluster) for tests and
rules_itest compositions. Writes `$TEST_TMPDIR/<name>.env` once every
node answers PING (and, for a cluster, reports cluster_state:ok) and the
seed files have run. If a server refuses its config, exits, isn't ready
within `ready_timeout`, or a seed command fails, it exits non-zero,
naming the cause.
""",
    attrs = {
        "config": attr.label(
            providers = [ValkeyConfigInfo],
            doc = "A valkey_config. Its host-specific settings (port, bind, " +
                  "dir, logfile, ...) are overridden; everything else applies.",
        ),
        "password": attr.string(
            doc = "requirepass (and masterauth in a cluster). Exported as " +
                  "VALKEY_PASSWORD and VALKEYCLI_AUTH, and in VALKEY_URL.",
        ),
        "seed": attr.label_list(
            allow_files = True,
            doc = "Files of valkey-cli commands, one per line, run in order " +
                  "once the server is up (following cluster redirects). Any " +
                  "error reply fails the start.",
        ),
        "rdb": attr.label(
            allow_single_file = True,
            doc = "A dump.rdb to start from (standalone only).",
        ),
        "shards": attr.int(
            default = 0,
            doc = "0: one standalone server. N >= 3: a Valkey Cluster of N primaries.",
        ),
        "replicas": attr.int(
            default = 0,
            doc = "Replicas per primary in a cluster.",
        ),
        "ready_timeout": attr.string(
            default = "30",
            doc = "Seconds to wait for the server (or cluster) to be ready.",
        ),
        "extra_args": attr.string_list(
            doc = "Extra valkey-server options, e.g. [\"--maxmemory\", \"64mb\"].",
        ),
        "tls": attr.bool(
            doc = "Listen TLS-only on the chosen port (cluster bus and " +
                  "replication over TLS too). Without tls_cert/tls_key/tls_ca, " +
                  "a throwaway CA and certificates are made at start with the " +
                  "toolchain's openssl. Env: VALKEY_TLS=1, VALKEY_TLS_CA, rediss:// URL.",
        ),
        "tls_auth_clients": attr.bool(
            doc = "Require client certificates (mutual TLS). Exports " +
                  "VALKEY_TLS_CERT / VALKEY_TLS_KEY for the test.",
        ),
        "tls_cert": attr.label(allow_single_file = True, doc = "Server certificate (for 127.0.0.1)."),
        "tls_key": attr.label(allow_single_file = True, doc = "Server key."),
        "tls_ca": attr.label(allow_single_file = True, doc = "CA that signed the certificates."),
        "tls_client_cert": attr.label(allow_single_file = True, doc = "Client certificate (with tls_auth_clients)."),
        "tls_client_key": attr.label(allow_single_file = True, doc = "Client key."),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

# ---- valkey_health_check -----------------------------------------------------

def _valkey_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

valkey_health_check = rule(
    implementation = _valkey_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [ValkeyServerInfo],
            doc = "The valkey_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
