#!/usr/bin/env bash
# Tests the scripts behind actions/golangci-lint, each with a case that must
# fail and a case that must pass.
#
# Why both: a check that passes everything looks the same as a working check
# until the day it matters. Each failing case also asserts the reason in the
# log, so a check that fails for another reason (a crash, a missing tool)
# does not pass the test.
#
# The fixtures are under testdata/, which find-go-modules.sh skips, so the
# module with a lint finding on purpose never fails this repo's own checks.
# The canned `golangci-lint linters` outputs in testdata/golangci/linters
# came from golangci-lint v2.15.0 (repo.txt: the fixtures' config; baseline.txt:
# quality/golangci-baseline.yml), so the drift parse is tested on the real
# format with no tool. The godox line is cut from both: its text holds work
# marker words, which the work marker gate would fail on in this repo.
#
# Needs on PATH: go, golangci-lint (the version actions/golangci-lint pins).
# Run from the repo root: tests/quality/golangci-lint-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fx=tests/quality/testdata/golangci
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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

# refute <name> <grep pattern>: the last log must not match.
refute() {
  if grep -qE "$2" "$work/log"; then
    echo "FAIL $1: log matches /$2/"
    sed 's/^/    /' "$work/log"
    fails=$((fails + 1))
  else
    echo "ok   $1"
  fi
}

cd "$root" || exit 1
gl="$root/actions/golangci-lint/golangci-lint.sh"
drift="$root/actions/golangci-lint/baseline-drift.sh"

# --- baseline-drift.sh on canned output ------------------------------------

# The counts also prove the parse stops at the Disabled section: read as
# enabled, those linters would change both counts.
expect pass "drift: lists the linters the repo lacks and adds" \
  "lacks 21 baseline linter\(s\) \(bodyclose .*gosec .*wastedassign\) and adds 1 \(misspell\)" -- \
  env -u GITHUB_STEP_SUMMARY bash "$drift" "$fx/linters/repo.txt" "$fx/linters/baseline.txt" mod
# The backticks are markdown, not a command, so single quotes are right.
# shellcheck disable=SC2016
expect pass "drift: the table names the missing and added linters" \
  '^\| Repo adds \| 1 \| `misspell` \|$' -- \
  env -u GITHUB_STEP_SUMMARY bash "$drift" "$fx/linters/repo.txt" "$fx/linters/baseline.txt" mod

expect pass "drift: the same config has no drift" "lacks 0 baseline linter\(s\) and adds 0\." -- \
  env -u GITHUB_STEP_SUMMARY bash "$drift" "$fx/linters/baseline.txt" "$fx/linters/baseline.txt"

summary="$work/summary.md"
: >"$summary"
expect pass "drift: the table goes to GITHUB_STEP_SUMMARY" "::notice" -- \
  env GITHUB_STEP_SUMMARY="$summary" bash "$drift" "$fx/linters/repo.txt" "$fx/linters/baseline.txt" mod
if grep -q '^| Baseline enables, repo does not | 21 |' "$summary"; then
  echo "ok   drift: the summary holds the table"
else
  echo "FAIL drift: the summary holds no table"
  sed 's/^/    /' "$summary"
  fails=$((fails + 1))
fi

# Color codes, as a terminal run prints them, must not hide the names.
sed -e $'s/^\\([a-z0-9_-]*\\):/\x1b[1m\\1\x1b[0m:/' "$fx/linters/repo.txt" >"$work/color.txt"
expect pass "drift: color codes are stripped" "adds 1 \(misspell\)" -- \
  env -u GITHUB_STEP_SUMMARY bash "$drift" "$work/color.txt" "$fx/linters/baseline.txt"

printf 'something else entirely\n' >"$work/garbage.txt"
expect fail "drift: an unknown format is not read as no drift" "format may have changed" -- \
  bash "$drift" "$work/garbage.txt" "$fx/linters/baseline.txt"
expect fail "drift: a missing file fails" "cannot read" -- \
  bash "$drift" "$work/none.txt" "$fx/linters/baseline.txt"

# --- golangci-lint.sh with the tool ----------------------------------------

expect fail "lint: an unchecked error fails" "errcheck" -- \
  env DIRS="$fx/lint-fail" BASELINE_REPORT=false bash "$gl"
expect fail "lint: the failure names the module" "::error title=golangci-lint::.* in $fx/lint-fail" -- \
  env DIRS="$fx/lint-fail" BASELINE_REPORT=false bash "$gl"
expect pass "lint: a clean module passes" "" -- \
  env DIRS="$fx/clean" BASELINE_REPORT=false bash "$gl"
# One failing module must not hide the next: both run, one error.
expect fail "lint: every module runs, the failing one fails" "golangci-lint $fx/clean" -- \
  env DIRS="$fx/lint-fail $fx/clean" BASELINE_REPORT=false bash "$gl"
refute "lint: the clean module is not reported" "::error title=golangci-lint::.* in $fx/clean"

: >"$summary"
expect pass "lint: the drift report runs on the real tool" "lacks 21 baseline linter\(s\).* adds 1 \(misspell\)" -- \
  env DIRS="$fx/clean" BASELINE_REPORT=true GITHUB_STEP_SUMMARY="$summary" bash "$gl"
# shellcheck disable=SC2016 # backticks are markdown, not a command
if grep -q '^| Repo adds | 1 | `misspell` |$' "$summary"; then
  echo "ok   lint: the drift table is in the job summary"
else
  echo "FAIL lint: the drift table is not in the job summary"
  sed 's/^/    /' "$summary"
  fails=$((fails + 1))
fi
expect pass "lint: a broken drift report does not fail the job" "cannot read the baseline" -- \
  env DIRS="$fx/clean" BASELINE_REPORT=true BASELINE="$work/none.yml" bash "$gl"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
