"""valkey_install + valkey_install_health_check — cluster primitives
wrapping rules_kubectl's `kubectl_apply` over the pinned, pre-rendered
official valkey-io `valkey` Helm chart (standalone primary, no
persistence).

Wait shape: Deployment `valkey` rolled out (fullnameOverride: valkey).

With `config = ":my_config"` (a valkey_config), the chart's
`valkey-config` ConfigMap is replaced at build time by your valkey.conf,
with host paths (dir, logfile, pidfile, aclfile, ...) and networking
(port, bind, protected-mode) commented out: the chart's init container
supplies those (port 6379, bind *, dir /data) and appends your file.
"""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")
load(":providers.bzl", "ValkeyConfigInfo")

_DEPLOY = "deploy/valkey"
_MANIFEST = Label("//private/manifests:valkey.yaml")

def _configured_manifest_impl(ctx):
    cfg = ctx.attr.config[ValkeyConfigInfo]
    if cfg.acl:
        fail("{}: {} has an ACL file; the pre-rendered chart mounts only valkey.conf. ".format(
            ctx.label, ctx.attr.config.label) + "Install without `acl` (or use the chart's auth values).")
    # Host paths (dir, logfile, ...) and the chart-owned networking
    # (port, bind, protected-mode) are commented out first: in the pod the
    # chart's base config provides them, and e.g. `dir /var/lib/valkey`
    # would stop valkey-server from starting.
    staged = ctx.actions.declare_file(ctx.label.name + ".valkey.conf")
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [ctx.file._launcher.path, "stage-for-chart", cfg.config.path, staged.path],
        inputs = [cfg.config, ctx.file._launcher],
        outputs = [staged],
        use_default_shell_env = True,
        mnemonic = "ValkeyStageConfig",
    )
    out = ctx.actions.declare_file(ctx.label.name + ".yaml")
    ctx.actions.run_shell(
        inputs = [staged, ctx.file.manifest, ctx.file._awk],
        outputs = [out],
        command = 'awk -v cm_name=valkey-config -v first_key=valkey.conf -v ndata=1 -f "$1" "$3" "$2" > "$OUT"',
        arguments = [ctx.file._awk.path, ctx.file.manifest.path, staged.path],
        env = {"OUT": out.path},
        mnemonic = "ValkeyInstallConfig",
        progress_message = "Applying %{label}'s config to the Valkey chart manifest",
    )
    return [DefaultInfo(files = depset([out]))]

valkey_configured_manifest = rule(
    implementation = _configured_manifest_impl,
    doc = "The pinned chart manifest with its valkey.conf replaced by `config`.",
    attrs = {
        "config": attr.label(mandatory = True, providers = [ValkeyConfigInfo]),
        "manifest": attr.label(default = _MANIFEST, allow_single_file = True),
        "_awk": attr.label(default = "//private:install_config.awk", allow_single_file = True),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
)

def valkey_install(
        name,
        namespace = "valkey",
        config = None,
        wait_timeout = "300s",
        **kwargs):
    """Apply the pinned Valkey chart into `namespace` and block until
    `deploy/valkey` has rolled out. Drops into `itest_service.exe`.

    Args:
      name: target name.
      namespace: namespace to install into (created if missing). The
        rendered objects carry none, so this places them.
      config: optional valkey_config appended to the chart's base config.
      wait_timeout: rollout wait.
      **kwargs: forwarded to kubectl_apply (tags, visibility,
        wait_for_rollouts, ...).
    """
    manifest = _MANIFEST
    if config:
        manifest = ":" + name + "_manifest"
        valkey_configured_manifest(
            name = name + "_manifest",
            config = config,
            tags = kwargs.get("tags"),
            visibility = ["//visibility:private"],
        )
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = [manifest],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_rollouts = [_DEPLOY] + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def valkey_install_health_check(
        name,
        namespace = "valkey",
        **kwargs):
    """Readiness probe paired with `valkey_install`: same rollout wait with
    `--timeout=0s`. Drops into `itest_service.health_check`."""
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_rollouts = [_DEPLOY] + list(extra_rollouts),
        **kwargs
    )
