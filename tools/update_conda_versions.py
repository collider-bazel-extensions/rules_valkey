#!/usr/bin/env python3
"""Resolve the full conda-forge dependency closure for valkey-server and
emit a Bazel-loadable pin file for rules_valkey's hermetic toolchain.
(Adapted from rules_pg's tools/update_conda_versions.py.)

Maintainer usage:
    python3 tools/update_conda_versions.py --refresh 9.1.3 \
        > private/conda_versions.bzl

For each (valkey version, supported platform) the script:
  1. Fetches conda-forge's repodata for that platform.
  2. Picks the newest valkey-server build of exactly that version.
  3. BFS-expands the transitive `depends` list, picking the
     highest-version package on conda-forge for each named dep that
     matches the version constraint.
  4. Resolves each chosen package to (url, sha256, size).
  5. Emits a CONDA_CLOSURES dict keyed by (version, platform) →
     list of pin entries.

Virtual packages (names starting with `__`, like `__glibc`) are
skipped — they represent system constraints, not real packages.

The repodata cache lives in `~/.cache/rules_valkey_conda_cache/`. Pass
`--refresh` when bumping versions: a stale cache silently pins whatever
was newest when it was filled. The cache's age is printed on every run.
"""

import argparse
import functools
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "rules_valkey_conda_cache"
CONDA_FORGE_BASE = "https://conda.anaconda.org/conda-forge"
REFRESH = False  # set by --refresh

PLATFORMS = {
    "linux_amd64":  "linux-64",
    "linux_arm64":  "linux-aarch64",
    "darwin_amd64": "osx-64",
    "darwin_arm64": "osx-arm64",
}


def _http_get(url: str, binary: bool = False) -> bytes | str:
    req = urllib.request.Request(url, headers={"User-Agent": "rules_valkey-update_conda_versions/1.0"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    return data if binary else data.decode("utf-8")


@functools.lru_cache(maxsize=None)
def _fetch_repodata(conda_platform: str) -> dict:
    """Fetch conda-forge's repodata.json for one platform. Cached on disk."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / f"repodata_{conda_platform}.json"
    if cache_path.exists() and not REFRESH:
        age_days = (time.time() - cache_path.stat().st_mtime) / 86400
        print(f"[cache] repodata for {conda_platform} is {age_days:.0f} days old "
              f"(pass --refresh to re-fetch)", file=sys.stderr)
        return json.loads(cache_path.read_text())
    print(f"[fetch] repodata for {conda_platform} (one-time, ~50-200MB)…", file=sys.stderr)
    body = _http_get(f"{CONDA_FORGE_BASE}/{conda_platform}/repodata.json")
    data = json.loads(body)
    cache_path.write_text(body)
    return data


def _parse_version(v: str) -> tuple:
    """A loose semver-ish key for sorting conda version strings.

    Conda versions are a superset of semver (`16.13`, `1.2.13rc1`,
    `3.0.7+deb`, …). For our purposes, take the leading dotted-int
    segments and ignore the rest.
    """
    parts = []
    for chunk in re.split(r"[.+-]", v):
        m = re.match(r"^(\d+)", chunk)
        if m:
            parts.append(int(m.group(1)))
        else:
            break
    return tuple(parts) or (0,)


def _matches_constraint(v: str, constraint: str) -> bool:
    """Check `v` against a conda-style version constraint, e.g.
    ">=1.19.3,<1.20.0a0". Returns True on match.

    Constraints support: ==, !=, >=, <=, >, <, =, and comma-separated
    AND. Wildcards (`*`) supported in `==1.2.*` form. Anything fancier
    (`(== or >=)`) falls back to True; that's a known loose match —
    the maintainer reviews the emitted pin set.
    """
    if not constraint:
        return True
    v_parts = _parse_version(v)
    for term in [t.strip() for t in constraint.split(",")]:
        if not term:
            continue
        m = re.match(r"^(==|!=|>=|<=|>|<|=)?\s*(.+)$", term)
        if not m:
            continue
        op = m.group(1) or "=="
        bound_raw = m.group(2).strip()
        if "*" in bound_raw:
            prefix = bound_raw.rstrip(".*")
            if op in ("==", "="):
                if not v.startswith(prefix):
                    return False
            continue
        b_parts = _parse_version(bound_raw)
        # Pad to equal length for comparison.
        n = max(len(v_parts), len(b_parts))
        a = v_parts + (0,) * (n - len(v_parts))
        b = b_parts + (0,) * (n - len(b_parts))
        if op == "==" or op == "=":
            if a != b:
                return False
        elif op == "!=":
            if a == b:
                return False
        elif op == ">=":
            if a < b:
                return False
        elif op == "<=":
            if a > b:
                return False
        elif op == ">":
            if a <= b:
                return False
        elif op == "<":
            if a >= b:
                return False
    return True


def _pick_best(repodata: dict, name: str, constraint: str) -> tuple[str, dict] | None:
    """Find the highest-version package on conda-forge that matches
    name + constraint. Returns (filename, package_info) or None.
    """
    candidates = []
    # repodata has two payload buckets: `packages` (legacy .tar.bz2)
    # and `packages.conda` (newer zstd-compressed .conda). Prefer
    # the latter — that's what we extract.
    for fname, info in repodata.get("packages.conda", {}).items():
        if info.get("name") != name:
            continue
        if not _matches_constraint(info.get("version", ""), constraint):
            continue
        candidates.append((fname, info))
    if not candidates:
        for fname, info in repodata.get("packages", {}).items():
            if info.get("name") != name:
                continue
            if not _matches_constraint(info.get("version", ""), constraint):
                continue
            candidates.append((fname, info))
    if not candidates:
        return None
    # Sort by (version, build_number, timestamp) descending.
    candidates.sort(
        key=lambda c: (
            _parse_version(c[1].get("version", "0")),
            c[1].get("build_number", 0),
            c[1].get("timestamp", 0),
        ),
        reverse=True,
    )
    return candidates[0]


def _resolve_closure(conda_platform: str, version: str) -> list[dict]:
    """BFS the dependency closure for valkey-server==<version> on
    conda_platform. Returns a list of {name, version, build, url,
    sha256, size} dicts.

    Conda has two relevant repodata sources per resolution:
    `<platform>/repodata.json` (platform-specific packages) and
    `noarch/repodata.json` (architecture-independent, like tzdata).
    Try platform first, fall back to noarch.
    """
    repodata = _fetch_repodata(conda_platform)
    noarch_repodata = _fetch_repodata("noarch")

    def best(name: str, constraint: str):
        pick = _pick_best(repodata, name, constraint)
        if pick is not None:
            return pick, conda_platform
        pick = _pick_best(noarch_repodata, name, constraint)
        if pick is not None:
            return pick, "noarch"
        return None, None

    root, root_subdir = best("valkey-server", f"=={version}")
    if not root:
        raise RuntimeError(f"no valkey-server {version} found on conda-forge/{conda_platform}")

    chosen: dict[str, tuple[tuple, str]] = {}  # name -> ((filename, info), subdir)
    chosen["valkey-server"] = (root, root_subdir)
    queue = [root]

    while queue:
        _fname, info = queue.pop(0)
        for dep in info.get("depends", []):
            # Strip channel prefix if any ("conda-forge::libpq >=...").
            d = dep.split("::", 1)[-1].strip()
            parts = d.split(None, 1)
            name = parts[0]
            constraint = parts[1] if len(parts) > 1 else ""
            if name.startswith("__"):
                # Virtual package (system constraint). Skip.
                continue
            if name in chosen:
                continue
            pick, subdir = best(name, constraint)
            if not pick:
                print(f"[warn] {conda_platform}/{version}: no candidate for {name} {constraint!r}", file=sys.stderr)
                continue
            chosen[name] = (pick, subdir)
            queue.append(pick)

    out = []
    for name, ((fname, info), subdir) in chosen.items():
        sha = info.get("sha256")
        if not sha:
            sha = _compute_sha256(f"{CONDA_FORGE_BASE}/{subdir}/{fname}")
        out.append({
            "name":    name,
            "version": info.get("version", ""),
            "build":   info.get("build", ""),
            "url":     f"{CONDA_FORGE_BASE}/{subdir}/{fname}",
            "sha256":  sha,
            "size":    info.get("size", 0),
        })
    out.sort(key=lambda e: e["name"])
    return out


def _compute_sha256(url: str) -> str:
    body = _http_get(url, binary=True)
    return hashlib.sha256(body).hexdigest()


def _emit_bzl(closures: dict, versions: list[str]) -> str:
    lines = [
        '"""Auto-generated conda-forge dependency closures for hermetic Valkey.',
        '',
        'Generated by `python3 tools/update_conda_versions.py %s` against' % ' '.join(versions),
        'conda-forge\'s repodata.json. Each closure is the full transitive',
        'dependency set for `valkey-server==<version>` on one platform (the',
        'server and CLI, openssl, and on Linux the GCC runtime), so the binaries',
        'run without host libraries beyond libc. Conda binaries are built with',
        'RPATH=$ORIGIN/../lib; the repository rule merges every package into',
        'one tree.',
        '',
        'Maintainer flow:',
        '    python3 tools/update_conda_versions.py --refresh %s \\' % ' '.join(versions),
        '        > private/conda_versions.bzl',
        '"""',
        '',
        '# (version, platform) -> list of {name, version, build, url, sha256}',
        'CONDA_CLOSURES = {',
    ]
    for version in versions:
        for plat in PLATFORMS.keys():
            entries = closures.get((version, plat))
            if not entries:
                continue
            lines.append(f'    ("{version}", "{plat}"): [')
            for e in entries:
                lines.append('        {')
                lines.append(f'            "name":    "{e["name"]}",')
                lines.append(f'            "version": "{e["version"]}",')
                lines.append(f'            "build":   "{e["build"]}",')
                lines.append(f'            "url":     "{e["url"]}",')
                lines.append(f'            "sha256":  "{e["sha256"]}",')
                lines.append('        },')
            lines.append('    ],')
    lines.append('}')
    lines.append('')
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("versions", nargs="+", help="valkey versions, e.g. 9.1.3")
    parser.add_argument("--refresh", action="store_true",
                        help="re-fetch conda-forge repodata instead of using the on-disk cache")
    args = parser.parse_args()
    global REFRESH
    REFRESH = args.refresh

    closures = {}
    for version in args.versions:
        for plat_key, conda_plat in PLATFORMS.items():
            print(f"[resolve] valkey-server {version} {plat_key} ({conda_plat})", file=sys.stderr)
            closure = _resolve_closure(conda_plat, version)
            print(f"          → {len(closure)} packages", file=sys.stderr)
            closures[(version, plat_key)] = closure

    sys.stdout.write(_emit_bzl(closures, args.versions))


if __name__ == "__main__":
    main()
