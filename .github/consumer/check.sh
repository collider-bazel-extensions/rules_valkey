#!/usr/bin/env bash
# Consumer checks against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   1. no valkey.version() in the root resolves, and a valkey_test runs the
#      default version
#   2. the same version set twice in the root resolves
#   3. an unsupported version fails, naming valkey.version
#   4. @rules_valkey//... loads (tests/ and tools/ are not shipped)
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_valkey"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests tools; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
default_version="$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"$/\1/p' "$src/private/versions.bzl")"
kubectl_commit="$(grep -A3 'module_name = "rules_kubectl"' "$src/MODULE.bazel" | sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p')"

consumer() { # <name> <extra MODULE.bazel lines>
    local c="$work/$1"
    mkdir -p "$c"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_valkey")
local_path_override(module_name = "rules_valkey", path = "$src")
bazel_dep(name = "rules_kubectl", version = "0.2.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "$kubectl_commit",
)
$2
MOD
    cat > "$c/ping_test.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
"\$VALKEY_SERVER" --version | grep -q "v=$default_version"
[[ "\$("\$VALKEY_CLI" -h "\$VALKEY_HOST" -p "\$VALKEY_PORT" PING)" == PONG ]]
SH
    chmod +x "$c/ping_test.sh"
    cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_valkey//:defs.bzl", "valkey_test")

valkey_test(
    name = "ping_test",
    srcs = ["ping_test.sh"],
)
BUILD
    echo "$c"
}

# 1. No valkey.version(): resolves; a valkey_test runs the default version.
c="$(consumer untagged "")"
(cd "$c" && bazel mod deps >/dev/null)
(cd "$c" && bazel test //:ping_test --test_output=errors)
echo "PASS: untagged root resolves, valkey $default_version runs"

# 2. The same version twice in the root.
c="$(consumer twice "valkey = use_extension(\"@rules_valkey//:extensions.bzl\", \"valkey\")
valkey.version(version = \"$default_version\")
valkey.version(version = \"$default_version\")")"
(cd "$c" && bazel mod deps >/dev/null)
echo "PASS: repeated identical valkey.version resolves"

# 3. An unsupported version fails with a message naming valkey.version.
c="$(consumer unsupported 'valkey = use_extension("@rules_valkey//:extensions.bzl", "valkey")
valkey.version(version = "0.0.1")')"
if (cd "$c" && bazel mod deps) > "$work/unsupported.out" 2>&1; then
    echo "FAIL: unsupported version resolved" >&2; exit 1
fi
grep -q 'valkey.version(version = "0.0.1") is not supported' "$work/unsupported.out" || {
    cat "$work/unsupported.out" >&2; echo "FAIL: unsupported version: wrong error" >&2; exit 1; }
echo "PASS: unsupported version fails clearly"

# 4. //... loads.
(cd "$work/untagged" && bazel query @rules_valkey//... >/dev/null)
echo "PASS: @rules_valkey//... loads"
