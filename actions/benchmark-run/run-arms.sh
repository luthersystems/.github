#!/usr/bin/env bash
# Measures both benchmark arms, base/ and pr/, on this runner, in this job,
# interleaved. Ported from elps scripts/bench-run-arms.sh and the "Run
# benchmarks" step of substrate's substrate-benchmark.yml.
#
# Why interleaved: each round runs the base arm, then the PR arm. A runner
# that slows down part way (thermal throttling, a noisy neighbour) then slows
# both arms. A run of all of one arm, then all of the other, puts that drift
# into the second arm only, and the gate reads it as a change in the code.
# Each round gives one sample per arm, so BENCH_COUNT rounds give BENCH_COUNT
# samples each.
#
# Why pipefail: the status of `go test | tee` is the status of tee, which is 0
# even when the benchmarks do not compile or panic. Without pipefail the step
# is green, the files hold error text, and the comparison means nothing.
#
# Environment (the action sets each one from its input of the same meaning):
#   GITHUB_WORKSPACE      holds the two checkouts, base/ and pr/; the output
#                         files are written here
#   BENCH_PACKAGES        packages, space separated (./...)
#   BENCH_REGEX           -bench regexp (.)
#   BENCH_SKIP            -skip regexp; empty means no -skip
#   BENCH_TIME            -benchtime (100ms)
#   BENCH_COUNT           interleaved rounds (10)
#   BENCH_TIMEOUT         -timeout of each go test (15m)
#   BENCH_GOMAXPROCS      GOMAXPROCS for each go test (1)
#   BENCH_ENV             KEY=VALUE lines set for each go test; ${ARM_DIR} in a
#                         value becomes the arm's absolute directory
#   BENCH_PREPARE         shell command run once in each arm before measuring
#   BENCH_ALLOW_BUILD_FAILURES  "true": a package that does not build is a
#                         warning, not a failure (the arms check still fails
#                         when that package has benchmarks)
#
# Writes bench-base-raw.txt and bench-pr-raw.txt, and bench-build-failures.txt
# when a package did not build. Exit 0, or 2 on bad input, or the status of
# the command that failed.
set -euo pipefail

work="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
count="${BENCH_COUNT:-10}"
procs="${BENCH_GOMAXPROCS:-1}"
allow="${BENCH_ALLOW_BUILD_FAILURES:-false}"

die() {
  echo "::error::benchmark-run: $*" >&2
  exit 2
}

case "$count" in '' | *[!0-9]* | 0) die "count must be a positive integer, got '${count}'" ;; esac
case "$procs" in '' | *[!0-9]* | 0) die "gomaxprocs must be a positive integer, got '${procs}'" ;; esac
case "$allow" in true | false) ;; *) die "allow-build-failures must be true or false, got '${allow}'" ;; esac
for arm in base pr; do
  [ -d "$work/$arm" ] || die "no $arm/ checkout in $work. The workflow must check out the base commit at base/ and the PR merge commit at pr/."
done

read -r -a packages <<<"${BENCH_PACKAGES:-./...}"
[ "${#packages[@]}" -gt 0 ] || die "packages is empty"

# Parse the env lines once, so a bad line fails before anything is measured.
# A value is plain text: ${ARM_DIR} is replaced by string substitution, never
# by eval, so a value that holds $(...) or backquotes stays literal.
env_keys=()
env_vals=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "env line is not KEY=VALUE: '${line}'"
  key="${line%%=*}"
  # GOMAXPROCS is the gomaxprocs input: benchgate must know the -N suffix
  # that go test adds to each name, and it reads it from that input only.
  [ "$key" != GOMAXPROCS ] || die "set GOMAXPROCS with the gomaxprocs input, not in env"
  env_keys+=("$key")
  env_vals+=("${line#*=}")
done <<<"${BENCH_ENV:-}"

# arm_env DIR: prints nothing; fills arm_pairs with KEY=VALUE for that arm.
arm_env() {
  local dir="$1" i
  arm_pairs=("GOMAXPROCS=${procs}")
  for i in "${!env_keys[@]}"; do
    # The replacement is quoted: with bash 5.2's patsub_replacement an
    # unquoted & in it would stand for the matched text.
    arm_pairs+=("${env_keys[$i]}=${env_vals[$i]//"\${ARM_DIR}"/"$dir"}")
  done
}

if [ -n "${BENCH_PREPARE:-}" ]; then
  for arm in base pr; do
    echo "::group::prepare ${arm}"
    if ! (cd "$work/$arm" && ARM_DIR="$work/$arm" bash -c "$BENCH_PREPARE"); then
      echo "::endgroup::"
      echo "::error::benchmark-run: prepare failed in the ${arm} arm: ${BENCH_PREPARE}" >&2
      exit 1
    fi
    echo "::endgroup::"
  done
fi

args=(test "-bench=${BENCH_REGEX:-.}")
[ -z "${BENCH_SKIP:-}" ] || args+=("-skip=${BENCH_SKIP}")
args+=(-benchmem "-benchtime=${BENCH_TIME:-100ms}" -count=1 '-run=^$' "-timeout=${BENCH_TIMEOUT:-15m}")
args+=("${packages[@]}")

# A go test that fails is fatal, except, with allow-build-failures, when
# every failed package failed to build or set up. substrate needs that: some
# packages import a private module that the runner cannot always fetch, and
# none of them has benchmarks. A test failure or a panic is still fatal.
only_build_failures() {
  local failed bad
  failed="$(grep -E '^FAIL[[:space:]]+[^[:space:]]+' "$1" || true)"
  [ -n "$failed" ] || return 1
  bad="$(grep -vE '\[(build|setup) failed\]' <<<"$failed" || true)"
  [ -z "$bad" ]
}

round_out="$work/bench-round.txt"
: >"$work/bench-base-raw.txt"
: >"$work/bench-pr-raw.txt"
for round in $(seq 1 "$count"); do
  echo "::group::round ${round}/${count}"
  for arm in base pr; do
    arm_env "$work/$arm"
    rc=0
    (cd "$work/$arm" && env "${arm_pairs[@]}" go "${args[@]}") | tee "$round_out" || rc=$?
    cat "$round_out" >>"$work/bench-${arm}-raw.txt"
    if [ "$rc" -ne 0 ]; then
      if [ "$allow" = true ] && only_build_failures "$round_out"; then
        echo "benchmark-run: go test exited ${rc} in the ${arm} arm; only build failures, which allow-build-failures accepts."
      else
        echo "::endgroup::"
        echo "::error::benchmark-run: go test exited ${rc} in the ${arm} arm, round ${round}. See the output above." >&2
        rm -f "$round_out"
        exit "$rc"
      fi
    fi
  done
  echo "::endgroup::"
done
rm -f "$round_out"

grep -hE '\[(setup|build) failed\]' "$work/bench-base-raw.txt" "$work/bench-pr-raw.txt" |
  sort -u >"$work/bench-build-failures.txt" || true
if [ -s "$work/bench-build-failures.txt" ]; then
  echo "::warning::some packages did not build during the benchmark run and contributed no benchmarks; the list follows. The arms check fails if one of them has benchmarks."
  cat "$work/bench-build-failures.txt"
else
  rm -f "$work/bench-build-failures.txt"
fi
