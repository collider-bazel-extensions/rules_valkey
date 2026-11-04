"""Analysis-time tests: install macros, valkey_server provider, and the
analysis errors for bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_valkey//:defs.bzl",
    "ValkeyServerInfo",
    "valkey_health_check",
    "valkey_install",
    "valkey_install_health_check",
    "valkey_server",
)

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None,
                 "expected target to expose an executable")
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[ValkeyServerInfo]
    asserts.equals(env, "9.1.3", info.binary.version)
    asserts.equals(env, 3, info.shards)
    asserts.equals(env, 1, info.replicas)
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    s = name + "_subject"
    valkey_server(name = s + "_cluster", shards = 3, replicas = 1, tags = ["manual"])
    valkey_health_check(name = s + "_health", server = ":" + s + "_cluster", tags = ["manual"])
    valkey_install(name = s + "_install", tags = ["manual"])
    valkey_install(name = s + "_install_config", config = "//tests/testdata:install_config", tags = ["manual"])
    valkey_install_health_check(name = s + "_install_health", tags = ["manual"])
    valkey_server(name = s + "_two_shards", shards = 2, tags = ["manual"])
    valkey_server(name = s + "_lone_replicas", replicas = 1, tags = ["manual"])
    valkey_server(name = s + "_cluster_rdb", shards = 3, rdb = "//tests/testdata:dump.rdb", tags = ["manual"])
    valkey_server(name = s + "_bad_timeout", ready_timeout = "soon", tags = ["manual"])
    valkey_install(name = s + "_install_acl", config = "//tests/testdata:config", tags = ["manual"])
    valkey_server(name = s + "_tls_no_tls", tls_auth_clients = True, tags = ["manual"])
    valkey_server(name = s + "_tls_partial", tls = True, tls_cert = "//tests/testdata:certs/server.crt", tags = ["manual"])
    valkey_server(
        name = s + "_tls_mutual_own",
        tls = True,
        tls_auth_clients = True,
        tls_ca = "//tests/testdata:certs/ca.crt",
        tls_cert = "//tests/testdata:certs/server.crt",
        tls_key = "//tests/testdata:certs/server.key",
        tags = ["manual"],
    )

    tests = {
        "_info": (_server_info_test, s + "_cluster", None),
        "_health_executable": (_has_executable_test, s + "_health", None),
        "_install_executable": (_has_executable_test, s + "_install", None),
        "_install_config_executable": (_has_executable_test, s + "_install_config", None),
        "_install_health_executable": (_has_executable_test, s + "_install_health", None),
        "_two_shards": (_fails_test, s + "_two_shards", "needs at least 3 primaries"),
        "_lone_replicas": (_fails_test, s + "_lone_replicas", "replicas apply to a cluster"),
        "_cluster_rdb": (_fails_test, s + "_cluster_rdb", "rdb is for a standalone server"),
        "_timeout": (_fails_test, s + "_bad_timeout", "expected a positive number of seconds"),
        "_install_acl": (_fails_test, s + "_install_acl_manifest", "has an ACL file"),
        "_tls_no_tls": (_fails_test, s + "_tls_no_tls", "tls_auth_clients need tls = True"),
        "_tls_partial": (_fails_test, s + "_tls_partial", "give tls_cert, tls_key and tls_ca together"),
        "_tls_mutual_own": (_fails_test, s + "_tls_mutual_own", "needs tls_client_cert and tls_client_key"),
    }
    for suffix, (rule, target, message) in tests.items():
        if message:
            rule(name = name + suffix, target_under_test = ":" + target, message = message)
        else:
            rule(name = name + suffix, target_under_test = ":" + target)
    native.test_suite(name = name, tests = [":" + name + t for t in tests])
