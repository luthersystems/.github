#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Warn about dependency manifests osv-scanner cannot check.

Usage: lockfile-check.py [--exclude PATTERN]...   (run at the repo root)

osv-scanner reads lockfiles, not manifests.  A package.json with no lockfile
gives it no versions, so its dependencies pass the scan without being
checked, and that looks the same as a clean scan.  A requirements file with
a range (`requests>=2`) is scanned at the oldest version the range allows,
not the one pip installs, so the result can be wrong both ways.  This prints
a warning for each such file.  It never
fails: some packages (a library's package.json) leave the versions to the
app that installs them on purpose.

--exclude takes osv-scanner's forms: a directory name, g:glob or r:regex.
Exit code is always 0 unless git fails.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

NODE_LOCKS = ("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb")
PY_LOCKS = ("poetry.lock", "uv.lock", "pdm.lock", "Pipfile.lock", "pylock.toml")
DEP_KEYS = ("dependencies", "devDependencies", "optionalDependencies")


def excluded(path, patterns):
    parts = path.split("/")[:-1]
    for p in patterns:
        if p.startswith("g:"):
            if fnmatch.fnmatchcase(path, p[2:]) or any(
                    fnmatch.fnmatchcase("/".join(parts[:i + 1]), p[2:]) for i in range(len(parts))):
                return True
        elif p.startswith("r:"):
            if re.search(p[2:], path):
                return True
        elif p in parts:
            return True
    return False


def has_lock(path, files, names):
    """True when the manifest's directory, or one above it (a workspace root), holds a lock."""
    d = os.path.dirname(path)
    while True:
        if any(os.path.join(d, n) in files for n in names):
            return True
        if not d:
            return False
        d = os.path.dirname(d)


def unpinned(path):
    bad = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            # Options (-r, -c, --hash), continuation lines, URLs and paths
            # carry no package==version to check.
            if not line or line.startswith(("-", "\\", ".", "/")) or "://" in line:
                continue
            # Cut the environment marker first: `x>=2; python_version == "3.10"`
            # is unpinned, and the marker's `==` must not hide that.
            line = line.rstrip("\\").split(";", 1)[0].strip()
            if "==" not in line:
                bad.append((n, line))
    return bad


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--exclude", action="append", default=[])
    args = ap.parse_args(argv)
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout
    files = {f for f in out.decode().split("\0") if f}
    warned = 0
    for f in sorted(files):
        if "node_modules/" in f or excluded(f, args.exclude) or not os.path.isfile(f):
            continue
        base = os.path.basename(f)
        if base == "package.json":
            try:
                with open(f, encoding="utf-8") as fh:
                    pkg = json.load(fh)
            except (OSError, ValueError):
                continue
            if any(pkg.get(k) for k in DEP_KEYS) and not has_lock(f, files, NODE_LOCKS):
                print(f"::warning file={f},title=No lockfile::{f} has dependencies but no lockfile, "
                      "so the dependency scan cannot check them. Commit the lockfile your package manager writes.")
                warned += 1
        elif base == "pyproject.toml":
            with open(f, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            has_deps = re.search(r"^\s*dependencies\s*=\s*\[\s*[\"']", text, re.M) or \
                "[tool.poetry.dependencies]" in text
            if has_deps and not has_lock(f, files, PY_LOCKS) and not any(
                    os.path.dirname(x) == os.path.dirname(f) and os.path.basename(x).startswith("requirements")
                    for x in files):
                print(f"::warning file={f},title=No lockfile::{f} has dependencies but no lockfile "
                      "(uv.lock, poetry.lock, ...), so the dependency scan cannot check them.")
                warned += 1
        elif re.fullmatch(r"requirements.*\.txt", base):
            bad = unpinned(f)
            if bad:
                n, line = bad[0]
                print(f"::warning file={f},line={n},title=Unpinned requirements::{len(bad)} line(s) of {f} "
                      f"pin no version (first: {line!r}). The dependency scan then checks the oldest version the "
                      "range allows, which is likely not the one installed, so it can miss a "
                      "vulnerability or report one that is not there. Pin with ==, or generate the "
                      "file with pip-compile or uv pip compile.")
                warned += 1
    if warned:
        print(f"lockfile check: {warned} manifest(s) the dependency scan cannot check (warnings only)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
