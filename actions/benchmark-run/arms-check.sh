#!/usr/bin/env bash
# Checks that the two arms' `go test -bench` outputs are COMPARABLE before
# benchstat compares them. Ported from substrate's scripts/bench-arms-check.sh,
# with elps's GOMAXPROCS-suffix rule (elps#767) merged in.
#
# Why: benchstat pairs rows by the FULL benchmark name, and it keys its
# "configuration" on the goos:, goarch: and cpu: headers. When these differ
# between the arms, benchstat gives no clear error: it prints a table with no
# compared rows. benchgate then exits 2 ("could not be interpreted"), which is
# true but names the symptom, not the cause. Both causes below happened in
# elps and substrate:
#
#   * cpu or goarch mismatch. The old design took the baseline from a cache:
#     another machine, another day. Two runs of the SAME code drew an EPYC
#     7763 and an EPYC 9V74 and paired nothing. Measuring both arms in one job
#     prevents it; this check names it if it comes back.
#   * GOMAXPROCS suffix mismatch. go test adds -N, where N is GOMAXPROCS, to
#     each benchmark name. Two arms measured at different core counts give
#     EnvGet-4 and EnvGet-2, which are different names, so nothing pairs, from
#     a table that looks normal. A change to runs-on, in another place, can
#     cause it. The run action pins GOMAXPROCS; this check names it if the pin
#     goes.
#
# It also fails when a package that has benchmarks in either arm fails to
# build or set up ([build failed], [setup failed]) in either arm: its
# benchmarks are then not compared while the rest still pair. A failed package
# with no benchmarks is only reported. A benchmark in one arm only (a PR added
# or removed it) is only reported.
#
# Usage: arms-check.sh <base-output> <pr-output>
#   env BENCH_ARMS_BASE_RAW, BENCH_ARMS_PR_RAW  the unfiltered outputs. The
#       FAIL lines that name a broken package are read from them too, as the
#       filtered files hold no FAIL lines.
#
# Exit 0 when the arms are comparable; 2 when they are not or the input is not
# usable. 2, not 1: it is benchgate's "cannot interpret" code. There is no
# exit 1: this script checks comparability, not performance.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <base-output> <pr-output>" >&2
  exit 2
fi
base="$1"
pr="$2"
base_raw="${BENCH_ARMS_BASE_RAW:-$1}"
pr_raw="${BENCH_ARMS_PR_RAW:-$2}"

problems=0
note() { echo "  $*"; }
problem() {
  problems=$((problems + 1))
  echo "  MISMATCH  $*" >&2
}

for f in "$base" "$pr" "$base_raw" "$pr_raw"; do
  if [ ! -f "$f" ]; then
    echo "arms-check: no such file: $f" >&2
    exit 2
  fi
  if [ ! -s "$f" ]; then
    echo "arms-check: $f is empty -- that arm produced no output at all." >&2
    exit 2
  fi
done

# The values of a `key: value` header in a file. go test ./... prints the
# headers again for each package, so this is a set. More than one value in ONE
# arm means that arm was measured on mixed machines, which is as bad as a
# mismatch between the arms.
headers() {
  awk -v k="$1" '
    substr($0, 1, length(k) + 1) == k ":" {
      v = substr($0, length(k) + 2)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (v != "") print v
    }
  ' "$2" | sort -u
}

# A result row is a name and then an integer iteration count; that count is
# what tells it from "--- FAIL", "ok", "PASS" and a -bench listing.
bench_names() {
  awk '$1 ~ /^Benchmark/ && $2 ~ /^[0-9]+$/ { print $1 }' "$1"
}

# procs_suffix NAMES: the -N that EVERY name ends with, or nothing. go test
# adds the same -N to all names, and nothing at GOMAXPROCS=1. A trailing
# number that only some names have is part of those names (elps's
# Package/get-nested-baseline-2), so it is not a suffix (elps#767).
procs_suffix() {
  sed -n 's/.*-\([0-9][0-9]*\)$/\1/p' "$1" | sort -u >"$1.suf"
  if [ "$(wc -l <"$1.suf" | tr -d ' ')" -eq 1 ] &&
    [ "$(grep -c . "$1")" -eq "$(grep -c -- "-$(cat "$1.suf")\$" "$1")" ]; then
    cat "$1.suf"
  fi
}

# strip_suffix NAMES SUFFIX: removes exactly -SUFFIX; nothing when it is empty.
strip_suffix() {
  if [ -n "$2" ]; then
    sed "s/-$2\$//" "$1"
  else
    cat "$1"
  fi
}

for key in goos goarch; do
  b="$(headers "$key" "$base" | paste -sd, -)"
  p="$(headers "$key" "$pr" | paste -sd, -)"
  if [ -z "$b" ] || [ -z "$p" ]; then
    note "no ${key}: header in one or both arms (base=${b:-<none>} pr=${p:-<none>}) -- skipping that comparison"
    continue
  fi
  if [ "$b" != "$p" ]; then
    problem "${key}: base=[${b}] pr=[${p}] -- the arms were measured on different platforms."
  else
    note "${key}: ${b} (both arms)"
  fi
done

# The CPU model. go test prints no cpu: header on linux/arm64 (Go reads the
# model from CPUID on x86 only), so on ARM this check cannot run, and the
# one-job design is what prevents the failure. It says "skipping", not
# "match": a check that did not run must not look like one that passed.
bcpu="$(headers cpu "$base" | paste -sd' | ' -)"
pcpu="$(headers cpu "$pr" | paste -sd' | ' -)"
if [ -n "$bcpu" ] && [ -n "$pcpu" ]; then
  if [ "$bcpu" != "$pcpu" ]; then
    problem "cpu: base=[${bcpu}] pr=[${pcpu}] -- benchstat keys its configuration on this header, so the arms will not pair. Measure both arms in ONE job on ONE runner."
  else
    note "cpu: ${bcpu} (both arms)"
  fi
else
  note "cpu: header absent from one or both arms -- skipping"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bench_names "$base" | sort -u >"$tmp/base.names"
bench_names "$pr" | sort -u >"$tmp/pr.names"
nbase="$(wc -l <"$tmp/base.names" | tr -d ' ')"
npr="$(wc -l <"$tmp/pr.names" | tr -d ' ')"

if [ "$nbase" -eq 0 ] || [ "$npr" -eq 0 ]; then
  echo "arms-check: no benchmark RESULT lines in $([ "$nbase" -eq 0 ] && echo base) $([ "$npr" -eq 0 ] && echo pr) -- the benchmarks did not run, or did not build." >&2
  exit 2
fi

comm -12 "$tmp/base.names" "$tmp/pr.names" >"$tmp/paired"
comm -23 "$tmp/base.names" "$tmp/pr.names" >"$tmp/base.only"
comm -13 "$tmp/base.names" "$tmp/pr.names" >"$tmp/pr.only"
npaired="$(wc -l <"$tmp/paired" | tr -d ' ')"

if [ "$npaired" -eq 0 ]; then
  # No pairs. First test whether only the GOMAXPROCS suffix differs: that
  # gives a one-line cause with a clear fix, not "nothing in common".
  bsuf="$(procs_suffix "$tmp/base.names")"
  psuf="$(procs_suffix "$tmp/pr.names")"
  strip_suffix "$tmp/base.names" "$bsuf" | sort -u >"$tmp/base.stripped"
  strip_suffix "$tmp/pr.names" "$psuf" | sort -u >"$tmp/pr.stripped"
  if [ -n "$(comm -12 "$tmp/base.stripped" "$tmp/pr.stripped")" ]; then
    problem "GOMAXPROCS suffix: base benchmarks end in -[${bsuf:-none}], PR benchmarks in -[${psuf:-none}]. \`go test\` appends GOMAXPROCS to every benchmark name, so these are DIFFERENT names and benchstat pairs none of them -- from a table that looks normal. The arms ran with different GOMAXPROCS (usually: different runner sizes). Pin GOMAXPROCS (the gomaxprocs input) so the suffix cannot move."
  else
    problem "benchmark names: the arms share NO benchmark names at all (base has ${nbase}, PR has ${npr}) and the difference is not just the GOMAXPROCS suffix. Nothing can be compared."
  fi
else
  note "paired benchmarks: ${npaired} (base ${nbase}, pr ${npr})"
fi

# Packages go test could not build or set up (the FAIL lines of either arm),
# and packages with benchmark results in either arm. A package in both lost
# its benchmarks from one arm.
failed_pkgs() {
  awk '/\[(build|setup) failed\]/ && $1 == "FAIL" { print $2 }' "$@"
}
bench_pkgs() {
  awk '
    /^pkg:/ { p = $2; next }
    $1 ~ /^Benchmark/ && $2 ~ /^[0-9]+$/ && p != "" { print p }
  ' "$@"
}
failed_pkgs "$base" "$pr" "$base_raw" "$pr_raw" | sort -u >"$tmp/failed.pkgs"
bench_pkgs "$base" "$pr" | sort -u >"$tmp/bench.pkgs"
comm -12 "$tmp/failed.pkgs" "$tmp/bench.pkgs" >"$tmp/lost.pkgs"
while IFS= read -r pkg; do
  problem "package ${pkg} has benchmarks but failed to build or set up in one arm, so its benchmarks are missing from the comparison. Fix the build."
done <"$tmp/lost.pkgs"
if [ -s "$tmp/failed.pkgs" ] && [ ! -s "$tmp/lost.pkgs" ]; then
  note "packages that failed to build or set up (no benchmarks in either arm, so nothing is lost):"
  sed 's/^/    /' "$tmp/failed.pkgs"
fi

# An unpaired benchmark is allowed (a PR can add or remove one), so it is
# reported, never failed. It is printed because a benchmark that silently
# leaves the comparison is no longer gated: a deleted benchmarked package once
# made a gate go quiet instead of red.
if [ -s "$tmp/base.only" ] || [ -s "$tmp/pr.only" ]; then
  note "unpaired (not compared; expected when a PR adds or removes a benchmark):"
  sed 's/^/    only in base: /' "$tmp/base.only"
  sed 's/^/    only in pr:   /' "$tmp/pr.only"
fi

# Sample counts, reported only: samples-check.sh is the check that fails, and
# it names WHICH benchmark is short.
if [ "$npaired" -gt 0 ]; then
  bmin="$(bench_names "$base" | sort | uniq -c | awk 'NR==1||$1<m{m=$1} END{print m+0}')"
  pmin="$(bench_names "$pr" | sort | uniq -c | awk 'NR==1||$1<m{m=$1} END{print m+0}')"
  note "min samples per benchmark: base=${bmin} pr=${pmin}"
  if [ "$bmin" -lt 6 ] || [ "$pmin" -lt 6 ]; then
    note "WARNING: benchstat cannot compute a confidence interval below 6 samples; rows will read 'need >= 6 samples'."
  fi
fi

if [ "$problems" -gt 0 ]; then
  echo "arms-check: ${problems} mismatch(es) -- the arms are NOT comparable; refusing to let a meaningless comparison be adjudicated." >&2
  exit 2
fi
echo "arms-check: arms are comparable."
