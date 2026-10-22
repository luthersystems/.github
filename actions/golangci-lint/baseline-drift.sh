#!/usr/bin/env bash
# Compares the linters a repo enables with the linters the shared baseline
# (quality/golangci-baseline.yml) enables, and reports the difference.
#
# Why a report and not a gate: golangci-lint v2 cannot import a shared
# config, so each repo keeps its own copy, and the owner chose to report
# drift, not to fail on it. This script only reads text, so the test can run
# it on canned output without golangci-lint.
#
# Input: two files, each the output of `golangci-lint linters --color never`
# (the repo's config, then the baseline's, read with -c). golangci-lint
# v2.15.0 prints this shape:
#
#   Enabled by your configuration linters:
#   errcheck: Errcheck is a program for ... [fast]
#   gosec: Inspects source code for security problems.
#
#   Disabled by your configuration linters:
#   ...
#
# The parse is defensive, because the format is text for people and a new
# release can change it: it strips color codes, takes the lines after the
# "Enabled" header up to the first blank line or "Disabled" header, and keeps
# only a leading name made of lower-case letters, digits, `_` and `-`. If it
# finds no "Enabled" header it exits 2, so a changed format reads as "cannot
# compare", never as "no drift".
#
# Output: a markdown table, appended to $GITHUB_STEP_SUMMARY (stdout when it
# is not set), and one ::notice:: line with the counts on stdout.
#
# Usage: baseline-drift.sh REPO_LINTERS BASELINE_LINTERS [MODULE]
# Exit: 0 report written, 2 a file is missing or has no "Enabled" section.
set -euo pipefail

[ "$#" -ge 2 ] || {
  echo "usage: $0 REPO_LINTERS BASELINE_LINTERS [MODULE]" >&2
  exit 2
}
repo_out="$1" base_out="$2" module="${3:-.}"

# enabled <file>: prints the enabled linter names, one per line, sorted.
# Exits 2 when the file has no "Enabled" section.
enabled() {
  [ -r "$1" ] || {
    echo "baseline drift: cannot read $1" >&2
    return 2
  }
  sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r$//' "$1" | awk '
    /^[[:space:]]*Enabled[^:]*linters:?[[:space:]]*$/ { inside = 1; found = 1; next }
    inside && (/^[[:space:]]*$/ || /^[[:space:]]*Disabled/) { inside = 0; next }
    inside && match($0, /^[[:space:]]*[a-z0-9_-]+:/) {
      name = substr($0, RSTART, RLENGTH - 1)
      gsub(/[[:space:]]/, "", name)
      print name
    }
    END { if (!found) exit 2 }
  ' | sort -u
  # awk sits in the middle of the pipe, so check its status from PIPESTATUS.
  local st=("${PIPESTATUS[@]}")
  if [ "${st[1]}" -ne 0 ]; then
    echo "baseline drift: no \"Enabled ... linters:\" section in $1; the golangci-lint linters format may have changed" >&2
    return 2
  fi
}

repo_set="$(enabled "$repo_out")" || exit 2
base_set="$(enabled "$base_out")" || exit 2

# comm needs sorted input; enabled() sorts. Empty sets give empty lines,
# which grep . removes.
missing="$(comm -13 <(printf '%s\n' "$repo_set") <(printf '%s\n' "$base_set") | grep . || true)"
extra="$(comm -23 <(printf '%s\n' "$repo_set") <(printf '%s\n' "$base_set") | grep . || true)"
n_missing=0
n_extra=0
[ -z "$missing" ] || n_missing="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
[ -z "$extra" ] || n_extra="$(printf '%s\n' "$extra" | wc -l | tr -d ' ')"

# list <names>: a markdown cell, names as code, comma separated.
list() {
  if [ -z "$1" ]; then
    echo "none"
  else
    # shellcheck disable=SC2016 # backticks are markdown, not a command
    printf '%s\n' "$1" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g'
  fi
}

{
  echo "#### \`$module\`"
  echo
  echo "| Drift | Count | Linters |"
  echo "|---|---|---|"
  echo "| Baseline enables, repo does not | $n_missing | $(list "$missing") |"
  echo "| Repo adds | $n_extra | $(list "$extra") |"
  echo
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

echo "::notice title=golangci-lint baseline::$module: the repo config lacks $n_missing baseline linter(s)$([ -z "$missing" ] || printf ' (%s)' "$(printf '%s\n' "$missing" | paste -sd' ' -)") and adds $n_extra$([ -z "$extra" ] || printf ' (%s)' "$(printf '%s\n' "$extra" | paste -sd' ' -)")."
