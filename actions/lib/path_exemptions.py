#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Expiring exemptions keyed on a rule id and a file path.

The Trivy and Semgrep gates share this file format:

    # id | path | expires (YYYY-MM-DD) | issue | reason
    AWS-0086 | aws/s3/main.tf | 2027-01-31 | luthersystems/tf-modules#90 | public bucket on purpose

Why a shared format and not each tool's own ignore file: the owner's fail
rule (shared security workflow, design question 4) is "block unless a
reviewed row with an expiry date covers it".  Trivy's own ignore file makes
the expiry optional and needs a YAML parser, and Semgrep's ignore file has no
expiry at all.  The govulncheck exemptions already use this pipe format, so
one shape covers every check, and the gate, not the tool, applies it.

`path` is a glob matched against the file the finding is in, relative to the
repo root (`*` matches every file, `**` crosses directories).  An expired row
exempts nothing, so an exemption cannot outlive its reason by accident.
"""
import datetime
import fnmatch
import os
import re

ISSUE_RE = re.compile(r"^[\w.-]+/[\w.-]+#\d+$")


class Row:
    def __init__(self, rule, path, expires, issue, line):
        self.rule, self.path, self.expires, self.issue, self.line = rule, path, expires, issue, line
        self.used = False

    def matches(self, rule_ids, path):
        # fnmatch's `*` already crosses `/`, so `**` needs no special case.
        return self.rule in rule_ids and fnmatch.fnmatchcase(path, self.path)


def load(path, today=None):
    """Return (live, expired) lists of Row. Raise ValueError when malformed.

    A missing file means no exemptions: most repos need none.
    """
    today = today or datetime.date.today()
    live, expired, seen = [], [], set()
    if not path or not os.path.exists(path):
        return live, expired
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 5 or not all(parts):
                raise ValueError(f"{path}:{n}: want 'id | path | expires | issue | reason'")
            rule, glob, expires, issue, _ = parts
            if not ISSUE_RE.match(issue):
                raise ValueError(f"{path}:{n}: {issue!r} is not owner/repo#N")
            try:
                day = datetime.date.fromisoformat(expires)
            except ValueError:
                raise ValueError(f"{path}:{n}: {expires!r} is not YYYY-MM-DD") from None
            if (rule, glob) in seen:
                raise ValueError(f"{path}:{n}: duplicate row for {rule} {glob}")
            seen.add((rule, glob))
            (live if day >= today else expired).append(Row(rule, glob, expires, issue, n))
    return live, expired


def find(rows, rule_ids, path):
    """Return the first row that covers the finding, or None."""
    for row in rows:
        if row.matches(rule_ids, path):
            return row
    return None
