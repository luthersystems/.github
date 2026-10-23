#!/usr/bin/env bash
# Scans the repo's Python, JavaScript and TypeScript with Semgrep CE and the
# pinned rules, and gates the report with semgrep-gate.py. Why Semgrep and
# the fail rule: see action.yml and semgrep-gate.py.
#
# Env: RULES (checkout of semgrep/semgrep-rules), LANGS (rule directories,
# space separated), EXEMPTIONS (file, relative to the repo root), EXCLUDE
# (globs to leave out, one per line). semgrep must be on PATH.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
out="$tmp/semgrep.json"
rules="$(cd "${RULES:?}" && pwd)"

# A bare `nosemgrep` hides every rule on its line, so a later rule that
# would catch a real bug there is hidden too. Name the rule. Semgrep also
# reads the short `nosem`, and `nosem:` or `nosemgrep:` with no id, so those
# count as bare too.
# Only a comment counts (`#`, `//` or `/*` before it, as Semgrep needs), so
# prose that names the syntax, such as a docstring, does not fail the gate.
bare="$(git grep -nE '(#|//|/\*).*(^|[^[:alnum:]_])nosem(grep)?([^[:alnum:]_-]|$)' -- '*.py' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.ts' '*.tsx' 2>/dev/null |
  grep -vE 'nosem(grep)?[[:space:]]*:[[:space:]]*[[:alnum:]_]' || true)"
if [ -n "$bare" ]; then
  while IFS= read -r hit; do
    f="${hit%%:*}" rest="${hit#*:}" n="${rest%%:*}"
    echo "::error file=$f,line=$n,title=nosemgrep without a rule id::write nosemgrep: <rule-id> and why"
  done <<<"$bare"
fi

# --metrics=off: send nothing to semgrep.dev. The rules checkout must sit
# outside the repo (action.yml moves it to RUNNER_TEMP): Semgrep scans
# untracked files too, and the rules' own test files are full of findings.
args=(scan --metrics=off --disable-version-check --quiet --severity ERROR --json --output "$out")
for l in ${LANGS:-python javascript typescript}; do
  args+=(--config "$rules/$l")
done
# Fixtures and third-party code are not ours to fix; the Trivy job and the
# workflow's detection leave the same directories out.
for ex in testdata vendor node_modules; do
  args+=(--exclude "$ex")
done
while IFS= read -r ex; do
  [ -n "$ex" ] && args+=(--exclude "$ex")
done <<<"${EXCLUDE:-}"

status=0
semgrep "${args[@]}" . 2>"$tmp/semgrep.log" || status=$?
# 0 = clean, 1 = findings (with --error only); anything else = the scan failed.
if [ "$status" -gt 1 ] || [ ! -s "$out" ]; then
  cat "$tmp/semgrep.log"
  echo "::error title=semgrep failed::semgrep exited $status, so nothing was scanned"
  exit 1
fi
# Semgrep names a rule loaded from a directory by its path, dots for
# slashes: relative to the working directory when the rules are under it,
# else absolute, with leading dots dropped. Strip the checkout's part so ids
# read as in the registry and match an exemption row.
case "$rules" in
  "$PWD"/*) p="${rules#"$PWD"/}" ;;
  *) p="${rules#/}" ;;
esac
prefix="$(printf '%s' "$p" | tr '/' '.' | sed 's/^\.*//')."
status=0
python3 "$here/semgrep-gate.py" --exemptions "${EXEMPTIONS:-}" --rule-prefix "$prefix" "$out" || status=$?
[ -z "$bare" ] || status=1
exit "$status"
