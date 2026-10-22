#!/usr/bin/env bash
# Asserts that EVERY benchmark gave the configured number of samples, and
# names the ones that did not. Ported from substrate's
# scripts/bench-samples-check.sh.
#
# Why: go test writes a benchmark's name, runs it, then writes the numbers on
# the same line, and it merges the test binary's stderr into that output. A
# log line written while a benchmark runs lands in the middle of its result
# row:
#
#   BenchmarkMockParallel-4   	2026-08-10T20:45:40.034Z [DEBUG] plugin: sta...
#
# benchstat cannot parse that row, so filter.sh drops it. Each dropped row is
# a lost sample, and the drop is silent: in substrate one benchmark was
# compared at n=1 despite -count=5, and another lost every row and was not
# compared at all. Both looked like a clean result. This check names them.
#
# Names come from the RAW file, so a benchmark that lost every row shows with
# count 0 instead of being missing from this report too.
#
# Usage: samples-check.sh <filtered-file> [<raw-file>]
#   env BENCH_MIN_SAMPLES        samples each benchmark needs (default 6,
#                                benchstat's floor for a confidence interval)
#   env BENCH_SAMPLES_WARN_ONLY  1: report, do not fail
#
# Exit 0 when each benchmark has enough samples; 2 when one has not, or the
# input cannot be used. 2, not 1: it is benchgate's "cannot interpret" code.
# This script does not judge performance.
set -uo pipefail

MIN="${BENCH_MIN_SAMPLES:-6}"
WARN_ONLY="${BENCH_SAMPLES_WARN_ONLY:-0}"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <filtered-file> [<raw-file>]" >&2
  exit 2
fi
filtered="$1"
raw="${2:-$1}"

case "$MIN" in
  '' | *[!0-9]*)
    echo "samples-check: BENCH_MIN_SAMPLES must be an integer, got '${MIN}'" >&2
    exit 2
    ;;
esac

for f in "$filtered" "$raw"; do
  if [ ! -f "$f" ]; then
    echo "samples-check: no such file: $f" >&2
    exit 2
  fi
  if [ ! -s "$f" ]; then
    echo "samples-check: $f is empty -- no benchmark output to check." >&2
    exit 2
  fi
done

# A good result row is a name and then an integer iteration count: the shape
# filter.sh keeps and benchstat reads. The two passes are told apart by
# NR == FNR, not by file name, as both arguments can name the same file.
report=$(
  awk -v min="$MIN" '
    NR == FNR && /^Benchmark/ {
      seen[$1] = 1
      if (!($2 ~ /^[0-9]+$/)) mangled[$1]++
      next
    }
    NR != FNR && /^Benchmark/ && $2 ~ /^[0-9]+$/ { ok[$1]++ }
    END {
      total = 0; short = 0
      for (n in seen) {
        total++
        c = ok[n] + 0
        if (c < min) {
          short++
          printf "  SHORT  %-64s samples=%d want>=%d mangled_rows=%d\n", n, c, min, mangled[n] + 0
        }
      }
      printf "VERDICT %d %d\n", short, total
    }
  ' "$raw" "$filtered"
)

verdict_line=$(printf '%s\n' "$report" | tail -n 1)
printf '%s\n' "$report" | sed '$d'
read -r _ n_short n_total <<<"$verdict_line"

if [ "${n_total:-0}" -eq 0 ]; then
  echo "samples-check: no benchmark rows in ${raw} -- the benchmarks did not run, or did not build." >&2
  exit 2
fi
if [ "$n_short" -eq 0 ]; then
  echo "samples-check: all ${n_total} benchmark(s) have >= ${MIN} samples in ${filtered}."
  exit 0
fi

# One annotation for each benchmark, so the checks page names it.
printf '%s\n' "$report" | sed '$d' | while read -r _ name rest; do
  echo "::warning::benchmark ${name} gave too few samples (${rest}); its comparison is not statistically meaningful."
done

cat >&2 <<EOF

samples-check: ${n_short} of ${n_total} benchmark(s) gave fewer than ${MIN}
usable samples in ${filtered}.

The usual cause: the benchmark, or code it calls, writes to stdout or stderr
while it is timed. go test puts that text into the result row, benchstat
cannot parse the row, and the filter drops it, so the sample is lost.

Fix the benchmark, not this check: stop the logging while the benchmark runs.
EOF

if [ "$WARN_ONLY" = "1" ]; then
  echo "samples-check: BENCH_SAMPLES_WARN_ONLY=1 -- report only." >&2
  exit 0
fi
exit 2
