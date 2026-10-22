#!/usr/bin/env bash
# Turns the benchmark gate's verdict into a red build, and says WHICH verdict
# it was. Ported from elps scripts/bench-gate-fail.sh.
#
# The action runs this only when the gate did not pass, so it always exits 1.
# The four messages differ because the reader's next step differs:
#   1  regressions found    -- a real, measured performance problem
#   2  could not interpret  -- a hard failure by design: a gate that cannot
#                              read its input must never report success
#   3  runner unfit         -- the machine gave no usable measurement
#                              (elps#542). Nothing was found and nothing was
#                              certified: re-run. Telling the reader to read
#                              the diff would send them after a problem that
#                              is not there.
#   *  no verdict           -- for example exit 127 (a tool not found), or an
#                              earlier step failed. This used to say
#                              "regressions detected", which sent readers
#                              after a performance problem that did not exist.
#
# Environment: GATE_STATUS, the compare step's gate_status (can be empty or
# unset; both print as <unset>).
set -euo pipefail

status="${GATE_STATUS-}"
case "$status" in
  1)
    echo "::error::Benchmark regressions detected (gate exit 1). Review the benchstat comparison in the PR comment and the gate report in the job log."
    ;;
  2)
    echo "::error::The benchmark comparison could not be interpreted (gate exit 2). This is a hard failure by design -- a gate that cannot read its input must never report success. See the job log above."
    ;;
  3)
    echo "::error::The RUNNER was not fit to measure (gate exit 3). One or more rows moved past the gate on a confidence interval too wide to size the move, so this run found no regression AND certified nothing -- see the UNMEASURABLE line(s) in the gate report. Re-run the job; if it recurs on a fresh runner, the benchmark itself needs a longer -benchtime or to leave the comparison set."
    ;;
  *)
    echo "::error::The benchmark gate did not run to completion (exit ${status:-<unset>}); it reached no verdict, so this is neither a pass nor a measured regression. See the job log above for the failing step."
    ;;
esac
exit 1
