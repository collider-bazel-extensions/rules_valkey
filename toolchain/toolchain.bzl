"""valkey_toolchain — exposes the platform-resolved Valkey binaries as a
`ToolchainInfo`, so rules resolve them via
`ctx.toolchains["@rules_valkey//toolchain:valkey"]`.

`current_valkey_toolchain` forwards them as a plain target (files +
runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "ValkeyBinaryInfo")

VALKEY_TOOLCHAIN_TYPE = Label("//toolchain:valkey")

def _toolchain_impl(ctx):
    files = depset(
        [ctx.file.server, ctx.file.cli, ctx.file.check_rdb, ctx.file.check_aof],
        transitive = [ctx.attr.libs[DefaultInfo].files],
    )
    info = ValkeyBinaryInfo(
        version   = ctx.attr.version,
        server    = ctx.file.server,
        cli       = ctx.file.cli,
        check_rdb = ctx.file.check_rdb,
        check_aof = ctx.file.check_aof,
        files     = files,
    )
    return [
        platform_common.ToolchainInfo(valkey = info),
        DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files)),
    ]

valkey_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version":   attr.string(mandatory = True),
        "server":    attr.label(allow_single_file = True, mandatory = True),
        "cli":       attr.label(allow_single_file = True, mandatory = True),
        "check_rdb": attr.label(allow_single_file = True, mandatory = True),
        "check_aof": attr.label(allow_single_file = True, mandatory = True),
        "libs":      attr.label(mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[VALKEY_TOOLCHAIN_TYPE].valkey
    return [
        info,
        DefaultInfo(files = info.files, runfiles = ctx.runfiles(transitive_files = info.files)),
    ]

current_valkey_toolchain = rule(
    implementation = _current_impl,
    toolchains = [VALKEY_TOOLCHAIN_TYPE],
    doc = "The resolved Valkey binaries and their libraries, as files and runfiles.",
)
