#!/usr/bin/env bash
# Scans the repo's infrastructure files (Terraform, Dockerfiles, Kubernetes,
# Helm, CloudFormation) with `trivy config` and gates the report with
# trivy-gate.py. Why Trivy and the fail rule: see action.yml and
# trivy-gate.py.
#
# Env: EXEMPTIONS (file, relative to the repo root), SKIP_DIRS (one per line).
# trivy must be on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
out="$tmp/trivy-config.json"

# An inline `trivy:ignore:<id>` comment hides a finding from the report, so
# the gate never sees it. Trivy accepts an expiry on it (`:exp:YYYY-MM-DD`);
# the fail rule says every exemption has one, so a comment without it fails.
noexp="$(git grep -nE 'trivy:ignore:' -- . 2>/dev/null | grep -v ':exp:' || true)"
if [ -n "$noexp" ]; then
  while IFS= read -r hit; do
    f="${hit%%:*}" rest="${hit#*:}" n="${rest%%:*}"
    echo "::error file=$f,line=$n,title=Inline Trivy ignore without an expiry::add :exp:YYYY-MM-DD, or move it to the exemptions file with an issue and a reason"
  done <<<"$noexp"
fi

# Why --skip-check-update: the checks built into this pinned Trivy are used,
# so a check published upstream cannot fail a merge with no change in the
# repo; a new Trivy version brings new checks, reviewed once.
# Why --tf-exclude-downloaded-modules: a remote module's findings belong to
# its own repo. Trivy still fetches public modules to evaluate their
# outputs; the job has no credentials, so a private module is not fetched
# and is only logged.
args=(config --quiet --skip-check-update --skip-version-check
  --tf-exclude-downloaded-modules --severity 'HIGH,CRITICAL'
  --skip-dirs '**/node_modules' --skip-dirs '**/.terraform' --skip-dirs '**/vendor' --skip-dirs '**/testdata'
  --format json --output "$out")
while IFS= read -r d; do
  [ -n "$d" ] && args+=(--skip-dirs "$d")
done <<<"${SKIP_DIRS:-}"

if ! trivy "${args[@]}" . 2>"$tmp/trivy.log"; then
  cat "$tmp/trivy.log"
  echo "::error title=trivy failed::trivy config did not finish, so nothing was scanned"
  exit 1
fi
status=0
python3 "$here/trivy-gate.py" --exemptions "${EXEMPTIONS:-}" "$out" || status=$?
[ -z "$noexp" ] || status=1
exit "$status"
