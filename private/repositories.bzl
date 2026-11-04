"""Per-platform Valkey repo: the pinned conda-forge closure for
valkey-server (server, CLI, openssl and, on Linux, the GCC runtime),
merged into one tree.

Each `.conda` file is a zip holding `pkg-<name>.tar.zst` (the files) and
`info-<name>.tar.zst` (metadata). Bazel extracts both formats itself, so
no host unzip or zstd is needed. Conda binaries carry
RPATH=$ORIGIN/../lib, so they find the merged lib/ next to bin/.
"""

load(":conda_versions.bzl", "CONDA_CLOSURES")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(name = "valkey_server", srcs = ["bin/valkey-server"])

filegroup(name = "valkey_cli", srcs = ["bin/valkey-cli"])

filegroup(name = "valkey_check_rdb", srcs = ["bin/valkey-check-rdb"])

filegroup(name = "valkey_check_aof", srcs = ["bin/valkey-check-aof"])

# The closure's OpenSSL CLI: valkey_server(tls = True) makes its test
# certificates with it.
filegroup(name = "openssl", srcs = ["bin/openssl"])

# Shared libraries the binaries load through their RPATH.
filegroup(name = "libs", srcs = glob(["lib/**"], allow_empty = True))
"""

def _impl(rctx):
    key = (rctx.attr.version, rctx.attr.platform)
    closure = CONDA_CLOSURES.get(key)
    if not closure:
        fail("rules_valkey: no conda closure for valkey {} on {}. Known: {}".format(
            rctx.attr.version, rctx.attr.platform, sorted(CONDA_CLOSURES.keys())))

    for i, pkg in enumerate(closure):
        tmp = "_dl/{}_{}".format(i, pkg["name"])
        rctx.download_and_extract(
            url = pkg["url"],
            sha256 = pkg["sha256"],
            output = tmp,
            type = "zip",
        )
        inner = [p for p in rctx.path(tmp).readdir() if p.basename.startswith("pkg-")]
        if len(inner) != 1:
            fail("rules_valkey: {} has no pkg-*.tar.zst".format(pkg["url"]))
        rctx.extract(inner[0], output = ".")
    rctx.delete("_dl")

    for b in ("valkey-server", "valkey-cli", "openssl"):
        if not rctx.path("bin/" + b).exists:
            fail("rules_valkey: bin/{} missing from the conda closure".format(b))
    rctx.file("BUILD.bazel", _BUILD)

valkey_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)
