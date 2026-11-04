"""Providers exposed by rules_valkey."""

ValkeyBinaryInfo = provider(
    doc = "Valkey toolchain binaries (one conda-forge closure).",
    fields = {
        "version":   "string — pinned Valkey version",
        "server":    "File — valkey-server",
        "cli":       "File — valkey-cli",
        "check_rdb": "File — valkey-check-rdb",
        "check_aof": "File — valkey-check-aof",
        "openssl":   "File — the closure's openssl CLI (test certificates)",
        "files":     "depset of File — the binaries plus the shared libraries " +
                     "they load through their RPATH; every runfiles tree " +
                     "that runs a binary needs all of it",
    },
)

ValkeyConfigInfo = provider(
    doc = "A checked valkey.conf (valkey_config).",
    fields = {
        "config": "File — the staged valkey.conf",
        "acl":    "File or None — the ACL file, staged beside it as users.acl",
        "files":  "depset of File — config + acl (one directory)",
    },
)
