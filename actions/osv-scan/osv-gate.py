#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Fail an osv-scanner report on a fixable High or Critical vulnerability.

Usage: osv-gate.py [--skip-ecosystem NAME]... [--config FILE] [--today YYYY-MM-DD] REPORT

REPORT is the output of `osv-scanner scan source --format json`.  Exit codes:

  0  no fixable High or Critical vulnerability is left
  1  at least one is (each prints as an ::error)
  2  the report or the config is malformed

Why this rule: it is the one the owner chose for the shared security
workflow (design question 4).  A fixable High or Critical has a version to
move to, so it blocks the merge.  An unfixable one, or a Low or Medium, prints
as a warning: there is nothing to do about the first, and the second is not
worth stopping a merge for.  Socket and Dependabot alerts still report both.

Why --skip-ecosystem Go: govulncheck already gates Go modules, and it reports
only code the module calls.  osv-scanner reports every module in go.mod, so
it would fail on vulnerable code that is never called.

Exemptions are osv-scanner's own: [[IgnoredVulns]] rows in osv-scanner.toml,
which osv-scanner drops from the report.  This gate refuses a row with no
ignoreUntil date or no reason, so no exemption is open-ended or unexplained.
"""
import datetime
import json
import sys

try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    tomllib = None

# CVSS v3 qualitative ratings: High is 7.0 to 8.9, Critical 9.0 to 10.0.
HIGH = 7.0
WORDS = {"HIGH": 7.0, "CRITICAL": 9.0, "MODERATE": 4.0, "MEDIUM": 4.0, "LOW": 0.1}


def check_config(path, today):
    """Return a list of problems with the IgnoredVulns rows of path."""
    if not path:
        return []
    if tomllib is None:
        return [f"{path}: python3 >= 3.11 is needed to read it"]
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
    except FileNotFoundError:
        return []
    except (OSError, tomllib.TOMLDecodeError) as e:
        return [f"{path}: {e}"]
    problems = []
    for row in cfg.get("IgnoredVulns", []):
        vid = row.get("id", "?")
        until = row.get("ignoreUntil")
        if not until:
            problems.append(f"{path}: IgnoredVulns {vid} has no ignoreUntil date")
        elif isinstance(until, (datetime.date, datetime.datetime)):
            day = until.date() if isinstance(until, datetime.datetime) else until
            if day < today:
                # osv-scanner already stops ignoring it; say why it is back.
                print(f"::warning title=osv exemption expired::{vid} expired {day}")
        if not str(row.get("reason", "")).strip():
            problems.append(f"{path}: IgnoredVulns {vid} has no reason")
    return problems


def score(group, vulns):
    """Highest severity of a group as a CVSS-like number (0 when unknown)."""
    try:
        s = float(group.get("max_severity") or 0)
    except ValueError:
        s = 0.0
    if s:
        return s
    best = 0.0
    for vid in group.get("ids", []):
        word = str(vulns.get(vid, {}).get("database_specific", {}).get("severity", "")).upper()
        best = max(best, WORDS.get(word, 0.0))
    return best


def fixed_in(pkg, group, vulns):
    """The versions that fix this group for this package (empty = no fix)."""
    fixes = set()
    for vid in group.get("ids", []):
        for aff in vulns.get(vid, {}).get("affected", []):
            p = aff.get("package", {})
            if p.get("name") != pkg["name"] or p.get("ecosystem", "").split(":")[0] != pkg["ecosystem"].split(":")[0]:
                continue
            for rng in aff.get("ranges", []):
                for ev in rng.get("events", []):
                    if "fixed" in ev:
                        fixes.add(ev["fixed"])
    return sorted(fixes)


def main(argv):
    skip, config, today = set(), None, datetime.date.today()
    while argv and argv[0].startswith("--"):
        flag = argv.pop(0)
        if flag == "--skip-ecosystem":
            skip.add(argv.pop(0).lower())
        elif flag == "--config":
            config = argv.pop(0)
        elif flag == "--today":
            today = datetime.date.fromisoformat(argv.pop(0))
        else:
            print(f"unknown flag {flag}", file=sys.stderr)
            return 2
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    problems = check_config(config, today)
    for p in problems:
        print(f"::error title=osv-scanner.toml exemption malformed::{p}")
    try:
        with open(argv[0], encoding="utf-8") as f:
            text = f.read()
        report = json.loads(text) if text.strip() else {"results": []}
    except (OSError, ValueError) as e:
        print(f"::error title=osv-scanner report did not parse::{e}")
        return 2
    if problems:
        return 2

    blocking = 0
    for result in report.get("results") or []:
        source = result.get("source", {}).get("path", "?")
        for entry in result.get("packages") or []:
            pkg = entry.get("package", {})
            if pkg.get("ecosystem", "").lower() in skip:
                continue
            vulns = {v["id"]: v for v in entry.get("vulnerabilities") or []}
            for group in entry.get("groups") or []:
                s = score(group, vulns)
                fixes = fixed_in(pkg, group, vulns)
                name = ", ".join(group.get("aliases") or group.get("ids") or ["?"])
                where = f"{pkg.get('name')}@{pkg.get('version')} ({pkg.get('ecosystem')}, {source})"
                fix = f"fixed in {', '.join(fixes)}" if fixes else "no fix yet"
                if s >= HIGH and fixes:
                    blocking += 1
                    print(f"::error title=osv: fixable severity {s}::{where}: {name}, {fix}")
                else:
                    print(f"::warning title=osv: severity {s or 'unknown'}, not blocking::{where}: {name}, {fix}")
    if blocking:
        print(f"osv-gate: {blocking} fixable High or Critical vulnerability group(s)")
        return 1
    print("osv-gate: no fixable High or Critical vulnerability")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
