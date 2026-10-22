#!/usr/bin/env bash
# Single quotes on purpose: these are bash -c bodies and Markdown backquotes.
# shellcheck disable=SC2016
# Tests the scripts behind actions/benchmark-run and actions/benchmark-gate,
# each with cases that must fail and cases that must pass. Ported from the
# benchmark cases of elps's and substrate's scripts/ci-gates-test.sh.
#
# Why both: a gate that passes everything looks like a working gate until the
# day it matters. elps's benchmark gate was dead for 473 runs (an inline grep
# no benchstat line could match), and nothing noticed. Each failing case also
# asserts the reason, so a check that fails for another reason (a crash, a
# missing file) does not pass the test.
#
# Fake go, benchstat and benchgate (testdata/bin) stand in for the real tools:
# this tests the plumbing. benchgate's verdicts are tested in luthersystems/elps.
#
# Needs on PATH: bash, awk, sed, grep, node.
# Run from anywhere: tests/benchmark/benchmark-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_dir="$root/actions/benchmark-run"
gate_dir="$root/actions/benchmark-gate"
fakes="$root/tests/benchmark/testdata/bin"
ARMS="$run_dir/arms-check.sh"
SAMPLES="$run_dir/samples-check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

# expect <want-exit> <name> <grep -E pattern for the output, or ""> -- cmd...
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
  # A here-string, not `cat | grep -q`: grep -q stops at the first match, and
  # under pipefail the writer then dies of SIGPIPE on a large output, which
  # reads as a miss.
  if [ -n "$pattern" ] && ! grep -qE -- "$pattern" <<<"$(cat "$log")"; then
    echo "FAIL $name: output does not match /$pattern/"
    sed 's/^/    /' "$log"
    fails=$((fails + 1))
    return
  fi
  echo "ok   $name"
}

# expect_not <name> <grep -E pattern that must NOT be in the output> -- cmd...
# The exit code is checked first: a command that could not run (126, 127,
# 128+) prints nothing, and the pattern would be absent for that reason only.
expect_not() {
  local name="$1" pattern="$2"
  shift 3
  local log="$work/log" status=0
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" -gt 125 ]; then
    echo "FAIL $name: the command could not run (exit $status)"
    fails=$((fails + 1))
  elif grep -qE -- "$pattern" <<<"$(cat "$log")"; then
    echo "FAIL $name: output matches /$pattern/"
    sed 's/^/    /' "$log"
    fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

# ===========================================================================
# samples-check.sh
# ===========================================================================
st="$work/samples"
mkdir -p "$st"
# raw_fixture <file> <good rows> <mangled rows>. The mangled row is a real one
# from a substrate CI log: a plugin logger wrote on the result line.
raw_fixture() {
  local i
  {
    printf 'goos: linux\ngoarch: arm64\npkg: example.com/stresstest\n'
    for ((i = 0; i < $2; i++)); do
      printf 'BenchmarkMockParallel-4\t       1\t 102731719 ns/op\t  326464 B/op\t    1798 allocs/op\n'
    done
    for ((i = 0; i < $3; i++)); do
      printf 'BenchmarkMockParallel-4\t2026-08-10T20:45:40.034Z [DEBUG] plugin: starting plugin: path=/x\n'
    done
    for i in 1 2 3 4 5; do
      printf 'BenchmarkChain-4\t 7000000\t     157.6 ns/op\t     224 B/op\t       2 allocs/op\n'
    done
    echo "PASS"
  } >"$1"
}
# The filter of filter.sh, so the fixtures get what CI gives the check.
filter_fixture() {
  grep -E '^(goos|goarch|pkg|cpu):|^Benchmark[^ ]+[[:space:]]+[0-9]+[[:space:]]' "$1" >"$2" || true
}
raw_fixture "$st/full-raw.txt" 5 0
filter_fixture "$st/full-raw.txt" "$st/full.txt"
raw_fixture "$st/n1-raw.txt" 1 4
filter_fixture "$st/n1-raw.txt" "$st/n1.txt"
raw_fixture "$st/gone-raw.txt" 0 5
filter_fixture "$st/gone-raw.txt" "$st/gone.txt"
: >"$st/empty.txt"

expect 0 "samples: each benchmark at the count passes" "all 2 benchmark" -- \
  env BENCH_MIN_SAMPLES=5 bash "$SAMPLES" "$st/full.txt" "$st/full-raw.txt"
expect 0 "samples: one argument reads one file as raw and filtered" "" -- \
  env BENCH_MIN_SAMPLES=5 bash "$SAMPLES" "$st/full.txt"
expect 2 "samples: 4 of 5 rows mangled fails, naming the benchmark" "SHORT +BenchmarkMockParallel-4 +samples=1 want>=5 mangled_rows=4" -- \
  env BENCH_MIN_SAMPLES=5 bash "$SAMPLES" "$st/n1.txt" "$st/n1-raw.txt"
expect 2 "samples: the short benchmark gets an annotation" "::warning::benchmark BenchmarkMockParallel-4" -- \
  env BENCH_MIN_SAMPLES=5 bash "$SAMPLES" "$st/n1.txt" "$st/n1-raw.txt"
expect 2 "samples: a benchmark that lost every row fails with count 0" "samples=0" -- \
  env BENCH_MIN_SAMPLES=5 bash "$SAMPLES" "$st/gone.txt" "$st/gone-raw.txt"
expect 0 "samples: warn-only reports without failing" "report only" -- \
  env BENCH_MIN_SAMPLES=5 BENCH_SAMPLES_WARN_ONLY=1 bash "$SAMPLES" "$st/n1.txt" "$st/n1-raw.txt"
expect 2 "samples: empty output is an error" "is empty" -- bash "$SAMPLES" "$st/empty.txt"
expect 2 "samples: a missing file is an error" "no such file" -- bash "$SAMPLES" "$st/nope.txt"
expect 2 "samples: no argument is a usage error" "usage" -- bash "$SAMPLES"
expect 2 "samples: a non-numeric minimum fails closed" "must be an integer" -- \
  env BENCH_MIN_SAMPLES=lots bash "$SAMPLES" "$st/full.txt"

# ===========================================================================
# arms-check.sh
# ===========================================================================
at="$work/arms"
mkdir -p "$at"
# arms_fixture <file> <cpu> <suffix, empty for none> [extra benchmark]
arms_fixture() {
  local s=""
  [ -z "$3" ] || s="-$3"
  {
    printf 'goos: linux\ngoarch: arm64\npkg: example.com/m/lisp\ncpu: %s\n' "$2"
    for _ in 1 2 3 4 5 6; do
      printf 'BenchmarkEnvGet%s\t  138022\t      8104 ns/op\t    1808 B/op\t      27 allocs/op\n' "$s"
      printf 'BenchmarkEnvFunCall%s\t   58022\t     18104 ns/op\t    3808 B/op\t      57 allocs/op\n' "$s"
      [ -z "${4:-}" ] || printf 'Benchmark%s%s\t   58022\t     18104 ns/op\t    3808 B/op\t      57 allocs/op\n' "$4" "$s"
    done
    echo "PASS"
  } >"$1"
}
arms_fixture "$at/base.txt" Neoverse-N1 4
arms_fixture "$at/pr.txt" Neoverse-N1 4
arms_fixture "$at/procs2.txt" Neoverse-N1 2
arms_fixture "$at/othercpu.txt" "AMD EPYC 7763" 4
arms_fixture "$at/extra.txt" Neoverse-N1 4 NewlyAdded
sed 's/^goos: linux/goos: darwin/' "$at/base.txt" >"$at/darwin.txt"
# GOMAXPROCS=1: no suffix; a name's own trailing -N is not one (elps#767).
{
  printf 'goos: linux\ngoarch: arm64\npkg: example.com/p\n'
  printf 'BenchmarkEnvGet\t 100\t 10 ns/op\nBenchmarkPkg/get-nested-2\t 100\t 10 ns/op\n'
} >"$at/procs1.txt"
{
  printf 'goos: linux\ngoarch: arm64\npkg: example.com/p\n'
  printf 'BenchmarkEnvGet-4\t 100\t 10 ns/op\nBenchmarkPkg/get-nested-2-4\t 100\t 10 ns/op\n'
} >"$at/procs4.txt"
{
  printf 'goos: linux\ngoarch: arm64\npkg: example.com/q\n'
  printf 'BenchmarkOther-4\t 100\t 10 ns/op\n'
} >"$at/other-names.txt"
: >"$at/empty.txt"
printf 'goos: linux\ngoarch: arm64\nFAIL\texample.com/m/lisp [build failed]\n' >"$at/nobench.txt"
# A second package with benchmarks in base; it fails to build or set up in pr.
cp "$at/base.txt" "$at/twopkg-base.txt"
{
  echo "pkg: example.com/m/core"
  for _ in 1 2 3 4 5 6; do printf 'BenchmarkCore-4\t 58022\t 18104 ns/op\n'; done
} >>"$at/twopkg-base.txt"
cp "$at/pr.txt" "$at/broken-pr.txt"
printf 'FAIL\texample.com/m/core [build failed]\n' >>"$at/broken-pr.txt"
cp "$at/pr.txt" "$at/setup-pr.txt"
printf 'FAIL\texample.com/m/core [setup failed]\n' >>"$at/setup-pr.txt"
cp "$at/pr.txt" "$at/license-pr.txt"
printf 'FAIL\texample.com/m/licensemanager [setup failed]\n' >>"$at/license-pr.txt"

expect 0 "arms: same configuration and names are comparable" "arms are comparable" -- \
  bash "$ARMS" "$at/base.txt" "$at/pr.txt"
expect 2 "arms: a goos mismatch is not comparable" "goos: base=\[darwin\] pr=\[linux\]" -- \
  bash "$ARMS" "$at/darwin.txt" "$at/pr.txt"
expect 2 "arms: a cpu mismatch is not comparable, naming the header" "cpu: base=\[AMD EPYC 7763\]" -- \
  bash "$ARMS" "$at/othercpu.txt" "$at/pr.txt"
expect 2 "arms: a GOMAXPROCS suffix mismatch is diagnosed as such" "GOMAXPROCS suffix: base benchmarks end in -\[2\], PR benchmarks in -\[4\]" -- \
  bash "$ARMS" "$at/procs2.txt" "$at/pr.txt"
expect 0 "arms: GOMAXPROCS=1 names that end in their own -N are comparable" "" -- \
  bash "$ARMS" "$at/procs1.txt" "$at/procs1.txt"
expect 2 "arms: a GOMAXPROCS=1 arm has NO suffix, not the name's own -2" "end in -\[none\], PR benchmarks in -\[4\]" -- \
  bash "$ARMS" "$at/procs1.txt" "$at/procs4.txt"
expect 2 "arms: no names in common is not comparable" "share NO benchmark names" -- \
  bash "$ARMS" "$at/base.txt" "$at/other-names.txt"
expect 0 "arms: an unpaired benchmark is reported, not failed" "only in pr: +BenchmarkNewlyAdded-4" -- \
  bash "$ARMS" "$at/base.txt" "$at/extra.txt"
expect 2 "arms: an empty arm fails" "is empty" -- bash "$ARMS" "$at/empty.txt" "$at/pr.txt"
expect 2 "arms: headers and no results fails" "no benchmark RESULT lines" -- \
  bash "$ARMS" "$at/nobench.txt" "$at/pr.txt"
expect 2 "arms: a missing file fails" "no such file" -- bash "$ARMS" "$at/nope.txt" "$at/pr.txt"
expect 2 "arms: a build failure in a package with benchmarks fails, naming it" "package example.com/m/core has benchmarks but failed" -- \
  bash "$ARMS" "$at/twopkg-base.txt" "$at/broken-pr.txt"
expect 2 "arms: a setup failure in a package with benchmarks fails" "example.com/m/core" -- \
  bash "$ARMS" "$at/twopkg-base.txt" "$at/setup-pr.txt"
expect 2 "arms: a build failure read from the raw output fails" "example.com/m/core has benchmarks" -- \
  env BENCH_ARMS_BASE_RAW="$at/twopkg-base.txt" BENCH_ARMS_PR_RAW="$at/broken-pr.txt" \
  bash "$ARMS" "$at/twopkg-base.txt" "$at/pr.txt"
expect 0 "arms: a failed package with no benchmarks is only reported" "nothing is lost" -- \
  bash "$ARMS" "$at/base.txt" "$at/license-pr.txt"
expect 2 "arms: four arguments is a usage error" "usage" -- \
  bash "$ARMS" "$at/base.txt" "$at/pr.txt" "$at/base.txt" "$at/pr.txt"

# ===========================================================================
# run-arms.sh and filter.sh, with a fake go
# ===========================================================================
# new_ws -> a workspace with empty base/ and pr/ checkouts.
new_ws() {
  local ws
  ws="$(mktemp -d "$work/ws.XXXX")"
  mkdir -p "$ws/base" "$ws/pr"
  echo "$ws"
}
run_arms() { # <ws> [VAR=value...]; runs run-arms.sh with the fake go
  local ws="$1"
  shift
  env PATH="$fakes:$PATH" GITHUB_WORKSPACE="$ws" FAKE_GO_LOG="$ws/go.log" BENCH_COUNT=3 "$@" \
    bash "$run_dir/run-arms.sh"
}

ws="$(new_ws)"
mkdir -p "$ws/base/sub/mod" "$ws/pr/sub/mod"
touch "$ws/base/sub/mod/go.mod" "$ws/pr/sub/mod/go.mod"
expect 0 "run: directory runs go test in the module directory" "round 3/3" -- run_arms "$ws" BENCH_DIRECTORY=sub/mod FAKE_GO_RECORD=PWD
expect 0 "run: ... in both arms" "" -- bash -c 'grep -c "PWD=$1/base/sub/mod " "$1/go.log" | grep -qx 3 && grep -c "PWD=$1/pr/sub/mod " "$1/go.log" | grep -qx 3' _ "$ws"
ws="$(new_ws)"
expect 2 "run: a directory with no go.mod fails, naming the input" "no go.mod in base/nope. Set the directory input" -- run_arms "$ws" BENCH_DIRECTORY=nope
expect 2 "run: a directory with .. fails" "directory must be relative" -- run_arms "$ws" BENCH_DIRECTORY=../x

ws="$(new_ws)"
expect 0 "run: three interleaved rounds pass" "round 3/3" -- run_arms "$ws"
order="$(sed -n 's/^arm=\([a-z]*\).*/\1/p' "$ws/go.log" | paste -sd' ' -)"
if [ "$order" = "base pr base pr base pr" ]; then
  echo "ok   run: the arms alternate, base first, each round"
else
  echo "FAIL run: arm order is '$order', want 'base pr base pr base pr'"
  fails=$((fails + 1))
fi
expect 0 "run: each arm's output is in its raw file, once per round" "^3$" -- \
  grep -c '^BenchmarkA' "$ws/bench-pr-raw.txt"
expect 0 "run: go test gets GOMAXPROCS=1 and the default flags" \
  "GOMAXPROCS=1 args=test -bench=\. -benchmem -benchtime=100ms -count=1 -run=\^\\$ -timeout=15m \./\.\.\.$" -- \
  head -n 1 "$ws/go.log"
expect 0 "run: filter and samples check pass on good output" "all 2 benchmark" -- \
  env GITHUB_WORKSPACE="$ws" BENCH_COUNT=3 bash "$run_dir/filter.sh"
expect 0 "run: the run passes the arms check" "arms are comparable" -- \
  bash -c 'cd "$1" && BENCH_ARMS_BASE_RAW=bench-base-raw.txt BENCH_ARMS_PR_RAW=bench-pr-raw.txt bash "$2" bench-baseline.txt bench-current.txt' _ "$ws" "$ARMS"
expect 2 "run: the PR arm short of samples fails the filter step" "SHORT" -- \
  env GITHUB_WORKSPACE="$ws" BENCH_COUNT=4 bash "$run_dir/filter.sh"

ws="$(new_ws)"
expect 0 "run: skip, bench, benchtime, timeout, packages and gomaxprocs reach go test" "" -- \
  run_arms "$ws" BENCH_SKIP='Parallel$' BENCH_REGEX=Env BENCH_TIME=1x BENCH_TIMEOUT=2m \
  BENCH_PACKAGES='./a ./b/...' BENCH_GOMAXPROCS=4 BENCH_COUNT=1
expect 0 "run: ... and the go test command line is right" \
  "GOMAXPROCS=4 args=test -bench=Env -skip=Parallel\\$ -benchmem -benchtime=1x -count=1 -run=\^\\$ -timeout=2m \./a \./b/\.\.\.$" -- \
  head -n 1 "$ws/go.log"
expect 0 "run: a GOMAXPROCS of 4 gives -4 names" "^BenchmarkA-4" -- cat "$ws/bench-base-raw.txt"

# ${ARM_DIR} is replaced by text substitution, and nothing is evaluated.
ws="$(new_ws)"
marker="$work/pwned"
env_lines="SUBSTRATEHCP_FILE=\${ARM_DIR}/cmd/substratehcp/build/substratehcp-local
INJECT=\$(touch $marker)\`touch $marker\`\${HOME}&\${ARM_DIR}

PLAIN=a=b"
expect 0 "run: env lines are accepted" "" -- \
  run_arms "$ws" BENCH_COUNT=1 BENCH_ENV="$env_lines" FAKE_GO_RECORD="SUBSTRATEHCP_FILE INJECT PLAIN"
expect 0 "run: \${ARM_DIR} becomes each arm's absolute directory" \
  "^arm=base .* SUBSTRATEHCP_FILE=$ws/base/cmd/substratehcp/build/substratehcp-local " -- \
  head -n 1 "$ws/go.log"
expect 0 "run: ... in the PR arm too" "^arm=pr .* SUBSTRATEHCP_FILE=$ws/pr/cmd/substratehcp/build/substratehcp-local " -- \
  sed -n 2p "$ws/go.log"
expect 0 "run: \$(...), backquotes, \${HOME} and & stay literal" \
  "INJECT=\\\$\(touch $marker\)\`touch $marker\`\\\$\{HOME\}&$ws/base PLAIN=a=b " -- \
  head -n 1 "$ws/go.log"
if [ -e "$marker" ]; then
  echo "FAIL run: an env value was evaluated (the marker file exists)"
  fails=$((fails + 1))
else
  echo "ok   run: an env value is never evaluated"
fi
expect 2 "run: an env line that is not KEY=VALUE fails" "env line is not KEY=VALUE: 'not a pair'" -- \
  run_arms "$(new_ws)" BENCH_ENV="not a pair"
expect 2 "run: GOMAXPROCS in env is refused" "set GOMAXPROCS with the gomaxprocs input" -- \
  run_arms "$(new_ws)" BENCH_ENV="GOMAXPROCS=8"
expect 2 "run: a count that is not a positive integer fails" "count must be a positive integer" -- \
  run_arms "$(new_ws)" BENCH_COUNT=0
expect 2 "run: a gomaxprocs that is not a positive integer fails" "gomaxprocs must be a positive integer" -- \
  run_arms "$(new_ws)" BENCH_GOMAXPROCS=auto
expect 2 "run: a missing checkout fails" "no base/ checkout" -- \
  env GITHUB_WORKSPACE="$work" bash "$run_dir/run-arms.sh"

# prepare runs once in each arm, in its directory, with ARM_DIR set.
ws="$(new_ws)"
expect 0 "run: prepare runs in each arm" "" -- \
  run_arms "$ws" BENCH_COUNT=1 BENCH_PREPARE='echo "$PWD $ARM_DIR" >>"$ARM_DIR/../prepare.log"'
expect 0 "run: ... once, base then pr, with ARM_DIR set" "^$ws/base $ws/base,$ws/pr $ws/pr$" -- \
  bash -c 'paste -sd, "$1"' _ "$ws/prepare.log"
expect 1 "run: a failing prepare fails the job" "prepare failed in the base arm" -- \
  run_arms "$(new_ws)" BENCH_PREPARE='exit 3'

# Build failures: fatal by default; with allow-build-failures, accepted only
# when every failed package failed to build or set up.
expect 1 "run: a go test failure is fatal by default" "go test exited 1 in the base arm" -- \
  run_arms "$(new_ws)" FAKE_GO_MODE=setup-fail-nobench
ws="$(new_ws)"
expect 0 "run: allow-build-failures accepts a setup failure, with the warning" \
  "::warning::some packages did not build" -- \
  run_arms "$ws" FAKE_GO_MODE=setup-fail-nobench BENCH_ALLOW_BUILD_FAILURES=true
expect 0 "run: ... and lists the package in bench-build-failures.txt" "example.com/m/private \[setup failed\]" -- \
  cat "$ws/bench-build-failures.txt"
expect 1 "run: allow-build-failures does not accept a test failure" "go test exited 1 in the pr arm" -- \
  run_arms "$(new_ws)" FAKE_GO_MODE=test-fail FAKE_GO_ARM=pr BENCH_ALLOW_BUILD_FAILURES=true
expect 2 "run: allow-build-failures must be true or false" "allow-build-failures must be true or false" -- \
  run_arms "$(new_ws)" BENCH_ALLOW_BUILD_FAILURES=yes
# A package WITH benchmarks that does not build passes the run step with the
# flag on, and the arms check fails it.
ws="$(new_ws)"
expect 0 "run: a benchmarked package's build failure passes the run step with the flag" "" -- \
  run_arms "$ws" FAKE_GO_MODE=build-fail-bench FAKE_GO_ARM=pr BENCH_ALLOW_BUILD_FAILURES=true
env GITHUB_WORKSPACE="$ws" BENCH_COUNT=3 bash "$run_dir/filter.sh" >/dev/null 2>&1
expect 2 "run: ... and the arms check fails it, naming the package" "package example.com/m/a has benchmarks but failed" -- \
  bash -c 'cd "$1" && BENCH_ARMS_BASE_RAW=bench-base-raw.txt BENCH_ARMS_PR_RAW=bench-pr-raw.txt bash "$2" bench-baseline.txt bench-current.txt' _ "$ws" "$ARMS"

# filter.sh: an arm with no parseable result fails.
ws="$(new_ws)"
printf 'goos: linux\nFAIL\texample.com/m/a [build failed]\n' >"$ws/bench-base-raw.txt"
cp "$at/pr.txt" "$ws/bench-pr-raw.txt"
expect 2 "filter: a base arm with no results fails" "no parseable benchmark results for the base arm" -- \
  env GITHUB_WORKSPACE="$ws" BENCH_COUNT=6 bash "$run_dir/filter.sh"
# A short BASE arm only warns (the base predates any fix).
ws="$(new_ws)"
raw_fixture "$ws/bench-base-raw.txt" 1 4
raw_fixture "$ws/bench-pr-raw.txt" 5 0
expect 0 "filter: a short base arm only warns" "::warning::benchmark BenchmarkMockParallel-4" -- \
  env GITHUB_WORKSPACE="$ws" BENCH_COUNT=5 bash "$run_dir/filter.sh"

# ===========================================================================
# compare.sh, with fake benchstat and benchgate
# ===========================================================================
# compare_case <dir> [VAR=value...]: a workspace with two arms that pass the
# arms check, then compare.sh. Prints the output, then __EXIT__, then
# $GITHUB_OUTPUT, then the body read from the comment_file path it names
# (followed, not hardcoded: a path named but not written posts nothing).
compare_case() {
  local d="$1" rc cf
  shift
  mkdir -p "$d/pr/.github/quality"
  # A .no-results file stands for a run that stopped before its filter.
  if [ ! -e "$d/.no-results" ]; then
    [ -f "$d/bench-baseline.txt" ] || cp "$at/base.txt" "$d/bench-baseline.txt"
    [ -f "$d/bench-current.txt" ] || cp "$at/pr.txt" "$d/bench-current.txt"
    [ -f "$d/bench-base-raw.txt" ] || cp "$d/bench-baseline.txt" "$d/bench-base-raw.txt"
    [ -f "$d/bench-pr-raw.txt" ] || cp "$d/bench-current.txt" "$d/bench-pr-raw.txt"
  fi
  : >"$d/gh-output.txt"
  rc=0
  env PATH="$fakes:$PATH" GITHUB_WORKSPACE="$d" GITHUB_OUTPUT="$d/gh-output.txt" \
    BENCH_COUNT=6 WAIVERS_PATH=.github/quality/benchstat-waivers.txt FAKE_GATE_ARGS="$d/gate-args.txt" \
    "$@" bash "$gate_dir/compare.sh" || rc=$?
  echo "__EXIT__ $rc"
  echo "__GITHUB_OUTPUT__"
  cat "$d/gh-output.txt"
  cf="$(sed -n 's/^comment_file=//p' "$d/gh-output.txt" | tail -n 1)"
  echo "__COMMENT_BODY__"
  if [ -z "$cf" ]; then
    echo "__NO_COMMENT_FILE_OUTPUT__"
  elif [ ! -f "$cf" ]; then
    echo "__COMMENT_FILE_MISSING__"
  else
    cat "$cf"
  fi
}
cdir() { mktemp -d "$work/cmp.XXXX"; }
body_of() { sed -n '/^__COMMENT_BODY__$/,$p' "$1" | tail -n +2; }

for rc in 0 1 2 3 127; do
  d="$(cdir)"
  compare_case "$d" FAKE_GATE_RC="$rc" >"$d/run.txt" 2>&1
  expect 0 "compare: gate exit $rc -> exits 0, gate_status=$rc" "" -- \
    grep -qx "gate_status=$rc" "$d/run.txt"
  expect 0 "compare: gate exit $rc -> exits 0" "" -- grep -qx "__EXIT__ 0" "$d/run.txt"
  expect 0 "compare: gate exit $rc -> the body is in the comment file" "^## Benchmark comparison \(base vs PR\)$" -- \
    body_of "$d/run.txt"
  expect_not "compare: gate exit $rc -> the comment file exists" "__COMMENT_FILE_MISSING__|__NO_COMMENT_FILE_OUTPUT__" -- \
    cat "$d/run.txt"
done
d="$(cdir)"
compare_case "$d" FAKE_GATE_RC=1 >"$d/run.txt" 2>&1
expect 0 "compare: exit 1 warns of a regression" "::warning::Benchstat detected a significant benchmark regression" -- cat "$d/run.txt"
d="$(cdir)"
compare_case "$d" FAKE_GATE_RC=3 FAKE_GATE_LINES=unfit >"$d/run.txt" 2>&1
expect 0 "compare: exit 3 warns that the runner was unfit" "::warning::The runner was not fit to measure" -- cat "$d/run.txt"
expect 0 "compare: exit 3 puts the UNMEASURABLE rows above the fold" "### Rows the RUNNER could not measure" -- \
  bash -c 'sed -n "/^__COMMENT_BODY__$/,/<details>/p" "$1"' _ "$d/run.txt"
d="$(cdir)"
compare_case "$d" FAKE_GATE_RC=127 >"$d/run.txt" 2>&1
expect 0 "compare: an unknown exit warns that the gate did not complete" "exited 127 -- it did not run to completion" -- cat "$d/run.txt"

d="$(cdir)"
compare_case "$d" FAKE_GATE_LINES="waived noise" FAKE_STAT_RC=0 >"$d/run.txt" 2>&1
above="$(sed -n '/^__COMMENT_BODY__$/,/<details>/p' "$d/run.txt")"
expect 0 "compare: NOISE-FLOOR rows go above the fold" "### Rows this comparison could not resolve" -- echo "$above"
expect 0 "compare: waivers go above the fold" "  WAIVED      pkg B/op Encode-2" -- echo "$above"
expect 0 "compare: the waiver section names the configured path" 'Declared in `\.github/quality/benchstat-waivers\.txt`' -- echo "$above"
expect 0 "compare: the gate report reaches the body" "stub gate report" -- body_of "$d/run.txt"
expect 0 "compare: the benchstat table reaches the body" "stub benchstat table" -- body_of "$d/run.txt"
expect 0 "compare: count reaches the footer" "n=6 each\._$" -- body_of "$d/run.txt"
expect_not "compare: no flag is passed when no threshold is set" "-threshold|-alloc-threshold|-variance-ceiling|-alpha" -- \
  cat "$d/gate-args.txt"
expect 0 "compare: the waivers go to -waivers-default, from pr/" \
  "args=-waivers-default $d/pr/\.github/quality/benchstat-waivers\.txt benchstat-output\.txt$" -- cat "$d/gate-args.txt"
expect 0 "compare: a missing waiver file is a notice, not an error" "::notice::No waiver file at \.github/quality/benchstat-waivers\.txt" -- \
  cat "$d/run.txt"
expect_not "compare: no base line in the footer without base-sha" "_Base arm" -- body_of "$d/run.txt"

d="$(cdir)"
compare_case "$d" THRESHOLD=10 ALLOC_THRESHOLD=10 VARIANCE_CEILING=30 ALPHA=0.01 BENCH_GOMAXPROCS=4 \
  BASE_SHA=0123456789abcdef0123456789abcdef01234567 BASE_SOURCE=merge-parent >"$d/run.txt" 2>&1
expect 0 "compare: set thresholds are passed as flags" \
  "args=-threshold 10 -alloc-threshold 10 -variance-ceiling 30 -alpha 0.01 -waivers-default " -- cat "$d/gate-args.txt"
expect 0 "compare: BENCH_GOMAXPROCS reaches benchgate" "^BENCH_GOMAXPROCS=4 " -- cat "$d/gate-args.txt"
expect 0 "compare: the base commit is in the footer" "_Base arm: \`0123456789abcdef0123456789abcdef01234567\`, the base this PR merges into\._" -- \
  body_of "$d/run.txt"
d="$(cdir)"
compare_case "$d" WAIVERS_PATH= >"$d/run.txt" 2>&1
expect 0 "compare: an empty waivers input passes an empty -waivers-default" "args=-waivers-default  benchstat-output\.txt$" -- \
  cat "$d/gate-args.txt"
expect 0 "compare: BENCH_GOMAXPROCS defaults to 0 (strip any suffix)" "^BENCH_GOMAXPROCS=0 " -- cat "$d/gate-args.txt"

# The could-not-run branches: each reports gate_status=2, names its cause in
# the log and in the body, and still writes the body.
d="$(cdir)"
compare_case "$d" BENCHGATE="$work/no-such-benchgate" >"$d/run.txt" 2>&1
expect 0 "compare: a missing tool reports gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
expect 0 "compare: a missing tool is named, not reported as a regression" "## Benchmark gate could not run" -- body_of "$d/run.txt"
expect 0 "compare: ... and the tool is in the body" "no-such-benchgate" -- body_of "$d/run.txt"
for bad in /etc/passwd ../x a/../../b; do
  d="$(cdir)"
  compare_case "$d" WAIVERS_PATH="$bad" >"$d/run.txt" 2>&1
  expect 0 "compare: waivers path '$bad' is refused with gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
  expect 0 "compare: ... and the reason is in the body" "must be relative to the repository root" -- body_of "$d/run.txt"
done
d="$(cdir)"
: >"$d/bench-baseline.txt"
compare_case "$d" >"$d/run.txt" 2>&1
expect 0 "compare: an empty base arm reports gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
expect 0 "compare: ... and says so in the log" "::error::bench-baseline.txt is empty" -- cat "$d/run.txt"
expect 0 "compare: ... and in the body" "## Benchmark results \(base arm FAILED" -- body_of "$d/run.txt"
d="$(cdir)"
touch "$d/.no-results"
compare_case "$d" >"$d/run.txt" 2>&1
expect 0 "compare: a run that wrote no results reports gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
expect 0 "compare: ... and calls it a failed run" "## Benchmark run failed -- no comparison" -- body_of "$d/run.txt"
expect_not "compare: ... and does not blame the base arm" "base arm FAILED" -- body_of "$d/run.txt"
d="$(cdir)"
awk '/^BenchmarkEnvGet/ && !done { done = 1; next } { print }' "$at/pr.txt" >"$d/bench-current.txt"
compare_case "$d" >"$d/run.txt" 2>&1
expect 0 "compare: a PR arm short of samples reports gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
expect 0 "compare: ... and names the benchmark in the body" "SHORT +BenchmarkEnvGet" -- body_of "$d/run.txt"
d="$(cdir)"
cp "$at/procs2.txt" "$d/bench-baseline.txt"
compare_case "$d" >"$d/run.txt" 2>&1
expect 0 "compare: incomparable arms report gate_status=2" "" -- grep -qx "gate_status=2" "$d/run.txt"
expect 0 "compare: ... named by the pre-flight" "::error::The two benchmark arms are not comparable" -- cat "$d/run.txt"
expect 0 "compare: ... with the cause in the body" "## Benchmark arms are NOT comparable" -- body_of "$d/run.txt"
expect 0 "compare: ... and the arms report in the body" "GOMAXPROCS suffix" -- body_of "$d/run.txt"
d="$(cdir)"
compare_case "$d" FAKE_STAT_RC=1 >"$d/run.txt" 2>&1
expect 0 "compare: a benchstat failure is a warning; the gate still judges" "::warning::benchstat exited 1" -- cat "$d/run.txt"
# The size property of elps PR #658: the body never travels in GITHUB_OUTPUT.
d="$(cdir)"
compare_case "$d" FAKE_STAT_ROWS=620 FAKE_GATE_ROWS=620 FAKE_GATE_LINES=waived >"$d/run.txt" 2>&1
out_len="$(wc -c <"$d/gh-output.txt")"
if [ "$out_len" -le 2048 ]; then
  echo "ok   compare: a long report leaves GITHUB_OUTPUT at ${out_len} bytes"
else
  echo "FAIL compare: GITHUB_OUTPUT is ${out_len} bytes; the body is in a step output again"
  fails=$((fails + 1))
fi
cp "$d/bench-comment.md" "$work/big-body.md"
d="$(cdir)"
compare_case "$d" FAKE_GATE_LINES=waived >"$d/run.txt" 2>&1
cp "$d/bench-comment.md" "$work/small-body.md"

# ===========================================================================
# gate-fail.sh
# ===========================================================================
GF="$gate_dir/gate-fail.sh"
expect 1 "gate-fail: exit 1 is a measured regression" "::error::Benchmark regressions detected \(gate exit 1\)" -- env GATE_STATUS=1 bash "$GF"
expect 1 "gate-fail: exit 2 is uninterpretable" "::error::The benchmark comparison could not be interpreted \(gate exit 2\)" -- env GATE_STATUS=2 bash "$GF"
expect 1 "gate-fail: exit 3 is an unfit runner" "::error::The RUNNER was not fit to measure \(gate exit 3\)" -- env GATE_STATUS=3 bash "$GF"
expect_not "gate-fail: exit 3 does not claim a regression" "regressions detected|did not run to completion" -- env GATE_STATUS=3 bash "$GF"
expect 1 "gate-fail: exit 127 is no verdict" "did not run to completion \(exit 127\)" -- env GATE_STATUS=127 bash "$GF"
expect_not "gate-fail: exit 127 does not claim a regression" "regressions detected" -- env GATE_STATUS=127 bash "$GF"
expect 1 "gate-fail: an empty status prints <unset>" "exit <unset>" -- env GATE_STATUS= bash "$GF"
expect 1 "gate-fail: an unset status prints <unset>, no unbound-variable crash" "exit <unset>" -- env -u GATE_STATUS bash "$GF"

# ===========================================================================
# comment.cjs: truncation and the sticky comment
# ===========================================================================
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL comment: node is not installed, so comment.cjs is not tested"
  fails=$((fails + 1))
else
  expect 0 "comment: the bodies and the cases pass" "" -- \
    node "$root/tests/benchmark/comment-test.cjs" "$work/big-body.md" "$work/small-body.md"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "all cases passed"
