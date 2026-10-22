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
import re
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


def version_key(v):
    """A sort key that orders most version schemes (semver, PEP 440, npm).

    Numbers compare as numbers and words as words, and a pre-release word
    (1.2.0-rc1) sorts before the release (1.2.0). It is not exact for every
    ecosystem, so the gate uses it only to find which range holds the
    installed version; when it cannot tell, the finding blocks (see fix_for).
    """
    v = str(v).lstrip("vV").split("+", 1)[0]
    key = []
    for part in re.findall(r"\d+|[A-Za-z]+", v):
        key.append((1, int(part), "") if part.isdigit() else (0, 0, part.lower()))
    # 1.2 and 1.2.0 are the same version, and so are 1.2-rc1 and 1.2.0-rc1:
    # drop the trailing zeros of the release numbers (before the first word).
    head = next((i for i, t in enumerate(key) if t[0] == 0), len(key))
    while head and key[head - 1] == (1, 0, ""):
        del key[head - 1]
        head -= 1
    # An end mark that sorts above any word and below any number, so a
    # pre-release sorts before its release (1.2.0-rc1 < 1.2.0) and a release
    # before a longer one (2.0 < 2.0.1).
    key.append((0, 1, ""))
    return key


def fix_for(pkg, group, vulns):
    """The version that fixes this group for the installed version.

    Returns (fixable, versions). An OSV range is a list of events: each
    "introduced" opens an affected span, and the next "fixed" closes it. The
    installed version is fixable when the span that holds it is closed by a
    "fixed" (the versions listed). It is not fixable when that span is open
    (no fix yet on that release line), even if another line has a fix: a
    fix on 1.x is no fix for 2.x. When no SEMVER or ECOSYSTEM range names
    the installed version, the gate cannot tell, and treats it as fixable
    when any range has a fix: a blocked merge can be exempted, a missed one
    cannot be seen.
    """
    installed = pkg.get("version", "")
    ik = version_key(installed) if installed else None
    any_fix, matched, fixes = set(), False, set()
    for vid in group.get("ids", []):
        for aff in vulns.get(vid, {}).get("affected", []):
            p = aff.get("package", {})
            if p.get("name") != pkg.get("name") or p.get("ecosystem", "").split(":")[0] != pkg.get("ecosystem", "").split(":")[0]:
                continue
            if installed and installed in (aff.get("versions") or []):
                matched = True
            for rng in aff.get("ranges", []):
                if rng.get("type") not in ("SEMVER", "ECOSYSTEM"):
                    continue
                start = None
                for ev in rng.get("events", []):
                    if "introduced" in ev:
                        start = ev["introduced"]
                    elif ("fixed" in ev or "last_affected" in ev) and start is not None:
                        end = ev.get("fixed")
                        if end:
                            any_fix.add(end)
                        if ik is not None and (start == "0" or version_key(start) <= ik):
                            if end and ik < version_key(end):
                                matched = True
                                fixes.add(end)
                            elif not end and ik <= version_key(ev["last_affected"]):
                                matched = True
                        start = None
                if start is not None and ik is not None and (start == "0" or version_key(start) <= ik):
                    matched = True  # open span: affected, no fix on this line
    if matched:
        return bool(fixes), sorted(fixes, key=version_key)
    return bool(any_fix), sorted(any_fix, key=version_key)


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
                fixable, fixes = fix_for(pkg, group, vulns)
                name = ", ".join(group.get("aliases") or group.get("ids") or ["?"])
                where = f"{pkg.get('name')}@{pkg.get('version')} ({pkg.get('ecosystem')}, {source})"
                fix = f"fixed in {', '.join(fixes)}" if fixable else "no fix yet"
                if s >= HIGH and fixable:
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
