#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Fail a Semgrep report on a security finding of ERROR severity.

Usage: semgrep-gate.py [--exemptions FILE] [--rule-prefix P] [--today YYYY-MM-DD] REPORT

REPORT is the output of `semgrep scan --json --severity ERROR`.  Exit codes:

  0  no blocking finding is left
  1  at least one is (each prints as an ::error)
  2  the report or the exemptions file is malformed

What blocks, and why: the owner chose "Semgrep CE, block ERROR only" in the
"Socket CLI and multi-language scans" thread.  Within ERROR this gate blocks
a rule only when its metadata says category "security" and confidence
MEDIUM or HIGH.  A LOW-confidence rule is an audit hint ("this calls
subprocess; check it") that fires on safe code too: on the day the check was
added, every security finding across our repos came from one, and none was
a real bug.  Those print as warnings, so a reviewer still sees them.  ERROR
rules of another category (best-practice, correctness) warn too: this is a
security check.

A finding is exempt when a live row of the exemptions file covers its rule
and file (format in actions/lib/path_exemptions.py; the id is the rule id
with the registry path, as the error prints it), or when the line carries a
`nosemgrep: <rule-id>` comment, which Semgrep itself honours.
"""
import argparse
import datetime
import json
import os
import sys

# No __pycache__ in the action's checkout: it is read-only by intent.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import path_exemptions  # noqa: E402

BLOCKING_CONFIDENCE = {"MEDIUM", "HIGH"}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--exemptions", default="")
    ap.add_argument("--rule-prefix", default="",
                    help="prefix Semgrep puts on rule ids loaded from a local directory")
    ap.add_argument("--today", default="")
    ap.add_argument("report")
    args = ap.parse_args(argv)
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    try:
        live, expired = path_exemptions.load(args.exemptions, today)
    except ValueError as e:
        print(f"::error title=Semgrep exemptions malformed::{e}")
        return 2
    try:
        with open(args.report, encoding="utf-8") as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        print(f"::error title=Semgrep report unreadable::{e}")
        return 2

    # A file Semgrep could not parse was not scanned; say so, but do not
    # block: a syntax it does not know is not a finding.
    for err in report.get("errors") or []:
        print(f"::warning title=Semgrep could not scan a file::{err.get('message', err)}"[:2000])

    blocked = exempted = 0
    for r in report.get("results") or []:
        rule = r.get("check_id", "")
        if args.rule_prefix and rule.startswith(args.rule_prefix):
            rule = rule[len(args.rule_prefix):]
        extra = r.get("extra") or {}
        meta = extra.get("metadata") or {}
        path, line = r.get("path", ""), (r.get("start") or {}).get("line", 0)
        msg = " ".join((extra.get("message") or "").split())
        sev = extra.get("severity", "")
        blocks = (sev == "ERROR" and meta.get("category") == "security"
                  and str(meta.get("confidence", "")).upper() in BLOCKING_CONFIDENCE)
        if not blocks:
            print(f"::warning file={path},line={line},title=Semgrep {rule}::"
                  f"{msg[:500]} (does not block: category {meta.get('category')}, "
                  f"confidence {meta.get('confidence')})")
            continue
        row = path_exemptions.find(live, {rule}, path)
        if row:
            row.used = True
            exempted += 1
            print(f"::notice title=Semgrep finding exempted::{rule} at {path}:{line} "
                  f"(row {row.line}, expires {row.expires}, {row.issue})")
            continue
        old = path_exemptions.find(expired, {rule}, path)
        why = f"exemption expired {old.expires} (row {old.line})" if old else "not exempted"
        print(f"::error file={path},line={line},title=Semgrep {rule}::{why}: {msg[:1500]}")
        print(f"    To exempt it, add a row: {rule} | {path} | YYYY-MM-DD | owner/repo#N | reason")
        blocked += 1

    for row in live:
        if not row.used:
            print(f"::warning title=Unused Semgrep exemption::row {row.line} ({row.rule} | {row.path}) "
                  "covers no finding; delete it")
    if blocked:
        print(f"Semgrep: {blocked} security finding(s) block, {exempted} exempted")
        return 1
    print(f"Semgrep: no security finding blocks ({exempted} exempted)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
