#!/usr/bin/env bash
# Tests the scripts behind the security workflow's checks, each with a case
# that must fail and a case that must pass.
#
# Why both: a check that passes everything looks the same as a working check
# until the day it matters. Each failing case also asserts the reason in the
# log, so a check that fails for another reason (a crash, a missing tool)
# does not pass the test.
#
# Needs on PATH: go, govulncheck, golangci-lint, gitleaks, osv-scanner, trivy,
# semgrep, python3 >= 3.11, git. RULES names a checkout of semgrep-rules.
# Run from the repo root: tests/security/security-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fx="$root/tests/security/testdata"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export RUNNER_TEMP="$work"
fails=0

# expect <want: pass|fail> <name> <grep pattern for the log, or ""> -- cmd...
expect() {
  local want="$1" name="$2" pattern="$3"
  shift 4
  local log="$work/log" status=0
  "$@" >"$log" 2>&1 || status=$?
  local got=pass
  [ "$status" -eq 0 ] || got=fail
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: want $want, got $got (exit $status)"
    sed 's/^/    /' "$log"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$pattern" ] && ! grep -qE "$pattern" "$log"; then
    echo "FAIL $name: log does not match /$pattern/"
    sed 's/^/    /' "$log"
    fails=$((fails + 1))
    return
  fi
  echo "ok   $name"
}

# --- govulncheck -----------------------------------------------------------
gv="$root/actions/govulncheck/govulncheck.sh"
cd "$root" || exit 1
future="$(date -u -d '+30 days' +%F)"
past="$(date -u -d '-1 day' +%F)"
mkdir -p "$work/ex"
echo "GO-2022-1059 | $future | luthersystems/.github#1 | test row" >"$work/ex/live.txt"
echo "GO-2022-1059 | $past | luthersystems/.github#1 | test row" >"$work/ex/expired.txt"
echo "GO-2022-1059 | $future | not-an-issue | test row" >"$work/ex/malformed.txt"
rel() { realpath --relative-to="$root" "$1"; }

expect fail "govulncheck: called finding fails" "GO-2022-1059.*fixed in v0.3.8" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS=.github/security/none.txt bash "$gv"
expect pass "govulncheck: live exemption passes" "finding exempted::GO-2022-1059" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS="$(rel "$work/ex/live.txt")" bash "$gv"
expect fail "govulncheck: expired exemption fails" "exemption expired::GO-2022-1059 expired $past" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS="$(rel "$work/ex/expired.txt")" bash "$gv"
expect fail "govulncheck: malformed exemptions fail" "exemptions malformed" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS="$(rel "$work/ex/malformed.txt")" bash "$gv"
expect pass "govulncheck: clean module passes" "0 called finding" -- \
  env DIRS=tests/security/testdata/go-clean EXEMPTIONS= bash "$gv"
expect fail "govulncheck: binary mode reports what it finds" "not exempted::GO-2022-1059 in .*-mode=binary" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS= BINARY=true bash "$gv"
expect pass "govulncheck: binary mode honours the exemption" "finding exempted.*\\(-mode=binary" -- \
  env DIRS=tests/security/testdata/go-vuln EXEMPTIONS="$(rel "$work/ex/live.txt")" BINARY=true bash "$gv"
mkdir -p "$work/broken"
printf 'module example.com/broken\n\ngo 1.24.0\n' >"$work/broken/go.mod"
printf 'package main\n\nfunc main() { undefined() }\n' >"$work/broken/main.go"
expect fail "govulncheck: a build failure is not read as clean" "build failure, not a finding" -- \
  env DIRS="$work/broken" EXEMPTIONS= BINARY=true bash "$gv"

# --- gosec -----------------------------------------------------------------
gs="$root/actions/gosec/gosec.sh"
cd "$root" || exit 1
expect fail "gosec: a G204 finding fails" "G204" -- env DIRS=tests/security/testdata/go-gosec bash "$gs"
expect pass "gosec: a clean module passes" "" -- env DIRS=tests/security/testdata/go-clean bash "$gs"

# --- osv-scanner -----------------------------------------------------------
osv="$root/actions/osv-scan/osv-scan.sh"
mkdir -p "$work/npm" "$work/empty"
cp "$fx/npm-vuln/package-lock.json" "$work/npm/"
cd "$work/npm" || exit 1
expect fail "osv: fixable High and Critical fail" "fixable severity 9.8::minimist@1.2.5" -- bash "$osv"
ids="CVE-2021-23337 CVE-2020-8203 CVE-2026-4800 CVE-2021-44906"
for id in $ids; do
  printf '[[IgnoredVulns]]\nid = "%s"\nignoreUntil = %s\nreason = "test row"\n\n' "$id" "$future"
done >osv-scanner.toml
# osv-scanner groups aliases, and the ignore may name either alias; the gate
# must pass once every blocking group is ignored.
expect pass "osv: ignored with an expiry passes" "no fixable High or Critical" -- bash "$osv"
sed -i 's/^reason = .*//' osv-scanner.toml
expect fail "osv: ignore row with no reason fails" "has no reason" -- bash "$osv"
sed -i 's/^ignoreUntil = .*//' osv-scanner.toml
expect fail "osv: ignore row with no expiry fails" "has no ignoreUntil" -- bash "$osv"
rm osv-scanner.toml
mkdir -p "$work/excl/sub"
cp "$fx/npm-vuln/package-lock.json" "$work/excl/sub/"
cd "$work/excl" || exit 1
expect pass "osv: an excluded directory is not scanned" "no fixable High or Critical" -- env EXCLUDE=sub bash "$osv"
expect fail "osv: the same directory, not excluded, fails" "fixable severity" -- bash "$osv"
cd "$work/empty" || exit 1
expect pass "osv: no lockfile passes" "no fixable High or Critical" -- bash "$osv"
cp -r "$fx/go-vuln" "$work/empty/go"
expect pass "osv: Go is left to govulncheck" "no fixable High or Critical" -- bash "$osv"

# --- lockfile warning ------------------------------------------------------
mkdir -p "$work/nolock"
cd "$work/nolock" || exit 1
git init -q .
printf '{"dependencies": {"lodash": "^4.17.21"}}\n' >package.json
printf 'tomli>=2\n' >requirements.txt
git add . && git -c user.email=t@e -c user.name=t commit -qm x
expect pass "osv: a manifest with no lockfile warns" "package.json has dependencies but no lockfile" -- bash "$osv"
expect pass "osv: an unpinned requirements file warns" "Unpinned requirements" -- bash "$osv"

# --- trivy config ----------------------------------------------------------
tv="$root/actions/trivy-config/trivy-config.sh"
mkdir -p "$work/iac"
cp "$fx/iac-misconfig/Dockerfile" "$work/iac/"
cd "$work/iac" || exit 1
git init -q .
git add . && git -c user.email=t@e -c user.name=t commit -qm x
mkdir -p .github/security
expect fail "trivy: a High misconfiguration fails" "Trivy HIGH misconfiguration DS-0002::not exempted" -- \
  env EXEMPTIONS=.github/security/trivy-exemptions.txt bash "$tv"
echo "DS-0002 | Dockerfile | $future | luthersystems/.github#1 | test row" >.github/security/trivy-exemptions.txt
expect pass "trivy: a live exemption passes" "Trivy finding exempted::DS-0002" -- \
  env EXEMPTIONS=.github/security/trivy-exemptions.txt bash "$tv"
echo "AVD-DS-0002 | * | $future | luthersystems/.github#1 | test row" >.github/security/trivy-exemptions.txt
expect pass "trivy: the AVD id and a * path match too" "Trivy finding exempted::DS-0002" -- \
  env EXEMPTIONS=.github/security/trivy-exemptions.txt bash "$tv"
echo "DS-0002 | Dockerfile | $past | luthersystems/.github#1 | test row" >.github/security/trivy-exemptions.txt
expect fail "trivy: an expired exemption fails" "exemption expired $past" -- \
  env EXEMPTIONS=.github/security/trivy-exemptions.txt bash "$tv"
echo "DS-0002 | Dockerfile | $future | not-an-issue | test row" >.github/security/trivy-exemptions.txt
expect fail "trivy: a malformed exemption fails" "Trivy exemptions malformed" -- \
  env EXEMPTIONS=.github/security/trivy-exemptions.txt bash "$tv"
rm .github/security/trivy-exemptions.txt
expect pass "trivy: a skipped directory is not scanned" "no High or Critical misconfiguration blocks" -- \
  env SKIP_DIRS=. EXEMPTIONS= bash "$tv"
printf 'FROM alpine:3.20\nUSER 65534\n# trivy:ignore:DS-0026\nRUN true\n' >Dockerfile
git add . && git -c user.email=t@e -c user.name=t commit -qm y
expect fail "trivy: an inline ignore with no expiry fails" "Inline Trivy ignore without an expiry" -- \
  env EXEMPTIONS= bash "$tv"
cd "$work/empty" || exit 1
expect pass "trivy: nothing to scan passes" "no High or Critical misconfiguration blocks" -- env EXEMPTIONS= bash "$tv"

# --- semgrep ---------------------------------------------------------------
sg="$root/actions/semgrep/semgrep.sh"
mkdir -p "$work/sast"
cp "$fx/sast-vuln/app.py" "$work/sast/"
cd "$work/sast" || exit 1
git init -q .
git add . && git -c user.email=t@e -c user.name=t commit -qm x
mkdir -p .github/security
expect fail "semgrep: an ERROR security finding fails" "Semgrep python.lang.security.audit.subprocess-shell-true::not exempted" -- \
  env RULES="$RULES" LANGS=python EXEMPTIONS=.github/security/semgrep-exemptions.txt bash "$sg"
echo "python.lang.security.audit.subprocess-shell-true | app.py | $future | luthersystems/.github#1 | test row" >.github/security/semgrep-exemptions.txt
expect pass "semgrep: a live exemption passes" "Semgrep finding exempted" -- \
  env RULES="$RULES" LANGS=python EXEMPTIONS=.github/security/semgrep-exemptions.txt bash "$sg"
sed -i "s/$future/$past/" .github/security/semgrep-exemptions.txt
expect fail "semgrep: an expired exemption fails" "exemption expired $past" -- \
  env RULES="$RULES" LANGS=python EXEMPTIONS=.github/security/semgrep-exemptions.txt bash "$sg"
rm .github/security/semgrep-exemptions.txt
expect pass "semgrep: an excluded file is not scanned" "no security finding blocks" -- \
  env RULES="$RULES" LANGS=python EXCLUDE=app.py bash "$sg"
sed -i 's/shell=True)/shell=True)  # nosemgrep/' app.py
git add . && git -c user.email=t@e -c user.name=t commit -qm y
expect fail "semgrep: a bare nosemgrep fails" "nosemgrep without a rule id" -- \
  env RULES="$RULES" LANGS=python bash "$sg"
sed -i 's/# nosemgrep$/# nosemgrep: python.lang.security.audit.subprocess-shell-true/' app.py
git add . && git -c user.email=t@e -c user.name=t commit -qm z
expect pass "semgrep: a nosemgrep naming the rule passes" "no security finding blocks" -- \
  env RULES="$RULES" LANGS=python bash "$sg"

# --- gitleaks --------------------------------------------------------------
gl="$root/actions/gitleaks/gitleaks.sh"
repo="$work/leak"
git init -q "$repo"
cd "$repo" || exit 1
git config user.email test@example.com
git config user.name test
echo "clean" >README
git add README && git commit -qm clean
base="$(git rev-parse HEAD)"
# A fake AWS access key id, built at run time so no commit of this repo
# holds one (push protection would refuse the push).
key="AKIA$(head -c 64 /dev/urandom | base32 | tr -dc 'A-Z2-7' | head -c 16)"
printf 'aws_access_key_id = %s\n' "$key" >config.ini
git add config.ini && git commit -qm leak
head="$(git rev-parse HEAD)"
echo "more" >>README
git add README && git commit -qm clean-again
clean="$(git rev-parse HEAD)"

expect fail "gitleaks: PR range with a key fails" "found a secret" -- \
  env EVENT=pull_request BASE="$base" HEAD="$head" bash "$gl"
# A range with one real, clean commit after the leak: only the commits the PR
# adds are scanned, so an older leak does not fail it.
expect pass "gitleaks: PR range without it passes" "" -- \
  env EVENT=pull_request BASE="$head" HEAD="$clean" bash "$gl"
expect fail "gitleaks: push range fails" "found a secret" -- \
  env EVENT=push BEFORE="$base" AFTER="$head" bash "$gl"
expect fail "gitleaks: scheduled scan of HEAD fails" "found a secret" -- env EVENT=schedule bash "$gl"
if grep -q "$key" "$work/log"; then
  echo "FAIL gitleaks: the log shows the secret (it must be redacted)"
  fails=$((fails + 1))
else
  echo "ok   gitleaks: the log redacts the secret"
fi
# The fingerprint of a file finding is file:rule:line.
echo "config.ini:aws-access-token:1" >.gitleaksignore
expect pass "gitleaks: .gitleaksignore fingerprint passes" "" -- env EVENT=schedule bash "$gl"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
