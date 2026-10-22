#!/usr/bin/env python3
# Copyright © 2026 Luther Systems, Ltd. All right reserved.
"""Unit tests for actions/osv-scan/osv-gate.py's version and fix logic.

Why: the gate blocks a merge only on a fixable High or Critical, so it must
tell which release line the installed version is on. A fix on 1.x is no fix
for 2.x, and reading it as one would block a merge that only a major
downgrade could clear. The end-to-end cases are in security-test.sh.
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "osv_gate", os.path.join(HERE, "../../actions/osv-scan/osv-gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def vulns(*ranges, versions=None):
    aff = {"package": {"name": "x", "ecosystem": "npm"},
           "ranges": [{"type": "SEMVER", "events": list(r)} for r in ranges]}
    if versions:
        aff["versions"] = versions
    return {"A": {"affected": [aff]}}


def fix(version, v):
    return gate.fix_for({"name": "x", "version": version, "ecosystem": "npm"}, {"ids": ["A"]}, v)


class VersionKey(unittest.TestCase):
    def test_order(self):
        k = gate.version_key
        self.assertLess(k("1.9"), k("1.10"))
        self.assertLess(k("1.2.0-rc1"), k("1.2.0"))
        self.assertLess(k("1.2.0-alpha"), k("1.2.0-beta"))
        self.assertEqual(k("1.2"), k("1.2.0"))
        self.assertEqual(k("v1.2.0"), k("1.2.0"))


class FixFor(unittest.TestCase):
    two_lines = vulns([{"introduced": "1.0.0"}, {"fixed": "1.5.0"}, {"introduced": "2.0.0"}])

    def test_fixed_on_its_line(self):
        self.assertEqual(fix("1.2.0", self.two_lines), (True, ["1.5.0"]))

    def test_open_line_is_not_fixable(self):
        self.assertEqual(fix("2.1.0", self.two_lines), (False, []))

    def test_only_the_fix_above_the_installed_version(self):
        v = vulns([{"introduced": "0"}, {"fixed": "0.2.4"}, {"introduced": "1.0.0"}, {"fixed": "1.2.6"}])
        self.assertEqual(fix("1.2.5", v), (True, ["1.2.6"]))

    def test_last_affected_has_no_fix(self):
        v = vulns([{"introduced": "0"}, {"last_affected": "3.0.0"}])
        self.assertEqual(fix("2.0.0", v), (False, []))

    def test_unknown_line_with_a_fix_blocks(self):
        # The installed version is in no range the gate can read: it blocks,
        # because a blocked merge can be exempted and a missed one is unseen.
        v = vulns([{"introduced": "5.0.0"}, {"fixed": "5.1.0"}])
        self.assertEqual(fix("1.0.0", v), (True, ["5.1.0"]))


class Config(unittest.TestCase):
    def write(self, text):
        import tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
        f.write(text)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_good_row(self):
        import datetime
        p = self.write('[[IgnoredVulns]]\nid = "A"\nignoreUntil = 2099-01-01\nreason = "r"\n')
        self.assertEqual(gate.check_config(p, datetime.date(2026, 1, 1)), [])

    def test_missing_fields(self):
        import datetime
        p = self.write('[[IgnoredVulns]]\nid = "A"\n')
        problems = gate.check_config(p, datetime.date(2026, 1, 1))
        self.assertEqual(len(problems), 2)

    def test_missing_file_is_no_exemptions(self):
        import datetime
        self.assertEqual(gate.check_config("/nonexistent/osv-scanner.toml", datetime.date(2026, 1, 1)), [])


if __name__ == "__main__":
    unittest.main()
