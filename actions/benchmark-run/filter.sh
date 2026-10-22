#!/usr/bin/env bash
# Keeps only the well-formed result rows of each arm and checks each
# benchmark's sample count. Ported from the "Filter and validate benchmark
# output" step of substrate's substrate-benchmark.yml.
#
# Why filter: benchstat reads every line that starts with "Benchmark" as a
# result row. A benchmark that logs while it is timed puts that text into its
# row, and benchstat reports "parsing iteration count: invalid syntax". Keep a
# name with an integer iteration count, plus the headers benchstat groups by.
# Each dropped row is a lost sample, so samples-check.sh counts what is left.
#
# Environment: GITHUB_WORKSPACE (the files are there), BENCH_COUNT (the
# samples each benchmark needs).
#
# Reads bench-base-raw.txt and bench-pr-raw.txt; writes bench-baseline.txt
# and bench-current.txt. Exit 0, or 2 when an arm has no results or the PR
# arm has too few samples.
set -euo pipefail

work="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
samples="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/samples-check.sh"
cd "$work"

keep() {
  grep -E '^(goos|goarch|pkg|cpu):|^Benchmark[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]' "$1" >"$2" || true
}
keep bench-base-raw.txt bench-baseline.txt
keep bench-pr-raw.txt bench-current.txt

check_arm() { # <label> <raw> <filtered> <warn-only>
  if ! grep -q '^Benchmark' "$3"; then
    echo "::error::no parseable benchmark results for the $1 arm -- it produced nothing usable."
    tail -n 50 "$2"
    return 2
  fi
  echo "== $1 arm =="
  BENCH_MIN_SAMPLES="${BENCH_COUNT:-10}" BENCH_SAMPLES_WARN_ONLY="$4" bash "$samples" "$3" "$2"
}

# The PR arm is the GATE; the base arm only warns. That is what makes the
# gate usable at all:
#   * The base is a commit already on the base branch, which passed this same
#     PR-arm check when it merged. So a change that loses samples fails on the
#     PR arm first, and is blocked there.
#   * A PR can never fix the base arm, because the base comes before the fix.
#     A hard failure on the base arm would block every PR that fixes a noisy
#     benchmark.
# A short base benchmark is still named by a warning, and arms-check.sh
# reports it as unpaired when it lost every row.
rc=0
check_arm base bench-base-raw.txt bench-baseline.txt 1 || rc=$?
check_arm pr bench-pr-raw.txt bench-current.txt 0 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "::error::the benchmark output cannot be compared: an arm has no results, or a PR-arm benchmark has fewer than ${BENCH_COUNT:-10} usable samples, which would understate its uncertainty. See the report above."
  exit "$rc"
fi
