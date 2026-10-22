#!/usr/bin/env bash
# Runs gosec, through golangci-lint, on each Go module. Why through
# golangci-lint: see action.yml.
#
# Env: DIRS (space separated; empty = every go.mod), REPORT (log for the
# drift issue). golangci-lint must be on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
report="${REPORT:-${RUNNER_TEMP:-/tmp}/gosec.txt}"
dirs="${DIRS:-$("$here/../security-detect/find-go-modules.sh")}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
failed=0
for d in $dirs; do
  echo "::group::gosec $d"
  status=0
  (cd "$d" && golangci-lint run --enable-only gosec --max-issues-per-linter 0 --max-same-issues 0 ./...) 2>&1 | tee -a "$report" || status=$?
  echo "::endgroup::"
  if [ "$status" -ne 0 ]; then
    echo "::error title=gosec::gosec found issues (or could not type-check the code) in $d"
    failed=1
  fi
done
exit "$failed"
