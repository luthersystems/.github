#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Fail a govulncheck scan only on called findings with no live exemption.

Usage: govulncheck-gate.py [--json FILE] [--today YYYY-MM-DD]
                           [--exemptions FILE] DIR [GOVULNCHECK ARGS...]

Runs `govulncheck -format json ARGS...` in DIR (default args ./...), or reads
FILE instead.  A finding counts when its trace's first frame names a
function: govulncheck's own test for "your code calls it".  Exit codes:

  0  every called finding has a live row in the exemptions file
  3  a called finding has none (govulncheck's own "found" code)
  2  the exemptions file is malformed
  1  the scan failed or its output did not parse

Why it exists: govulncheck has no ignore list, so a stdlib advisory fixed
only in a Go release the toolchain cannot move to yet blocks every merge.
The rule the owner chose (luthersystems/.github security workflow, design
question 4) is: fail on any reachable finding, unless a reviewed row with an
expiry date and a tracking issue exempts it.  An expired row exempts nothing,
so an exemption cannot outlive its reason by accident.

This file grew out of luthersystems/substrate's scripts/govulncheck-exempt.py
and keeps its file format, so substrate's rows move here as they are.

A missing exemptions file means no exemptions (most repos need none).
"""
import datetime
import json
import os
import re
import subprocess
import sys

ID_RE = re.compile(r"^GO-\d{4}-\d+$")
ISSUE_RE = re.compile(r"^[\w.-]+/[\w.-]+#\d+$")


def load_exemptions(path, today):
    """Return (live, expired), each {id: (expires, issue)}."""
    live, expired = {}, {}
    if not path or not os.path.exists(path):
        return live, expired
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 4 or not all(parts):
                raise ValueError(f"{path}:{n}: want 'id | expires | issue | reason'")
            vid, expires, issue, _ = parts
            if not ID_RE.match(vid):
                raise ValueError(f"{path}:{n}: {vid!r} is not a GO-YYYY-N id")
            if not ISSUE_RE.match(issue):
                raise ValueError(f"{path}:{n}: {issue!r} is not owner/repo#N")
            try:
                day = datetime.date.fromisoformat(expires)
            except ValueError:
                raise ValueError(f"{path}:{n}: {expires!r} is not YYYY-MM-DD")
            if vid in live or vid in expired:
                raise ValueError(f"{path}:{n}: duplicate row for {vid}")
            (live if day >= today else expired)[vid] = (expires, issue)
    return live, expired


def parse_stream(stream):
    """Return ({id: finding detail} for called findings, {id: summary})."""
    dec = json.JSONDecoder()
    called, summaries, i = {}, {}, 0
    while True:
        while i < len(stream) and stream[i].isspace():
            i += 1
        if i >= len(stream):
            return called, summaries
        obj, i = dec.raw_decode(stream, i)
        osv = obj.get("osv")
        if osv:
            summaries[osv["id"]] = osv.get("summary", "")
        finding = obj.get("finding")
        if finding and finding.get("trace") and finding["trace"][0].get("function"):
            frame = finding["trace"][0]
            called.setdefault(finding["osv"], {
                "module": frame.get("module", ""),
                "version": frame.get("version", ""),
                "fixed": finding.get("fixed_version", ""),
            })


def main(argv):
    today = datetime.date.today()
    jsonfile, exemptions = None, os.environ.get("GOVULNCHECK_EXEMPTIONS", "")
    while argv and argv[0].startswith("--"):
        flag = argv.pop(0)
        if flag == "--json":
            jsonfile = argv.pop(0)
        elif flag == "--today":
            today = datetime.date.fromisoformat(argv.pop(0))
        elif flag == "--exemptions":
            exemptions = argv.pop(0)
        else:
            print(f"unknown flag {flag}", file=sys.stderr)
            return 2
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    directory, args = argv[0], argv[1:] or ["./..."]
    try:
        live, expired = load_exemptions(exemptions, today)
    except (OSError, ValueError) as e:
        print(f"::error title=govulncheck exemptions malformed::{e}")
        return 2
    if jsonfile:
        with open(jsonfile, encoding="utf-8") as f:
            stream = f.read()
    else:
        r = subprocess.run(["govulncheck", "-format", "json", *args],
                           cwd=directory, capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            print(f"::error title=govulncheck scan failed::exit {r.returncode} in {directory}")
            return 1
        stream = r.stdout
    try:
        called, summaries = parse_stream(stream)
    except (ValueError, AttributeError, KeyError, IndexError, TypeError) as e:
        print(f"::error title=govulncheck JSON did not parse::{e}")
        return 1
    found = set(called)
    # One line per called finding, so the log says what to upgrade without a
    # second, text-mode scan.
    for vid in sorted(found):
        d = called[vid]
        fix = f"fixed in {d['fixed']}" if d["fixed"] else "no fix yet"
        print(f"{vid} {d['module']}@{d['version']}, {fix}: {summaries.get(vid, '')}")
    where = f"{directory} ({' '.join(args)})"
    for vid in sorted(found & set(expired)):
        exp, issue = expired[vid]
        print(f"::error title=govulncheck exemption expired::{vid} expired {exp} ({issue})")
    open_ids = sorted(found - set(live))
    for vid in sorted(found & set(live)):
        exp, issue = live[vid]
        print(f"::warning title=govulncheck finding exempted::{vid} until {exp} ({issue}) in {where}")
    for vid in sorted(set(live) - found):
        print(f"govulncheck-gate: row {vid} covers no finding in {directory}; delete it once no module needs it")
    if open_ids:
        print(f"::error title=govulncheck findings not exempted::{' '.join(open_ids)} in {where}")
        return 3
    print(f"govulncheck-gate: {len(found)} called finding(s) in {where}, none open")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
