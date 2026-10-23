#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Fail a `trivy config` report on a High or Critical misconfiguration.

Usage: trivy-gate.py [--exemptions FILE] [--today YYYY-MM-DD] REPORT

REPORT is the output of `trivy config --format json`.  Exit codes:

  0  every High or Critical finding has a live exemption
  1  at least one has none (each prints as an ::error)
  2  the report or the exemptions file is malformed

Why High and Critical: the rule the owner chose for the shared workflow
(design question 4, and for Terraform "fail on High/Critical; baseline").
Low and Medium findings are style more often than risk, and Trivy is not
asked for them.  A repo's findings on the day it adopts the check go into
its exemptions file, each with an expiry date and an issue, so new findings
block at once and old ones have a deadline.

The exemptions file format is in actions/lib/path_exemptions.py.  A row's id
is Trivy's (AWS-0086 or AVD-AWS-0086; either works).
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

BLOCKING = {"HIGH", "CRITICAL"}


def findings(report):
    """Yield (ids, path, line, severity, title, message, url) per failed check."""
    for result in report.get("Results") or []:
        target = result.get("Target", "")
        for m in result.get("Misconfigurations") or []:
            if m.get("Status", "FAIL") != "FAIL":
                continue
            # Older Trivy ids and docs say AVD-AWS-0086, newer ones AWS-0086;
            # a row may use either.
            ids = {i for i in (m.get("ID"), m.get("AVDID")) if i}
            ids |= {"AVD-" + i for i in ids if not i.startswith("AVD-")}
            line = (m.get("CauseMetadata") or {}).get("StartLine") or 0
            yield (ids, target, line, m.get("Severity", ""), m.get("Title", ""),
                   m.get("Message", ""), m.get("PrimaryURL", ""))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--exemptions", default="")
    ap.add_argument("--today", default="")
    ap.add_argument("report")
    args = ap.parse_args(argv)
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    try:
        live, expired = path_exemptions.load(args.exemptions, today)
    except ValueError as e:
        print(f"::error title=Trivy exemptions malformed::{e}")
        return 2
    try:
        with open(args.report, encoding="utf-8") as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        print(f"::error title=Trivy report unreadable::{e}")
        return 2

    blocked = exempted = 0
    for ids, path, line, sev, title, msg, url in findings(report):
        if sev not in BLOCKING:
            continue
        rule = min(ids, key=len)
        where = f"{path}:{line}" if line else path
        row = path_exemptions.find(live, ids, path)
        if row:
            row.used = True
            exempted += 1
            print(f"::notice title=Trivy finding exempted::{rule} {sev} at {where} "
                  f"(row {row.line}, expires {row.expires}, {row.issue})")
            continue
        old = path_exemptions.find(expired, ids, path)
        why = f"exemption expired {old.expires} (row {old.line})" if old else "not exempted"
        loc = f"file={path},line={line}," if line else f"file={path},"
        print(f"::error {loc}title=Trivy {sev} misconfiguration {rule}::{why}: {title}. {msg} {url}")
        print(f"    To exempt it, add a row: {rule} | {path} | YYYY-MM-DD | owner/repo#N | reason")
        blocked += 1

    for row in live:
        if not row.used:
            print(f"::warning title=Unused Trivy exemption::row {row.line} ({row.rule} | {row.path}) "
                  "covers no finding; delete it")
    if blocked:
        print(f"Trivy: {blocked} High or Critical misconfiguration(s) block, {exempted} exempted")
        return 1
    print(f"Trivy: no High or Critical misconfiguration blocks ({exempted} exempted)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
