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

# Leave out the same directories as the scan, so the grep below judges only
# files Trivy reads.
skips=('**/node_modules' '**/.terraform' '**/vendor' '**/testdata')
while IFS= read -r d; do
  [ -n "$d" ] && skips+=("$d")
done <<<"${SKIP_DIRS:-}"
excl=()
for d in "${skips[@]}"; do
  excl+=(":(exclude,glob)${d%/}/**")
done

# An inline `trivy:ignore:<id>` comment hides a finding from the report, so
# the gate never sees it. Trivy accepts an expiry on it (`:exp:YYYY-MM-DD`);
# the fail rule says every exemption has one, so a comment without it fails.
# Trivy also honours tfsec's older `tfsec:ignore:<id>`. Only a comment counts
# (`#` or `//` before it), and only in the file types Trivy reads inline
# ignores from, so prose that names the syntax does not fail the gate.
noexp="$(git grep -nE '(#|//)[[:space:]]*(trivy|tfsec):ignore:' -- \
  '*.tf' '*.tf.json' '*.tfvars' '*.hcl' '*.yaml' '*.yml' '*.json' \
  '*Dockerfile*' '*dockerfile*' '*Containerfile*' "${excl[@]}" 2>/dev/null |
  grep -v ':exp:' || true)"
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
# Why --ignorefile and --config point at empty files: Trivy reads
# `.trivyignore`, `.trivyignore.yaml` and `trivy.yaml` from the working
# directory by default, so a repo could drop a finding, or change the
# severity or skip list, with no expiry, issue or reason. Every exemption
# goes through the exemptions file instead.
: >"$tmp/empty.trivyignore"
: >"$tmp/empty.trivy.yaml"
for f in .trivyignore .trivyignore.yaml trivy.yaml; do
  [ -e "$f" ] && echo "::warning file=$f,title=Trivy setting not used::the gate ignores $f; put exemptions in ${EXEMPTIONS:-the exemptions file}"
done
args=(config --quiet --skip-check-update --skip-version-check
  --ignorefile "$tmp/empty.trivyignore" --config "$tmp/empty.trivy.yaml"
  --tf-exclude-downloaded-modules --severity 'HIGH,CRITICAL'
  --format json --output "$out")
for d in "${skips[@]}"; do
  args+=(--skip-dirs "$d")
done

if ! trivy "${args[@]}" . 2>"$tmp/trivy.log"; then
  cat "$tmp/trivy.log"
  echo "::error title=trivy failed::trivy config did not finish, so nothing was scanned"
  exit 1
fi
status=0
python3 "$here/trivy-gate.py" --exemptions "${EXEMPTIONS:-}" "$out" || status=$?
[ -z "$noexp" ] || status=1
exit "$status"
