"""Maintainer-side: Valkey Helm chart pin for the helm-render flow.

Consumers don't see this — it's loaded only by the dev-only chart-fetch
extension under tools/. The committed manifest at
`//private/manifests:valkey.yaml` is what consumers apply.

The chart is the official valkey-io `valkey` chart
(https://github.com/valkey-io/valkey-helm), published as a packaged
`.tgz` on its GitHub release; the sha256 is the release asset's digest.

Update flow:
    1. Add an entry (chart_url + chart_sha256).
    2. Add (or update) a `helm_template` + `sh_binary` block in
       tools/BUILD.bazel for the new version.
    3. `tools/render_valkey.sh <version>`.
"""

VALKEY_CHART_VERSIONS = {
    "0.12.1": {
        # appVersion 9.1.3 (matches the pinned binaries).
        "chart_url":    "https://github.com/valkey-io/valkey-helm/releases/download/valkey-0.12.1/valkey-0.12.1.tgz",
        "chart_sha256": "4ffe1a53f2902ddefd3774c1aab5bd60bfdc4b74cc670614899967972b153f7d",
    },
}
