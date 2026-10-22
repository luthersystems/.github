#!/usr/bin/env bash
# Runs the govulncheck gate on each Go module of a repo.
#
# Why one script for every module: some repos hold more than one go.mod
# (substrate's bin-adapter, test fixtures), and a scan of only the root module
# misses the others. Each module is scanned in its own directory, so its own
# go and toolchain lines pick the Go whose stdlib is checked (GOTOOLCHAIN=auto):
# the stdlib of the Go we ship, not of the runner's Go.
#
# Why binary mode is optional: binary mode finds code reached by reflection,
# which source mode cannot see, but it has to build every main package first.
# That doubles the cost, so the workflow runs it on the scheduled scan only.
# A build failure there fails the scan: a package that did not build was not
# scanned, and an unscanned package is not a clean one.
#
# Env:
#   DIRS        module directories, space separated; empty = every go.mod
#   EXEMPTIONS  exemptions file, relative to the repo root
#   BINARY      true: also scan built main packages
#   REPORT      file that collects the log for the drift issue
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(pwd)"
REPORT="${REPORT:-${RUNNER_TEMP:-/tmp}/govulncheck.txt}"
EXEMPTIONS="${EXEMPTIONS:-}"
if [ -n "$EXEMPTIONS" ]; then
  EXEMPTIONS="$root/$EXEMPTIONS"
  [ -f "$EXEMPTIONS" ] || echo "govulncheck: no exemptions file at ${EXEMPTIONS#"$root"/}; no finding is exempt"
fi
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

dirs="${DIRS:-}"
if [ -z "$dirs" ]; then
  dirs="$("$here/../security-detect/find-go-modules.sh")"
fi
if [ -z "$dirs" ]; then
  echo "govulncheck: no go.mod found; nothing to scan"
  exit 0
fi

failed=0
for d in $dirs; do
  echo "::group::govulncheck (source) $d"
  status=0
  python3 "$here/govulncheck-gate.py" --exemptions "$EXEMPTIONS" "$d" ./... 2>&1 | tee -a "$REPORT" || status=$?
  echo "::endgroup::"
  [ "$status" -eq 0 ] || failed=1

  [ "${BINARY:-false}" = "true" ] || continue

  if ! mains="$(cd "$d" && go list -f '{{if eq .Name "main"}}{{.ImportPath}}{{end}}' ./...)"; then
    echo "::error title=govulncheck binary mode: build failure, not a finding::go list ./... failed in $d, so nothing there was built or scanned" | tee -a "$REPORT"
    failed=1
    continue
  fi
  bindir="$(mktemp -d)"
  for pkg in $mains; do
    out="$bindir/$(echo "$pkg" | tr '/' '_')"
    echo "::group::govulncheck (binary) $pkg"
    if ! (cd "$d" && go build -o "$out" "$pkg"); then
      echo "::endgroup::"
      echo "::error title=govulncheck binary mode: build failure, not a finding::go build $pkg failed, so it was not scanned" | tee -a "$REPORT"
      failed=1
      continue
    fi
    status=0
    python3 "$here/govulncheck-gate.py" --exemptions "$EXEMPTIONS" "$d" -mode=binary "$out" 2>&1 | tee -a "$REPORT" || status=$?
    echo "::endgroup::"
    [ "$status" -eq 0 ] || failed=1
  done
  rm -rf "$bindir"
done
exit "$failed"
