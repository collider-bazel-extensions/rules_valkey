"""Bzlmod extension. Single `version` tag — fetches the conda-forge valkey-server closure
for each supported platform.
"""

load("//private:conda_versions.bzl", "CONDA_CLOSURES")
load("//private:repositories.bzl", "valkey_binary_repo")
load("//private:versions.bzl", "DEFAULT_VERSION", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "9.1.3"
})

def _impl(mctx):
    # The extension runs once for the whole build and sees every module's
    # tags. Repos are named by version (`valkey_<ver>_<plat>`), so versions
    # from different modules never collide; each is created once. Fetched:
    # the root module's versions plus rules_valkey's own (its MODULE.bazel
    # imports those repos and the toolchain points at them, for every
    # consumer), or DEFAULT_VERSION when neither sets one. Other modules'
    # tags are ignored. Through v0.2.0 only the root's tags were honoured,
    # so a root without `valkey.version()` failed to resolve.
    versions = {}
    for mod in mctx.modules:
        if mod.is_root or mod.name == "rules_valkey":
            for tag in mod.tags.version:
                versions[tag.version] = None
    if not versions:
        versions[DEFAULT_VERSION] = None

    supported = sorted({v: None for v, _ in CONDA_CLOSURES.keys()}.keys())
    for version in versions.keys():
        if version not in supported:
            fail("rules_valkey: valkey.version(version = \"{}\") is not supported. Supported: {}".format(
                version,
                ", ".join(supported),
            ))
        for plat in PLATFORMS.keys():
            valkey_binary_repo(
                name = "valkey_{}_{}".format(version.replace(".", "_"), plat),
                version = version,
                platform = plat,
            )

valkey = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
