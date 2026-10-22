#!/usr/bin/env bash
# The backquotes in single quotes below are Markdown code spans, not commands.
# shellcheck disable=SC2016
# Compares the two benchmark arms: checks they are comparable, runs benchstat,
# gives the table to benchgate, and writes the PR comment body. Ported from
# elps scripts/bench-compare.sh and the "Compare with benchstat" step of
# substrate's substrate-benchmark.yml.
#
# This script decides nothing. The verdict is benchgate's; gate-fail.sh turns
# it into a red build. So every branch exits 0 and writes gate_status to
# $GITHUB_OUTPUT: 0 clean, 1 regression, 2 cannot interpret, 3 runner unfit,
# any other value no verdict.
#
# Why the comment body is a FILE and only its path is a step output: it used
# to be a step output, which the comment step got through `env:`. An env
# variable is part of the child process's argv/envp block, which the kernel
# limits (128 KiB for one string on Linux). On elps PR #658 the report was
# about 1,300 lines and the step died before its script ran ("Argument list
# too long"), although the gate had PASSED. A path is a few dozen bytes.
# GitHub's 65,536-character limit on a comment body is a different limit;
# comment.cjs handles it.
#
# Environment:
#   GITHUB_WORKSPACE   holds pr/ and the files benchmark-run wrote
#   GITHUB_OUTPUT      gate_status and comment_file are written here
#   WAIVERS_PATH       waiver list, relative to pr/; empty means none
#   THRESHOLD, ALLOC_THRESHOLD, VARIANCE_CEILING, ALPHA
#                      benchgate flags; each is passed only when set
#   BENCH_COUNT        samples per arm, for the comment footer
#   BENCH_GOMAXPROCS   the GOMAXPROCS the arms ran at (benchmark-run sets it)
#   BASE_SHA, BASE_SOURCE  optional: the base commit and how it was chosen
#                      (merge-parent or fallback), for the footer
#   BENCHGATE, BENCHSTAT, ARMS_CHECK  the tools; defaults are benchgate and
#                      benchstat on PATH and benchmark-run's arms-check.sh
#
# Writes arms-check.txt, benchstat-output.txt, gate-report.txt and the body,
# bench-comment.md, in $GITHUB_WORKSPACE.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
cd "$work"

GATE="${BENCHGATE:-benchgate}"
STAT="${BENCHSTAT:-benchstat}"
ARMS="${ARMS_CHECK:-${here}/../benchmark-run/arms-check.sh}"
waivers_rel="${WAIVERS_PATH-}"
count="${BENCH_COUNT:-?}"
# benchgate reads the suffix from this. Unset (0) means "strip any trailing
# -<digits>", benchgate's behaviour before elps#767.
export BENCH_GOMAXPROCS="${BENCH_GOMAXPROCS:-${GOMAXPROCS:-0}}"

# Every branch must write the body here AND name it on $GITHUB_OUTPUT, or the
# comment step reads an empty path and posts nothing, silently. One function
# does both, so the two cannot drift apart.
COMMENT_FILE="${work}/bench-comment.md"
emit() { # <gate_status>; the body is already in $COMMENT_FILE
  echo "gate_status=$1" >>"$out"
  echo "comment_file=${COMMENT_FILE}" >>"$out"
}

could_not_run() { # <reason> <detail>
  echo "::error::$1"
  {
    echo '## Benchmark gate could not run'
    echo ''
    echo "$1"
    echo ''
    echo '```'
    echo "$2"
    echo '```'
  } >"$COMMENT_FILE"
  emit 2
  exit 0
}

missing=""
for tool in "$GATE" "$STAT"; do
  command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
[ -f "$ARMS" ] || missing="${missing} ${ARMS}"
[ -z "$missing" ] || could_not_run "The benchmark gate tools were not found." "${missing# }"

# The waiver list must be inside the PR checkout: a PR that changes the gate's
# waivers is judged by its own list, and a path out of pr/ is a mistake.
waivers=""
if [ -n "$waivers_rel" ]; then
  case "/${waivers_rel}/" in
    //* | */../*) could_not_run "The waivers path must be relative to the repository root, with no '..'." "$waivers_rel" ;;
  esac
  waivers="${work}/pr/${waivers_rel}"
  # benchgate's -waivers-default treats a missing file as "no waivers", which
  # can only make the gate stricter. Say so, so a typo is seen.
  [ -f "$waivers" ] || echo "::notice::No waiver file at ${waivers_rel}; the gate runs with no waivers."
fi

# Both arms come from benchmark-run in this job. An empty base arm is not a
# cache miss: the base checkout or its run failed, and a report of the PR
# numbers only would hide that.
if [ ! -s bench-baseline.txt ]; then
  echo "::error::bench-baseline.txt is empty or missing -- the base arm did not produce results."
  {
    echo '## Benchmark results (base arm FAILED -- no comparison)'
    echo ''
    echo 'The base checkout or its benchmark run produced nothing.'
    echo 'These are the PR-side numbers only; they are NOT a comparison.'
    echo ''
    echo '```'
    cat bench-current.txt 2>/dev/null || echo '(no PR-arm output either)'
    echo '```'
  } >"$COMMENT_FILE"
  emit 2
  exit 0
fi

# Comparability before comparison (see arms-check.sh). benchmark-run already
# ran it and failed the job; it runs again here so the comment names the
# cause when the caller runs this action after a failed measurement.
arms_rc=0
BENCH_ARMS_BASE_RAW="${BENCH_ARMS_BASE_RAW:-bench-base-raw.txt}" \
  BENCH_ARMS_PR_RAW="${BENCH_ARMS_PR_RAW:-bench-pr-raw.txt}" \
  bash "$ARMS" bench-baseline.txt bench-current.txt >arms-check.txt 2>&1 || arms_rc=$?
cat arms-check.txt
if [ "$arms_rc" -ne 0 ]; then
  echo "::error::The two benchmark arms are not comparable; see the pre-flight report above."
  {
    echo '## Benchmark arms are NOT comparable -- no comparison was made'
    echo ''
    echo '```'
    cat arms-check.txt
    echo '```'
  } >"$COMMENT_FILE"
  emit 2
  exit 0
fi

# benchstat's exit status is kept, not dropped with `|| true`: when it
# crashes, its error text is all that reaches benchstat-output.txt, and
# benchgate turns that into exit 2. A dropped status made a crash look like a
# clean comparison.
bench_rc=0
"$STAT" base=bench-baseline.txt pr=bench-current.txt >benchstat-output.txt 2>&1 || bench_rc=$?
[ "$bench_rc" -eq 0 ] || echo "::warning::benchstat exited ${bench_rc}; the gate will adjudicate its output."

gate_args=()
[ -z "${THRESHOLD:-}" ] || gate_args+=(-threshold "$THRESHOLD")
[ -z "${ALLOC_THRESHOLD:-}" ] || gate_args+=(-alloc-threshold "$ALLOC_THRESHOLD")
[ -z "${VARIANCE_CEILING:-}" ] || gate_args+=(-variance-ceiling "$VARIANCE_CEILING")
[ -z "${ALPHA:-}" ] || gate_args+=(-alpha "$ALPHA")
# -waivers-default, not -waivers: an explicit BENCH_WAIVERS in the job's env
# still wins (substrate's baseline workflow uses that), and an empty
# BENCH_WAIVERS turns waivers off, which can only make the gate stricter.
gate_args+=(-waivers-default "$waivers")

# Run before the body is written, so the comment carries the verdict and not
# only the table. That matters most for a WAIVED row: an accepted regression
# seen only in the job log is one nobody reviews. Redirected, not piped to
# tee: exit 1 is the gate's normal "regression", and it must not stop this
# script before the comment is written.
gate_status=0
"$GATE" "${gate_args[@]}" benchstat-output.txt >gate-report.txt 2>&1 || gate_status=$?
cat gate-report.txt
case "$gate_status" in
  0) echo "No benchmark regression at or above the configured gates." ;;
  1) echo "::warning::Benchstat detected a significant benchmark regression." ;;
  2) echo "::warning::The benchmark comparison could not be interpreted." ;;
  3) echo "::warning::The runner was not fit to measure; one or more rows are UNMEASURABLE and this run certified nothing about them." ;;
  *) echo "::warning::${GATE} exited ${gate_status} -- it did not run to completion." ;;
esac

# These lines go ABOVE the fold, outside the collapsed sections, so everyone
# who reads the PR reads them. `|| true`: grep exits 1 when nothing matches,
# which is the normal case.
#   UNMEASURABLE (elps#542): the RUNNER, not the code, is the finding. A row
#     past the gate on an interval too wide to size the move certified
#     nothing; in a collapsed block "we could not measure it" reads as "fine".
#   NOISE-FLOOR: a row whose own spread is larger than its move cannot be
#     judged by this comparison. It is fixed only by someone who sees it.
#   Waivers: a standing exception must be read by everyone, not only by
#     whoever opens a details block.
unfit_lines="$(grep -E '^  UNMEASURABLE' gate-report.txt || true)"
noise_lines="$(grep -E '^  NOISE-FLOOR' gate-report.txt || true)"
waiver_lines="$(grep -E '^  (WAIVED|WAIVER-|waiver-)' gate-report.txt || true)"

# The order is the contract comment.cjs truncates against: what must survive
# a long body (the heading and the three sections above) comes BEFORE the
# first <details>; what is in a <details> can be cut.
{
  echo '## Benchmark comparison (base vs PR)'
  echo ''
  if [ -n "$unfit_lines" ]; then
    echo '### Rows the RUNNER could not measure'
    echo ''
    echo 'These rows moved at or above the gate, but on a confidence interval at or'
    echo 'above the fitness ceiling -- an arm that dispersed carries no information'
    echo 'about the size of the move. They are NOT regressions and NOT passes: this'
    echo 'run certified nothing about them, and the gate exits 3 (RUNNER-UNFIT)'
    echo 'rather than reporting either. Re-run the job; see the fitness-check note'
    echo 'in the `cmd/benchgate` package doc (luthersystems/elps).'
    echo ''
    echo '```'
    echo "$unfit_lines"
    echo '```'
    echo ''
  fi
  if [ -n "$noise_lines" ]; then
    echo '### Rows this comparison could not resolve'
    echo ''
    echo 'These timing rows moved past the gate by LESS than their own measured'
    echo 'spread, so this comparison cannot tell the move from noise. They are'
    echo 'NOT counted as regressions and they are NOT suppressed -- they are'
    echo 'unmeasurable as sampled. A row that keeps appearing here needs a longer'
    echo '`-benchtime`, or to be kept out of the comparison set; see the'
    echo 'resolution-check note in the `cmd/benchgate` package doc.'
    echo ''
    echo '```'
    echo "$noise_lines"
    echo '```'
    echo ''
  fi
  if [ -n "$waiver_lines" ]; then
    echo '### Reviewed waivers'
    echo ''
    echo "Declared in \`${waivers_rel}\`. A \`WAIVED\` row was measured,"
    echo 'DID move, and was accepted within the ceiling recorded there -- it is not'
    echo 'suppressed. `waiver-unused` means that row is no longer regressing and the'
    echo 'entry can be deleted; `WAIVER-STALE` means it protects nothing at all.'
    echo ''
    echo '```'
    echo "$waiver_lines"
    echo '```'
    echo ''
  fi
  echo '<details>'
  echo '<summary>Click to expand benchstat output</summary>'
  echo ''
  echo '```'
  cat benchstat-output.txt
  echo '```'
  echo ''
  echo '</details>'
  echo ''
  echo '<details>'
  echo '<summary>Click to expand the gate report</summary>'
  echo ''
  echo '```'
  cat gate-report.txt
  echo '```'
  echo ''
  echo '</details>'
  echo ''
  echo "_Both arms measured on the same runner in the same job, interleaved, n=${count} each._"
  if [ -n "${BASE_SHA:-}" ]; then
    case "${BASE_SOURCE:-}" in
      merge-parent) echo "_Base arm: \`${BASE_SHA}\`, the base this PR merges into._" ;;
      fallback) echo "_Base arm: \`${BASE_SHA}\`, pull_request.base.sha (no merge commit; can be older than the base this PR merges into)._" ;;
      *) echo "_Base arm: \`${BASE_SHA}\`._" ;;
    esac
  fi
} >"$COMMENT_FILE"
emit "$gate_status"
