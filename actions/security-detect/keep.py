#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Print the paths on stdin that a scanner would not skip.

Usage: keep.py iac|code. For iac, SKIP_DIRS holds Trivy's skip-dirs: globs
from the repo root that name directories. For code, EXCLUDE holds Semgrep's
excludes: a pattern with no "/" names a file or directory anywhere, as in
.gitignore. Both are one per line. Globs follow actions/lib/path_exemptions.py.

Why: find-files.sh must skip what the scanner skips, or a repo whose only
infrastructure (or code) is in a skipped directory installs and runs a
scanner over nothing on every run.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from path_exemptions import glob_re  # noqa: E402

kind = sys.argv[1]
pats = []
for p in os.environ.get("SKIP_DIRS" if kind == "iac" else "EXCLUDE", "").splitlines():
    p = p.strip().strip("/")
    if not p:
        continue
    if kind == "code" and "/" not in p:
        p = "**/" + p
    pats.append(glob_re(p))
for f in sys.stdin.read().splitlines():
    parts = f.split("/")
    # Every directory above the file; for Semgrep the file itself too.
    heads = ["/".join(parts[:i]) for i in range(1, len(parts) + (kind == "code"))]
    if not any(r.fullmatch(h) for r in pats for h in heads):
        print(f)
