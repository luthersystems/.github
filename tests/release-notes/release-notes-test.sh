#!/usr/bin/env bash
# Tests actions/release-notes/release-notes.sh.
#
# Builds one small git repository with each kind of commit that reaches main
# (a PR merge commit, a squash merge, a direct push, a merged side branch),
# then checks the notes line by line, so a script that prints something for
# every commit but gets the form wrong does not pass.
#
# Needs on PATH: bash, git. Run from anywhere:
#   bash tests/release-notes/release-notes-test.sh
# pass only echoes, so "A && pass || fail" is an if-then-else here.
# shellcheck disable=SC2015
set -uo pipefail

NOTES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/actions/release-notes/release-notes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# want NAME FILE LINE: FILE holds LINE as a whole line.
want() { grep -qxF -- "$3" "$2" && pass "$1" || { fail "$1: missing line: $3"; sed 's/^/  | /' "$2" >&2; }; }
# nowant NAME FILE TEXT: FILE does not hold TEXT anywhere.
nowant() { grep -qF -- "$3" "$2" && { fail "$1: unexpected: $3"; sed 's/^/  | /' "$2" >&2; } || pass "$1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
R="$TMP/repo"
git init -q -b main "$R"
cd "$R" || exit 1
c() { git commit -q --allow-empty -m "$1" ${2:+-m "$2"}; }

c "Before the last release"
git tag v1.0.0
# A PR merged with a merge commit; the side branch has two commits.
git checkout -q -b feature
c "Side commit one"
c "Side commit two"
git checkout -q main
git merge -q --no-ff feature -m "Merge pull request #10 from luthersystems/feature" -m "  Add the feature  "
# A squash merge.
c "Fix the thing (#11)"
# A direct push with no PR, whose subject mentions a PR mid-line.
c "Bump the pin, see #12 for why"
# A local merge that is not a PR merge.
git checkout -q -b local
c "Local side"
git checkout -q main
git merge -q --no-ff local -m "Merge branch 'local'"
# A PR merge commit with an empty body falls back to its subject.
git checkout -q -b empty
c "Empty side"
git checkout -q main
git merge -q --no-ff empty -m "Merge pull request #13 from luthersystems/empty"

out="$TMP/out.md"
if LAST_TAG=v1.0.0 TAG=v1.1.0 GITHUB_REPOSITORY=luthersystems/example bash "$NOTES" >"$out" 2>"$TMP/err"; then
  pass "runs"
else
  fail "runs: $(cat "$TMP/err")"
fi
want "heading" "$out" "## What's Changed"
want "merge commit: PR title, trimmed" "$out" "- Add the feature (#10)"
want "squash: subject as it is" "$out" "- Fix the thing (#11)"
sha=$(git rev-parse --short=7 "HEAD~2")
want "direct push: subject and short SHA" "$out" "- Bump the pin, see #12 for why ($sha)"
lsha=$(git rev-parse --short=7 "HEAD~1")
want "local merge: subject and short SHA" "$out" "- Merge branch 'local' ($lsha)"
want "PR merge with no body: subject" "$out" "- Merge pull request #13 from luthersystems/empty (#13)"
nowant "side branch commits are not listed" "$out" "Side commit"
nowant "commits before the last tag are not listed" "$out" "Before the last release"
want "compare link" "$out" "**Full Changelog**: https://github.com/luthersystems/example/compare/v1.0.0...v1.1.0"
n=$(grep -c '^- ' "$out")
[[ "$n" == 5 ]] && pass "one line per first-parent commit" || fail "one line per first-parent commit: got $n"

# Newest first, as git log prints them.
first=$(grep -m1 '^- ' "$out")
[[ "$first" == "- Merge pull request #13 from luthersystems/empty (#13)" ]] && pass "newest first" || fail "newest first: $first"

# The extra command's output follows the list, with LAST_TAG and TAG set.
LAST_TAG=v1.0.0 TAG=v1.1.0 EXTRA_COMMAND='printf "## Extra\n\nfrom %s to %s\n" "$LAST_TAG" "$TAG"' \
  bash "$NOTES" >"$out" 2>"$TMP/err" || fail "extra command runs: $(cat "$TMP/err")"
want "extra section" "$out" "## Extra"
want "extra command sees the tags" "$out" "from v1.0.0 to v1.1.0"
el=$(grep -n '^## Extra$' "$out" | cut -d: -f1)
ll=$(grep -n '^- ' "$out" | tail -1 | cut -d: -f1)
[[ -n "$el" && -n "$ll" && "$el" -gt "$ll" ]] && pass "extra after the list" || fail "extra after the list"
nowant "no compare link without GITHUB_REPOSITORY" "$out" "Full Changelog"

# A failing extra command fails the notes.
if LAST_TAG=v1.0.0 EXTRA_COMMAND='echo partial; exit 3' bash "$NOTES" >"$out" 2>/dev/null; then
  fail "failing extra command fails the notes"
else
  pass "failing extra command fails the notes"
fi

# An extra command that prints nothing adds nothing.
LAST_TAG=v1.0.0 bash "$NOTES" >"$TMP/plain.md"
LAST_TAG=v1.0.0 EXTRA_COMMAND='true' bash "$NOTES" >"$out"
cmp -s "$out" "$TMP/plain.md" && pass "empty extra adds nothing" || fail "empty extra adds nothing"

# A start tag that is not in the checkout fails, not an empty list.
if LAST_TAG=v9.9.9 bash "$NOTES" >"$out" 2>"$TMP/err"; then
  fail "unknown LAST_TAG fails"
else
  grep -q "is not a tag in this checkout" "$TMP/err" && pass "unknown LAST_TAG fails" || fail "unknown LAST_TAG fails for the right reason: $(cat "$TMP/err")"
fi

# No LAST_TAG lists the whole history, with no compare link.
TAG=v1.1.0 GITHUB_REPOSITORY=luthersystems/example bash "$NOTES" >"$out"
want "first release lists the oldest commit" "$out" "- Before the last release ($(git rev-parse --short=7 v1.0.0))"
nowant "first release has no compare link" "$out" "Full Changelog"

# No commits since the tag.
git tag v1.1.0
LAST_TAG=v1.1.0 bash "$NOTES" >"$out"
want "no changes" "$out" "- No changes since v1.1.0."

# More than 200 changes are all listed (the old scripts stopped at 200).
for i in $(seq 1 205); do c "Change $i"; done
LAST_TAG=v1.1.0 bash "$NOTES" >"$out"
n=$(grep -c '^- Change ' "$out")
[[ "$n" == 205 ]] && pass "no cap at 200" || fail "no cap at 200: got $n"

# Past the size limit the list ends with a count of the rest and a link.
LAST_TAG=v1.1.0 TAG=v1.2.0 GITHUB_REPOSITORY=luthersystems/example LIST_LIMIT=200 bash "$NOTES" >"$out"
n=$(grep -c '^- Change ' "$out")
(( n > 0 && n < 205 )) && pass "size limit cuts the list" || fail "size limit cuts the list: got $n"
want "size limit counts the rest" "$out" "- ...and $(( 205 - n )) more changes: https://github.com/luthersystems/example/compare/v1.1.0...v1.2.0"
TAG=v1.2.0 GITHUB_REPOSITORY=luthersystems/example LIST_LIMIT=200 bash "$NOTES" >"$out"
grep -q '^- \.\.\.and [0-9]* more changes: https://github.com/luthersystems/example/commits/v1.2.0$' "$out" \
  && pass "size limit on a first release links the commits" || fail "size limit on a first release links the commits"

if (( fails > 0 )); then
  echo "$fails case(s) failed" >&2
  exit 1
fi
echo "all release notes cases passed"
