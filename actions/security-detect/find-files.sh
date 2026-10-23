#!/usr/bin/env bash
# Prints iac=true|false and code=true|false: whether git tracks a file the
# Trivy job or the Semgrep job would scan. Only tracked files count, and
# vendor/, node_modules/ and testdata/ do not (the scanners skip them too).
# SKIP_DIRS (Trivy skip-dirs) and EXCLUDE (Semgrep excludes), one per line,
# leave out more, so a repo whose only infrastructure or code sits in a
# directory its scanner skips does not pay to install a scanner that would
# scan nothing.
#
# Why the Kubernetes and CloudFormation tests read the file: such a file is
# a .yaml or .json like any other, and only its content (apiVersion and
# kind, or AWSTemplateFormatVersion, or an ARM $schema) tells it apart from,
# say, a workflow file. .github/ is left out, since nothing there is one.
#
# Why the Dockerfile test is on the whole file name: it is Trivy's own test
# (pkg/iac/detection): Dockerfile or Containerfile with at most one
# extension, case-sensitive, or any name ending in .dockerfile or
# .containerfile in any case. A name that only holds the word, such as
# dockerfile-lint.sh, is not one, and must not start a Trivy build.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
files="$(git ls-files | grep -vE '(^|/)(vendor|node_modules|testdata)/' || true)"

iac=false code=false
iacfiles="$(python3 -B "$here/keep.py" iac <<<"$files")"
if grep -qE '(\.tf|\.tf\.json|(^|/)(Dockerfile|Containerfile)(\.[^./]*)?|(^|/)Chart\.yaml)$' <<<"$iacfiles" ||
   grep -qiE '\.(dockerfile|containerfile)$' <<<"$iacfiles"; then
  iac=true
else
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC2016 # the $ in $schema is a literal ARM key
    if { grep -qE '^apiVersion:' "$f" && grep -qE '^kind:' "$f"; } ||
       grep -qE '^[[:space:]{"]*AWSTemplateFormatVersion"?[[:space:]]*:' "$f" ||
       grep -qE '"\$schema"[[:space:]]*:[[:space:]]*"https?://schema\.management\.azure\.com/schemas/[^"]*[dD]eploymentTemplate\.json' "$f"; then
      iac=true
      break
    fi
  done < <(grep -E '\.(ya?ml|json)$' <<<"$iacfiles" | grep -v '^\.github/' || true)
fi
# Into a variable first: piped into grep -q, keep.py could be cut off
# mid-write, and pipefail would then read a match as no match.
codefiles="$(python3 -B "$here/keep.py" code <<<"$files")"
if grep -qE '\.(py|js|jsx|mjs|cjs|ts|tsx)$' <<<"$codefiles"; then
  code=true
fi
echo "iac=$iac"
echo "code=$code"
