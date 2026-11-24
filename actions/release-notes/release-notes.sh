#!/usr/bin/env bash
# Prints the release notes for a release of HEAD. See action.yml for why.
#
# Env:
#   LAST_TAG       previous release tag; empty lists all of HEAD's history
#   TAG            tag being released, for the compare link; empty = no link
#   EXTRA_COMMAND  optional shell command whose stdout follows the list
#   GITHUB_REPOSITORY  owner/repo, for the compare link (set by Actions)
#
# One line per commit on the first-parent history, the way it reached main:
# - a merge commit of a PR: the PR title (the first line of the body) and
#   "(#N)";
# - a squash merge already ends in "(#N)", so its subject is used as it is;
# - any other commit (pushed without a PR): its subject and short SHA, so it
#   is still listed, which GitHub's generated notes do not do.
# There is no cap on the number of lines: a long release lists every change.
set -euo pipefail

last_tag="${LAST_TAG:-}"
tag="${TAG:-}"
range=HEAD
if [[ -n "$last_tag" ]]; then
  # Fail here, not with an empty list, when the start tag is not fetched.
  git rev-parse -q --verify "refs/tags/$last_tag^{commit}" >/dev/null || {
    echo "error: LAST_TAG $last_tag is not a tag in this checkout (fetch-depth: 0?)" >&2
    exit 1
  }
  range="$last_tag..HEAD"
fi

# Into a variable first, so a git failure fails the notes (set -e); a
# process substitution would hide it.
log=$(git log --first-parent --format='%H%x1f%P%x1f%s' "$range")
lines=()
# %x1f separates the fields; a subject cannot hold it.
while IFS=$'\x1f' read -r sha parents subject; do
  [[ -n "$sha" ]] || continue
  read -ra parent_list <<<"$parents"
  if (( ${#parent_list[@]} > 1 )) && [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+)\ from\  ]]; then
    pr=${BASH_REMATCH[1]}
    # awk reads the whole body, so git log never ends on SIGPIPE.
    title=$(git log -1 --format=%b "$sha" | awk 'NF && !done { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; done = 1 }')
    lines+=("- ${title:-$subject} (#$pr)")
  elif [[ "$subject" =~ \(#[0-9]+\)$ ]]; then
    lines+=("- $subject")
  else
    lines+=("- $subject (${sha:0:7})")
  fi
done <<<"$log"

echo "## What's Changed"
echo
if (( ${#lines[@]} == 0 )); then
  echo "- No changes since $last_tag."
else
  printf '%s\n' "${lines[@]}"
fi

if [[ -n "${EXTRA_COMMAND:-}" ]]; then
  # Into a variable first, so a failing command fails the notes (set -e)
  # rather than leave half a section in them.
  extra=$(LAST_TAG="$last_tag" TAG="$tag" bash -c "$EXTRA_COMMAND")
  if [[ -n "$extra" ]]; then
    echo
    printf '%s\n' "$extra"
  fi
fi

if [[ -n "$last_tag" && -n "$tag" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  echo
  echo "**Full Changelog**: https://github.com/$GITHUB_REPOSITORY/compare/$last_tag...$tag"
fi
