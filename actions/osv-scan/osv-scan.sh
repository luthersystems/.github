#!/usr/bin/env bash
# Runs osv-scanner over every lockfile under the current directory and gates
# the report with osv-gate.py. Why osv-scanner, and the fail rule: see
# action.yml and osv-gate.py.
#
# Env: SKIP_GO (true: leave Go to govulncheck), EXCLUDE (one per line).
# osv-scanner must be on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
out="$tmp/osv.json"
args=(scan source -r --format json --allow-no-lockfiles --output-file "$out")
gate=()
# osv-scanner reads osv-scanner.toml only next to each lockfile; pass the
# root one so its exemptions cover nested lockfiles too.
if [ -f osv-scanner.toml ]; then
  args+=(--config osv-scanner.toml)
  gate+=(--config osv-scanner.toml)
fi
if [ "${SKIP_GO:-true}" = "true" ]; then
  # Skip the call analysis too: it builds the Go code to no purpose.
  args+=(--no-call-analysis=go)
  gate+=(--skip-ecosystem Go)
fi
while IFS= read -r ex; do
  [ -n "$ex" ] && args+=(--experimental-exclude "$ex")
done <<<"${EXCLUDE:-}"

# Warnings only: a manifest with no lockfile is not scanned at all.
lock_args=()
while IFS= read -r ex; do
  [ -n "$ex" ] && lock_args+=(--exclude "$ex")
done <<<"${EXCLUDE:-}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  python3 "$here/lockfile-check.py" "${lock_args[@]}" || true
fi

status=0
osv-scanner "${args[@]}" . >"$tmp/osv-scanner.log" 2>&1 || status=$?
# 0 = no vulnerability, 1 = some found. Anything else means the scan did not
# finish, which must not read as clean.
if [ "$status" -gt 1 ]; then
  cat "$tmp/osv-scanner.log"
  echo "::error title=osv-scanner failed::osv-scanner exited $status, so nothing was scanned"
  exit 1
fi
python3 "$here/osv-gate.py" "${gate[@]}" "$out"
