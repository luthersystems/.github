#!/usr/bin/env bash
# Tests the auto-fix pieces that can run without an agent: the prompt
# builder, and the rule that keeps security.yml startable by every caller.
#
# Why the permissions rule: a job of a reusable workflow that asks for a
# permission its caller did not grant stops the whole workflow at startup,
# skipped or not (luthersystems/.github#13 probed it: startup_failure). The
# 48 callers grant only contents: read and issues: write, so a job here that
# asks for more would break every repo's required check at once.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL $*" >&2; exit 1; }

# The prompt builder: values are put in as text, never evaluated, and no
# value can end the multi-line output early.
out="$(FAILED='govulncheck $(touch /tmp/pwned) & `id`' EXEMPTIONS='x.txt' RUN_URL='https://u/1' \
  bash "$root/actions/security-autofix/prompt.sh" "$root/actions/security-autofix/prompt.md")"
grep -qF 'failed: govulncheck $(touch /tmp/pwned) & `id`' <<<"$out" || fail "prompt: FAILED not put in as text"
grep -qF 'https://u/1' <<<"$out" || fail "prompt: RUN_URL missing"
grep -qF 'x.txt' <<<"$out" || fail "prompt: EXEMPTIONS missing"
! grep -q '@[A-Z_]*@' <<<"$out" || fail "prompt: a placeholder was left"
delim="$(head -1 <<<"$out" | sed 's/^prompt<<//')"
[ "$(tail -1 <<<"$out")" = "$delim" ] || fail "prompt: output does not end with its delimiter"
[ "$(grep -cxF "$delim" <<<"$out")" = 1 ] || fail "prompt: delimiter appears inside the prompt"
echo "ok   autofix: prompt builder"

# The permissions rule. Allowed: contents: read anywhere, and issues: write
# (which every caller grants) on the result job only.
python3 - "$root/.github/workflows/security.yml" <<'PY' || fail "permissions: see above"
import re, sys
text = open(sys.argv[1]).read()
if re.search(r"^permissions:", text, re.M):
    sys.exit("security.yml: workflow-level permissions would cap the autofix job; set them per job")
bad = []
job = None
inperm = False
for line in text.splitlines():
    m = re.match(r"^  ([a-z][a-z0-9-]*):$", line)
    if m:
        job, inperm = m.group(1), False
        continue
    if re.match(r"^    permissions:", line):
        inperm = True
        continue
    if inperm:
        m = re.match(r"^      ([a-z-]+): *(\S+)", line)
        if not m:
            inperm = False
            continue
        perm, level = m.groups()
        if level == "read" and perm == "contents":
            continue
        if job == "result" and perm == "issues" and level == "write":
            continue
        bad.append(f"{job}: {perm}: {level}")
if bad:
    sys.exit("security.yml jobs ask for permissions a read-only caller lacks: " + ", ".join(bad))
PY
echo "ok   autofix: no job asks for more than a read-only caller grants"
