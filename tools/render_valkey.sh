#!/usr/bin/env bash
# Maintainer flow:
#   1. Edit tools/versions.bzl::VALKEY_CHART_VERSIONS — add the
#      target version's chart_url + chart_sha256.
#   2. Add (or update) a `helm_template` + `sh_binary` block in
#      tools/BUILD.bazel for the new version.
#   3. tools/render_valkey.sh <version>  (e.g. 0.12.1)
#
# Host helm is NOT required — helm comes from rules_helm.
set -euo pipefail

VERSION="${1:?usage: tools/render_valkey.sh <version>}"
TARGET="//tools:render_writeback_$(echo "$VERSION" | tr '.' '_')"

echo "[render_valkey] $TARGET"
exec bazel run "$TARGET"
