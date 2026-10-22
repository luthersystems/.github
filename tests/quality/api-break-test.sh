#!/usr/bin/env bash
# Tests the API break gate (actions/api-break/api-break.sh) with cases that
# must pass, cases that must fail and cases it must refuse to judge.
#
# Why each case checks the exit code and the log: the gate has three
# outcomes (0 pass, 1 unwaived break, 2 could not judge), and a gate that
# fails for another reason (a crash, a missing tool) looks the same as a
# working gate until the day it matters. So each case asserts the code and
# the reason.
#
# How: each case copies the base fixture module to a head tree, changes it,
# and runs the gate from the head tree with API_BREAK_BASE_TREE pointing at
# the base. Making each head from the base, in this file, keeps the change
# a case tests next to the case. One case builds a real git repo, to test
# the git worktree of base-sha that CI uses.
#
# Needs on PATH: go, git. It installs the pinned apidiff and apibreak.
# Run from anywhere: tests/quality/api-break-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fx="$root/tests/quality/testdata/api-break"
gate="$root/actions/api-break/api-break.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
export GOTOOLCHAIN=auto

# The versions action.yml pins, read from it, so the test runs the tools a
# caller gets.
pin() { awk -v k="$1:" '$1 == k { f = 1 } f && $1 == "default:" { print $2; exit }' "$root/actions/api-break/action.yml"; }
apidiff_v="$(pin apidiff-version)"
apibreak_v="$(pin apibreak-version)"
GOFLAGS="" GOWORK=off bash "$root/actions/lib/go-install.sh" "$work/tools" "golang.org/x/exp/cmd/apidiff@$apidiff_v" apidiff || exit 1
GOFLAGS="" GOWORK=off bash "$root/actions/lib/go-install.sh" "$work/tools" "github.com/luthersystems/elps/cmd/apibreak@$apibreak_v" apibreak || exit 1
export PATH="$work/tools:$PATH"

future="$(date -u -d '+30 days' +%F)"
past="$(date -u -d '-1 day' +%F)"

# expect <want exit code> <name> <grep -E pattern for the log> -- cmd...
expect() {
  local want="$1" name="$2" pattern="$3"
  shift 4
  local log="$work/log" status=0
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" -ne "$want" ]; then
    echo "FAIL $name: want exit $want, got $status"
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

# newhead <name>: a fresh copy of the base module, to change for one case.
newhead() {
  rm -rf "${work:?}/$1"
  cp -r "$fx/base" "$work/$1"
  echo "$work/$1"
}

# gate <head dir> [VAR=value ...]: run the gate from the head tree against
# the base fixture.
gate() {
  local dir="$1"
  shift
  (cd "$dir" && env API_BREAK_BASE_TREE="$fx/base" DIRS=. OVERRIDES=api-breaks.txt "$@" bash "$gate")
}

# --- Go surface ------------------------------------------------------------
h="$(newhead same)"
expect 0 "no change passes" "0 breaking change" -- gate "$h"
expect 0 "a missing overrides file waives nothing and says so" "no overrides file at api-breaks.txt" -- gate "$h"

h="$(newhead added)"
printf '\n// Added is new: an addition breaks no caller.\nfunc Added() {}\n' >>"$h/lib/lib.go"
expect 0 "an addition passes" "0 breaking change" -- gate "$h"

h="$(newhead removed-func)"
sed -i '/Hello/d' "$h/lib/lib.go"
expect 1 "a removed func fails" "BREAK +go lib.Hello: removed" -- gate "$h"
grep -q "unwaived breaking change::add the printed line to api-breaks.txt" "$work/log" ||
  { echo "FAIL a removed func: no annotation that names the overrides file"; fails=$((fails + 1)); }
echo "go | lib.Hello | $future | luthersystems/.github#1 | test row: Hello is removed on purpose" >"$h/api-breaks.txt"
expect 0 "an override row waives it" "WAIVED +go lib.Hello" -- gate "$h"
echo "go | lib.Hello | $past | luthersystems/.github#1 | test row: Hello is removed on purpose" >"$h/api-breaks.txt"
expect 1 "an expired override fails" "BREAK +go lib.Hello: removed \(override at line 1 EXPIRED" -- gate "$h"
echo "go | lib.Hello | $future | not-an-issue | test row: Hello is removed on purpose" >"$h/api-breaks.txt"
expect 2 "a malformed override exits 2" "OVERRIDE-BAD" -- gate "$h"

h="$(newhead removed-root-sym)"
sed -i '/Version/d' "$h/doc.go"
expect 1 "a root package symbol has a key with no package path" "BREAK +go Version: removed" -- gate "$h"

h="$(newhead removed-pkg)"
rm -r "$h/gone"
expect 1 "a removed package fails" "BREAK +go gone: package removed" -- gate "$h"

h="$(newhead became-main)"
sed -i 's/^package gone/package main/' "$h/gone/gone.go"
printf '\nfunc main() {}\n' >>"$h/gone/gone.go"
expect 1 "a package that became a command fails" "BREAK +go gone: package became a command" -- gate "$h"

h="$(newhead internal)"
sed -i '/X/d' "$h/internal/x/x.go"
expect 0 "an internal change passes" "0 breaking change" -- gate "$h"

h="$(newhead excluded)"
sed -i '/Use/d' "$h/excluded/excluded.go"
sed -i '/^import/d' "$h/excluded/excluded.go"
expect 0 "a change in an excluded package passes" "0 breaking change" -- gate "$h" EXCLUDE_DEPS=example.com/apibreak/private
expect 1 "the same change, not excluded, fails" "BREAK +go excluded.Use: removed" -- gate "$h"

h="$(newhead new-dep)"
sed -i 's|^package lib$|&\n\nimport "example.com/apibreak/private"\n\n// K now uses private.\nfunc K() string { return private.Key() }|' "$h/lib/lib.go"
expect 2 "a new dependency on an excluded path exits 2" "lib now depends on an exclude-deps path" -- gate "$h" EXCLUDE_DEPS=example.com/apibreak/private

h="$(newhead broken)"
printf '\nfunc Broken() { undefined() }\n' >>"$h/lib/lib.go"
expect 2 "a package that does not build exits 2" "could not load example.com/apibreak/lib in this change" -- gate "$h"

h="$(newhead parse-error)"
# An import of a package that does not exist: go list itself reports it.
sed -i 's|^package lib$|&\n\nimport _ "example.com/apibreak/nothere"|' "$h/lib/lib.go"
expect 2 "a package go list cannot load exits 2" "lib does not load in this change" -- gate "$h"

h="$(newhead all-internal)"
# Every package of the module is, or depends on, the excluded path.
expect 2 "a base with no public package exits 2" "has no public package" -- gate "$h" EXCLUDE_DEPS=example.com/apibreak

# --- modules not at the repo root --------------------------------------------
# The base and head are trees that hold the module under sub/mod.
mkdir -p "$work/nested-base/sub" "$work/nested-head/sub"
cp -r "$fx/base" "$work/nested-base/sub/mod"
cp -r "$fx/base" "$work/nested-head/sub/mod"
sed -i '/Hello/d' "$work/nested-head/sub/mod/lib/lib.go"
sed -i '/Version/d' "$work/nested-head/sub/mod/doc.go"
cp -r "$fx/base" "$work/nested-head/sub/new"
expect 1 "a nested module's keys start with its directory" "BREAK +go sub/mod/lib.Hello: removed" -- \
  bash -c "cd '$work/nested-head' && API_BREAK_BASE_TREE='$work/nested-base' DIRS='./sub/mod/ sub/new' bash '$gate'"
grep -qE "BREAK +go sub/mod.Version: removed" "$work/log" ||
  { echo "FAIL nested module: root package key is not sub/mod.Version"; fails=$((fails + 1)); }
if grep -q "sub/new is a new module" "$work/log"; then
  echo "ok   a new module is skipped with a notice"
else
  echo "FAIL nested module: the new module is not skipped with a notice"
  fails=$((fails + 1))
fi

# --- other surfaces ----------------------------------------------------------
h="$(newhead surface)"
mkdir -p "$h/scripts" "$work/surface-base"
cp -r "$fx/base/." "$work/surface-base/"
cp "$fx/lisp/lisp-base.json" "$work/surface-base/lisp.json"
cp "$fx/lisp/lisp-head.json" "$h/lisp.json"
cp "$fx/surface.sh" "$h/scripts/surface.sh"
expect 1 "surface-script: a removed Lisp export fails" "BREAK +lisp time:sleep: removed" -- \
  gate "$h" API_BREAK_BASE_TREE="$work/surface-base" SURFACE_SCRIPT=scripts/surface.sh
grep -qE "BREAK +lisp gone:\*: package removed" "$work/log" ||
  { echo "FAIL surface-script: removed Lisp package not reported"; fails=$((fails + 1)); }
{
  echo "lisp | time:sleep | $future | luthersystems/.github#1 | test row: sleep is removed on purpose"
  echo "lisp | gone:* | $future | luthersystems/.github#1 | test row: gone is removed on purpose"
} >"$h/api-breaks.txt"
expect 0 "surface-script: override rows waive the Lisp breaks" "WAIVED +lisp time:sleep" -- \
  gate "$h" API_BREAK_BASE_TREE="$work/surface-base" SURFACE_SCRIPT=scripts/surface.sh
rm "$h/lisp.json"
expect 2 "surface-script: a failing script exits 2" "surface-script scripts/surface.sh failed" -- \
  gate "$h" API_BREAK_BASE_TREE="$work/surface-base" SURFACE_SCRIPT=scripts/surface.sh

# --- the git worktree path and module detection --------------------------------
repo="$work/repo"
cp -r "$fx/base" "$repo"
(
  cd "$repo" && git init -q && git config user.email test@example.com && git config user.name test &&
    git add -A && git commit -qm base
) || exit 1
base_sha="$(git -C "$repo" rev-parse HEAD)"
sed -i '/Hello/d' "$repo/lib/lib.go"
git -C "$repo" commit -qam remove-hello || exit 1
expect 1 "base-sha: a worktree of the base finds the break, modules detected" "BREAK +go lib.Hello: removed" -- \
  bash -c "cd '$repo' && BASE_SHA=$base_sha bash '$gate'"
if [ -n "$(git -C "$repo" worktree list | sed 1d)" ]; then
  echo "FAIL base-sha: the gate left its worktree behind"
  fails=$((fails + 1))
fi
expect 2 "base-sha: a commit not in the clone exits 2" "is not in the clone" -- \
  bash -c "cd '$repo' && BASE_SHA=0123456789abcdef0123456789abcdef01234567 bash '$gate'"

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
