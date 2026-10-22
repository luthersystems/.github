#!/usr/bin/env bash
# Runs golangci-lint with the repo's own .golangci.yml on each Go module, and
# reports how far each repo config has drifted from the shared baseline.
#
# Why the repo's own config: golangci-lint v2 cannot import a shared config,
# and each repo has exclusions it has reviewed. golangci-lint finds the
# config from the module directory upward, so a module with no file of its
# own uses the repo root's.
#
# Why it collects failures (set -u, not -e): one module that fails must not
# hide the result of the next, so every module runs and the script exits 1
# at the end if any failed.
#
# Env:
#   DIRS             module directories, space separated; empty = every go.mod
#   BASELINE_REPORT  "true" writes the drift report (never fails the job)
#   BASELINE         baseline config; empty = quality/golangci-baseline.yml
#                    of this repo
# golangci-lint must be on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dirs="${DIRS:-$("$here/../security-detect/find-go-modules.sh")}"
baseline="${BASELINE:-$here/../../quality/golangci-baseline.yml}"
report="${BASELINE_REPORT:-true}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -z "$dirs" ]; then
  echo "::notice title=golangci-lint::no Go module to lint"
  exit 0
fi

# -c needs a path that still holds after the cd into each module.
case "$baseline" in /*) ;; *) baseline="$PWD/$baseline" ;; esac
if [ "$report" = "true" ] && [ ! -r "$baseline" ]; then
  echo "::warning title=golangci-lint baseline::cannot read the baseline $baseline; no drift report"
  report=false
fi
if [ "$report" = "true" ]; then
  {
    echo "### golangci-lint: drift from the shared baseline"
    echo
    echo "A report only; it does not fail the job. The baseline is quality/golangci-baseline.yml in luthersystems/.github."
    echo
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

failed=0
for d in $dirs; do
  echo "::group::golangci-lint $d"
  status=0
  (cd "$d" && golangci-lint run --max-issues-per-linter 0 --max-same-issues 0 ./...) 2>&1 || status=$?
  echo "::endgroup::"
  if [ "$status" -ne 0 ]; then
    echo "::error title=golangci-lint::golangci-lint found issues (or could not type-check the code) in $d"
    failed=1
  fi

  [ "$report" = "true" ] || continue
  # The drift report must never change the job's result: each step that can
  # fail turns into a warning, and the loop goes on.
  key="$(printf '%s' "$d" | tr '/' '_')"
  if ! (cd "$d" && golangci-lint linters --color never) >"$work/$key.repo" 2>&1 ||
    ! (cd "$d" && golangci-lint linters --color never -c "$baseline") >"$work/$key.base" 2>&1; then
    echo "::warning title=golangci-lint baseline::golangci-lint linters failed in $d; no drift report for it"
    continue
  fi
  bash "$here/baseline-drift.sh" "$work/$key.repo" "$work/$key.base" "$d" ||
    echo "::warning title=golangci-lint baseline::cannot compare the linters of $d with the baseline"
done
exit "$failed"
