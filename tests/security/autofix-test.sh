#!/usr/bin/env bash
# Tests the auto-fix pieces that can run without an agent: the prompt
# builder, and the rule that keeps security.yml startable by every caller.
#
# Why the permissions rule: a job of a reusable workflow that asks for a
# permission its caller did not grant stops the whole workflow at startup,
# skipped or not (luthersystems/.github#13 probed it: startup_failure). The
# 48 callers grant only contents: read and issues: write, so a job here that
# asks for more would break every repo's required check at once.
# The tests pass $(...) and $VAR in single quotes on purpose: the values
# must reach the code under test unexpanded.
# shellcheck disable=SC2016
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL $*" >&2; exit 1; }

# The prompt builder: values are put in as text, never evaluated, and no
# value can end the multi-line output early.
out="$(FAILED='govulncheck $(touch /tmp/pwned) & `id`' RUN_ID='77-1' RUN_URL='https://u/1' \
  bash "$root/actions/security-autofix/prompt.sh" "$root/actions/security-autofix/prompt.md")"
grep -qF 'failed: govulncheck $(touch /tmp/pwned) & `id`' <<<"$out" || fail "prompt: FAILED not put in as text"
grep -qF 'https://u/1' <<<"$out" || fail "prompt: RUN_URL missing"
grep -qF 'security-autofix/77-1' <<<"$out" || fail "prompt: RUN_ID missing"
! grep -q '@[A-Z_]*@' <<<"$out" || fail "prompt: a placeholder was left"
delim="$(head -1 <<<"$out" | sed 's/^prompt<<//')"
[ "$(tail -1 <<<"$out")" = "$delim" ] || fail "prompt: output does not end with its delimiter"
[ "$(grep -cxF "$delim" <<<"$out")" = 1 ] || fail "prompt: delimiter appears inside the prompt"
echo "ok   autofix: prompt builder"

# The gate commands hold their values as data, and run-untrusted drops the
# job's credentials.
bin="$(mktemp -d)"
BIN="$bin" ACTIONS_DIR="$root/actions" DIRS='a b' EXEMPTIONS='x $(touch /tmp/pwned).txt' \
  EXCLUDE=$'tests\ng:fix*' GITHUB_PATH=/dev/null bash "$root/actions/security-autofix/setup.sh"
# Run each command with its exec swapped for a print of what it exported.
show() { bash -c "source <(sed 's/^exec .*/printf \"%s|\" $2/' \"\$1\")" _ "$1"; }
got="$(show "$bin/security-gate-govulncheck" '"$DIRS" "$EXEMPTIONS" "$BINARY"')"
[ "$got" = 'a b|x $(touch /tmp/pwned).txt|true|' ] || fail "gate: govulncheck env: $got"
got="$(show "$bin/security-gate-dependencies" '"$EXCLUDE" "$SKIP_GO"')"
[ "$got" = $'tests\ng:fix*|true|' ] || fail "gate: dependencies env: $got"
grep -qF "$root/actions/govulncheck/govulncheck.sh" "$bin/security-gate-govulncheck" || fail "gate: wrong govulncheck script"
grep -qF "$root/actions/osv-scan/osv-scan.sh" "$bin/security-gate-dependencies" || fail "gate: wrong osv script"
[ ! -e /tmp/pwned ] || fail "gate: a value was evaluated"
env_out="$(ACTIONS_ID_TOKEN_REQUEST_TOKEN=t ACTIONS_ID_TOKEN_REQUEST_URL=u AWS_SECRET_ACCESS_KEY=s \
  SSH_AUTH_SOCK=/s GITHUB_TOKEN=g GH_TOKEN=g GOFLAGS=-mod=mod "$bin/run-untrusted" env)"
! grep -qE '^(ACTIONS_ID_TOKEN|AWS_|SSH_AUTH_SOCK|GITHUB_TOKEN|GH_TOKEN)' <<<"$env_out" || fail "run-untrusted kept a credential: $env_out"
grep -qx 'GOFLAGS=-mod=mod' <<<"$env_out" || fail "run-untrusted dropped GOFLAGS"
rm -rf "$bin"
echo "ok   autofix: gate commands and run-untrusted"

# The agent installs the gate's scanner versions. A bump of one without the
# other leaves the agent unable to reproduce the gate's findings.
pin() { awk -v k="$2:" '$1==k{f=1} f&&$1=="default:"{print $2; exit}' "$1"; }
[ "$(pin "$root/actions/govulncheck/action.yml" version)" = "$(pin "$root/actions/security-autofix/action.yml" govulncheck-version)" ] ||
  fail "pins: govulncheck version differs between actions/govulncheck and actions/security-autofix"
[ "$(pin "$root/actions/osv-scan/action.yml" version)" = "$(pin "$root/actions/security-autofix/action.yml" osv-scanner-version)" ] ||
  fail "pins: osv-scanner version differs between actions/osv-scan and actions/security-autofix"
echo "ok   autofix: scanner pins match the gate"

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
    m = re.match(r"^    permissions:\s*(\S.*)?$", line)
    if m:
        if m.group(1) and not m.group(1).startswith("#"):
            bad.append(f"{job}: permissions: {m.group(1)} (write it as a block map)")
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
