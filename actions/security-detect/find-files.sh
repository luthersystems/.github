#!/usr/bin/env bash
# Prints iac=true|false and code=true|false: whether git tracks a file the
# Trivy job or the Semgrep job would scan. Only tracked files count, and
# vendor/, node_modules/ and testdata/ do not (the scanners skip them too).
#
# Why the Kubernetes test reads the file: a Kubernetes manifest is a .yaml
# like any other, and only its apiVersion and kind lines tell it apart from,
# say, a workflow file. .github/ is left out, since nothing there is one.
set -euo pipefail

files="$(git ls-files | grep -vE '(^|/)(vendor|node_modules|testdata)/' || true)"
iac=false code=false
if grep -qiE '(\.tf|\.tf\.json|(^|/)[^/]*dockerfile[^/]*|(^|/)containerfile[^/]*|(^|/)chart\.yaml)$' <<<"$files"; then
  iac=true
else
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -qE '^apiVersion:' "$f" && grep -qE '^kind:' "$f"; then
      iac=true
      break
    fi
  done < <(grep -E '\.ya?ml$' <<<"$files" | grep -v '^\.github/' || true)
fi
if grep -qE '\.(py|js|jsx|mjs|cjs|ts|tsx)$' <<<"$files"; then
  code=true
fi
echo "iac=$iac"
echo "code=$code"
