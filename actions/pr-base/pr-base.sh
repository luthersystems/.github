#!/usr/bin/env bash
# Prints the commit a PR merge commit was built on (its first parent). Why
# not pull_request.base.sha: see action.yml. Ported from substrate's
# scripts/bench-base-ref.sh (#654).
#
# Usage: pr-base.sh <pr-checkout-dir> <pr-head-sha> <fallback-base-sha>
#
# Writes sha=<40-hex> and source=merge-parent|fallback to $GITHUB_OUTPUT and
# to stdout. Exit 2 on bad usage.
#
# Fallback: the fallback SHA is used when the checkout is not a merge of the
# PR head: no merge ref exists (a merge conflict), the checkout is the PR head
# itself, or the merge's second parent is not the PR head. It can be older
# than the base the PR merges into, so a warning says so.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <pr-checkout-dir> <pr-head-sha> <fallback-base-sha>" >&2
  exit 2
}

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

[ "$#" -eq 3 ] || usage
dir="$1" head="$2" fallback="$3"
is_sha "$head" || {
  echo "pr-base: pr-head-sha is not a 40-hex SHA: '${head}' (is this a pull_request event?)" >&2
  exit 2
}
is_sha "$fallback" || {
  echo "pr-base: fallback-base-sha is not a 40-hex SHA: '${fallback}'" >&2
  exit 2
}
[ -d "$dir" ] || {
  echo "pr-base: no such directory: '${dir}'" >&2
  exit 2
}

emit() { # <sha> <source>
  printf 'sha=%s\nsource=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'sha=%s\nsource=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

fall_back() { # <reason>
  echo "::warning::PR base: $1; using pull_request.base.sha ${fallback}, which can be older than the base the PR merges into." >&2
  emit "$fallback" fallback
  exit 0
}

# `git cat-file commit` prints the raw object: header lines, a blank line,
# then the message. Parent lines come before the blank line. The checked-out
# commit is read, not refs/pull/<N>/merge: that ref moves when the base
# moves, and the base must match the tree the check measures.
if ! commit="$(git -C "$dir" cat-file commit HEAD 2>/dev/null)"; then
  fall_back "cannot read HEAD in ${dir}"
fi
mapfile -t parents < <(sed -n '/^$/q; s/^parent \([0-9a-f]\{40\}\)$/\1/p' <<<"$commit")

if [ "${#parents[@]}" -ne 2 ]; then
  fall_back "the PR checkout is not a two-parent merge commit (${#parents[@]} parents)"
fi
if [ "${parents[1]}" != "$head" ]; then
  fall_back "the merge commit's second parent ${parents[1]} is not the PR head ${head}"
fi
emit "${parents[0]}" merge-parent
