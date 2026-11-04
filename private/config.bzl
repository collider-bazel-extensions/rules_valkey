"""valkey_config — a valkey.conf (plus ACL file) checked by valkey-server
itself at build time.

valkey-server has no "check config" command, so the validation action
starts it on the config with TCP off and a unix socket in a scratch dir,
overriding every setting that points at the host (dir, logfile, pidfile,
daemonize, cluster-config-file; aclfile when `acl` is given). A config it
refuses fails `bazel build` with valkey-server's own message, e.g.

    >>> 'maxmemory banana'
    argument must be a memory value
"""

load(":providers.bzl", "ValkeyConfigInfo")

_TOOLCHAIN = "//toolchain:valkey"

def _valkey_config_impl(ctx):
    vk = ctx.toolchains[_TOOLCHAIN].valkey
    config = ctx.actions.declare_file(ctx.label.name + "/valkey.conf")
    ctx.actions.symlink(output = config, target_file = ctx.file.src)
    acl = None
    files = [config]
    if ctx.file.acl:
        acl = ctx.actions.declare_file(ctx.label.name + "/users.acl")
        ctx.actions.symlink(output = acl, target_file = ctx.file.acl)
        files.append(acl)

    marker = ctx.actions.declare_file(ctx.label.name + ".checked")
    args = ctx.actions.args()
    args.add(ctx.file._launcher)
    args.add("check")
    args.add("--server", vk.server)
    args.add("--marker", marker)
    args.add("--config", config)
    if acl:
        args.add("--acl", acl)
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [args],
        inputs = depset(files + [ctx.file._launcher], transitive = [vk.files]),
        outputs = [marker],
        # python3 from the user's PATH, as for the test-time launcher.
        use_default_shell_env = True,
        mnemonic = "ValkeyCheckConfig",
        progress_message = "Checking valkey config %{label}",
    )
    return [
        DefaultInfo(files = depset(files)),
        ValkeyConfigInfo(config = config, acl = acl, files = depset(files)),
        OutputGroupInfo(_validation = depset([marker])),
    ]

valkey_config = rule(
    implementation = _valkey_config_impl,
    doc = "A valkey.conf (and optional ACL file), loaded by valkey-server on every build.",
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The valkey.conf.",
        ),
        "acl": attr.label(
            allow_single_file = True,
            doc = "An ACL file (`user ...` lines). Used as the server's " +
                  "aclfile, whatever path the config's `aclfile` names.",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)
