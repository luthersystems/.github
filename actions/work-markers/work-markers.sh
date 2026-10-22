#!/usr/bin/env bash
# Work marker gate: every work marker in the tracked tree names an issue.
#
# Ported from luthersystems/substrate scripts/work-marker-gate.sh. The owner
# chose substrate's rule for every repo, so all repos share one rule and one
# script, and a fix reaches every repo when v1 moves.
#
# A work marker is one of five upper-case words for deferred work, broken
# code and kludges (the first is the word for "to do"). This script never
# writes them literally: it assembles them below, so its own source and this
# repo's scan cannot trip the gate.
#
# A marker passes when one of these is true:
#
#   * The marker is followed at once by a reference in parentheses:
#     MARKER(#123) or MARKER(owner/repo#123). `#123` is an issue of the
#     caller repo (WORK_MARKER_REPO).
#   * An entry in the allowlist covers the line. Entries are for words that
#     are not work (copied third-party source, data, a log prefix).
#   * It is Go's context.<marker>() call.
#
# With --check-issues (or CHECK_ISSUES=true), the gate also reads each
# referenced issue from GitHub. Every reference must name an issue that is
# OPEN, so a marker always points at the backlog. A closed issue, a pull
# request, a missing issue or one the token cannot read fails the gate: an
# unread reference is not a proven one.
#
# Matching is case-sensitive and bounded: a marker counts only when the
# characters on both sides are not letters, digits or `_`. The self-test
# below proves both directions on every run.
#
# Exit codes:
#   0  every marker passes, and every allowlist entry covers a marker
#   1  a marker does not pass, an entry is stale or expired, or (with
#      --check-issues) a reference is not an open issue
#   2  the gate could not run: no repository, no repo name, an unreadable
#      tree, an empty scan, a malformed allowlist, or a failed self-test
#
# Environment:
#   ALLOWLIST              Allowlist path, relative to the repo root. Default:
#                          .github/quality/work-markers.txt. A missing file
#                          means no entries.
#   CHECK_ISSUES           "true" turns on the issue check, as --check-issues.
#   WORK_MARKER_REPO       owner/repo that `#123` means. Default:
#                          GITHUB_REPOSITORY.
#   WORK_MARKER_TODAY      YYYY-MM-DD to use as today. Default: the UTC date.
#   GH_TOKEN, GITHUB_TOKEN A token that can read the issues (--check-issues).
#                          Without one the gate tries `gh auth token`, then
#                          reads anonymously (public repositories only).
#   WORK_MARKER_ISSUE_CMD  For tests. A command run as `CMD owner/repo N`
#                          that prints open, closed, pr or missing. Default:
#                          the GitHub REST API through curl.
#
# Usage: work-markers.sh [--check-issues]   (from anywhere in the repo)
set -euo pipefail

ALLOWLIST="${ALLOWLIST:-.github/quality/work-markers.txt}"
REPO="${WORK_MARKER_REPO:-${GITHUB_REPOSITORY:-}}"

die() {
  echo "::error title=work markers::$*"
  echo "work marker gate: $*" >&2
  echo "work marker gate: refusing to report clean." >&2
  exit 2
}

# migration_hint prints once, on a failure, what a repo that used the old
# elps-style allowlist must change. Under that rule, deferred work was a row
# with a date and an issue. Under the shared rule the reference goes on the
# marker itself, so the row has to move into the code.
hinted=0
migration_hint() {
  [ "$hinted" -eq 0 ] || return 0
  hinted=1
  echo "work marker gate: moving from the old elps-style allowlist? Its rows for deferred work (a date and an" >&2
  echo "  issue) must become inline references on the marker, MARKER(#N) or MARKER(owner/repo#N). Keep in" >&2
  echo "  ${ALLOWLIST} only words that are not work (copied source, data), with expires never." >&2
}

CHECK_ISSUES="${CHECK_ISSUES:-false}"
case "$CHECK_ISSUES" in
true) CHECK_ISSUES=1 ;;
false | "") CHECK_ISSUES=0 ;;
*) die "CHECK_ISSUES ${CHECK_ISSUES} is not true or false" ;;
esac
for arg in "$@"; do
  case "$arg" in
  --check-issues) CHECK_ISSUES=1 ;;
  *) die "unknown argument ${arg} (usage: $0 [--check-issues])" ;;
  esac
done

REPO_TOP=""
rev_rc=0
REPO_TOP="$(git rev-parse --show-toplevel 2>&1)" || rev_rc=$?
if [ "$rev_rc" -ne 0 ] || [ -z "$REPO_TOP" ]; then
  [ -n "$REPO_TOP" ] && printf '%s\n' "$REPO_TOP" | sed 's/^/  | /' >&2
  die "cannot locate the repository root (git rev-parse exit ${rev_rc})"
fi
cd "$REPO_TOP"

# `#N` must name one repo. Guessing one would check the wrong issues, so the
# gate stops when it does not know which repo it scans.
[ -n "$REPO" ] || die "set WORK_MARKER_REPO or GITHUB_REPOSITORY to the owner/repo that #N means"
TODAY="${WORK_MARKER_TODAY:-$(date -u +%Y-%m-%d)}"
[[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "today ${TODAY} is not a YYYY-MM-DD date"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "repo ${REPO} is not owner/repo"

# The markers, assembled so that no marker appears literally in this file.
MARKERS="$(printf '%s|' "TO""DO" "FIX""ME" "X""XX" "HA""CK" "B""UG")"
MARKERS="${MARKERS%|}"
PATTERN="(^|[^[:alnum:]_])(${MARKERS})([^[:alnum:]_]|$)"
REF='#[0-9]+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+'
# A tracked marker: the marker, then at once a reference in parentheses.
TRACKED="(^|[^[:alnum:]_])(${MARKERS})\\((${REF})\\)"
GO_CALL="context.TO""DO()"

has_marker() { [[ "$1" =~ $PATTERN ]]; }

# full_ref <ref>: owner/repo#N for a reference; `#N` is the caller repo's.
full_ref() {
  if [[ "$1" == "#"* ]]; then printf '%s%s' "$REPO" "$1"; else printf '%s' "$1"; fi
}

# strip_tracked <line> <where>: sets STRIPPED to the line with every tracked
# marker removed, and appends each reference it removed to the refs array.
refs=()
refs_at=()
strip_tracked() {
  local rest="$1" where="$2" m
  STRIPPED=""
  while [[ "$rest" =~ $TRACKED ]]; do
    m="${BASH_REMATCH[0]}"
    refs+=("$(full_ref "${BASH_REMATCH[3]}")")
    refs_at+=("$where")
    # Keep the boundary character the match began with.
    rest="${rest/"$m"/"${BASH_REMATCH[1]}"}"
  done
  STRIPPED="$rest"
}

# --- self-test: boundary handling and references ----------------------------
#
# Regex rules are easy to break in a way that passes everything. These
# fixtures run on every call, so a broken rule stops the gate (exit 2)
# instead of reporting a clean tree.

m="TO""DO"
for fixture in "todo" "${m}S" "_${m}" "${m}_" "1${m}" "${m}1" "X""X" "X""XXL" "DEB""UG"; do
  if has_marker "$fixture"; then
    die "self-test failed: false positive on ${fixture}"
  fi
done
for fixture in "$m" "// ${m}: x" "${m}(#1)" "(B""UG)" "; FIX""ME" "x-HA""CK-y" "pkg:X""XX"; do
  if ! has_marker "$fixture"; then
    die "self-test failed: missed ${fixture}"
  fi
done
for fixture in "// ${m}(#12): x" "x ${m}(a/b#3) y" "(FIX""ME(#1))"; do
  strip_tracked "$fixture" self-test
  if has_marker "$STRIPPED"; then
    die "self-test failed: tracked marker not accepted in ${fixture}"
  fi
done
for fixture in "// ${m}: x" "${m} (#1)" "${m}(#)" "${m}(12)" "${m}(#1 x)" "${m}(#1) ${m}" "x${m}(#1) ${m}"; do
  strip_tracked "$fixture" self-test
  if ! has_marker "$STRIPPED"; then
    die "self-test failed: untracked marker accepted in ${fixture}"
  fi
done
refs=()
refs_at=()

# --- read the allowlist ------------------------------------------------------

# valid_date <YYYY-MM-DD>: a real calendar date. Portable (no GNU `date -d`).
valid_date() {
  [[ "$1" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) mo=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local -a days=(0 31 28 31 30 31 30 31 31 30 31 30 31)
  if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then days[2]=29; fi
  ((mo >= 1 && mo <= 12 && d >= 1 && d <= days[mo]))
}

# valid_issues <field>: one or more references (#N or owner/repo#N).
valid_issues() {
  local good=0 t
  for t in ${1//,/ }; do
    [[ "$t" =~ ^(${REF})$ ]] || return 1
    good=$((good + 1))
  done
  [ "$good" -gt 0 ]
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

e_path=()
e_text=()
e_expires=()
e_line=()
e_used=()
e_expired=()
malformed=0
declare -A seen=()
lineno=0
bad() {
  echo "  ALLOW-BAD  ${ALLOWLIST}:${lineno}  $1" >&2
  malformed=1
}

# A missing allowlist means no entries. Substrate's copy refuses to run
# instead, because there the file must exist. Here most repos have no word
# to allow, and with no entries every marker must name an issue, so a
# missing file can only make the gate stricter. That is safe.
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    raw="${raw%$'\r'}"
    [[ "$raw" =~ ^[[:space:]]*(#|$) ]] && continue
    IFS='|' read -r -a f <<<"$raw"
    if [ "${#f[@]}" -ne 5 ] || [[ "$raw" == *"|" ]]; then
      bad "expected 5 |-separated fields (path | text | expires | issue | reason)"
      continue
    fi
    path="$(trim "${f[0]}")"
    text="$(trim "${f[1]}")"
    expires="$(trim "${f[2]}")"
    issue="$(trim "${f[3]}")"
    reason="$(trim "${f[4]}")"
    ok=1
    if [ -z "$path" ] || [[ "$path" == *[[:space:]*?]* ]]; then
      bad "path must be one exact repository-relative path (no spaces or globs)"
      ok=0
    fi
    if [ "$text" = "*" ]; then
      if [ "$expires" != "never" ]; then
        bad "a whole-file entry (text *) is only for files that are not our work, so it needs expires never"
        ok=0
      fi
    elif ! has_marker "$text"; then
      bad "text must contain a work marker (or be * for a whole file), so the entry cannot cover lines without one"
      ok=0
    fi
    if [ "$expires" = "never" ]; then
      if [ "$issue" != "-" ] && ! valid_issues "$issue"; then
        bad "issue ${issue} is not - or a reference (#412 or owner/repo#412)"
        ok=0
      fi
    elif ! valid_date "$expires"; then
      bad "expires ${expires} is not a real YYYY-MM-DD date or never"
      ok=0
    elif ! valid_issues "$issue"; then
      bad "issue ${issue} is not a reference; deferred work needs an issue (#412 or owner/repo#412)"
      ok=0
    fi
    if [ "${#reason}" -lt 10 ]; then
      bad "reason is missing or shorter than 10 characters"
      ok=0
    fi
    [ "$ok" -eq 1 ] || continue
    key="${path}|${text}"
    if [ -n "${seen[$key]:-}" ]; then
      bad "duplicate entry for ${key} (first at line ${seen[$key]})"
      continue
    fi
    seen[$key]="$lineno"
    e_path+=("$path")
    e_text+=("$text")
    e_expires+=("$expires")
    e_line+=("$lineno")
    e_used+=(0)
    if [ "$expires" != "never" ] && [[ "$TODAY" > "$expires" ]]; then
      e_expired+=(1)
    else
      e_expired+=(0)
    fi
    if [ "$issue" != "-" ]; then
      for t in ${issue//,/ }; do
        refs+=("$(full_ref "$t")")
        refs_at+=("${ALLOWLIST}:${lineno}")
      done
    fi
  done <"$ALLOWLIST"
  if [ "$malformed" -ne 0 ]; then
    migration_hint
    die "${ALLOWLIST} is malformed (see ALLOW-BAD lines above)"
  fi
else
  echo "::notice title=work markers::${ALLOWLIST} does not exist, so it has no entries: every work marker must name an issue."
fi

# --- prove the scan can see the tree ----------------------------------------
#
# git grep exits 1 both on a clean tree and when it read nothing (for
# example, tracked files missing from the working tree). Count readable files
# with the same command and pathspec first, so an empty scan cannot read as
# clean.

# The allowlist holds markers as data, so the scan leaves it out. It leaves
# it out only when it exists: an exclude of a missing path is harmless to git,
# but there is nothing to exclude.
PATHSPEC=(-- .)
[ ! -f "$ALLOWLIST" ] || PATHSPEC+=(":(exclude)${ALLOWLIST}")
scan_err="$(mktemp)"
hits="$(mktemp)"
trap 'rm -f "$scan_err" "$hits"' EXIT
seen_rc=0
n_seen="$(git grep -IlE '.' "${PATHSPEC[@]}" 2>"$scan_err" | grep -c .)" || seen_rc=$?
if [ "$seen_rc" -ne 0 ] && [ "$seen_rc" -ne 1 ]; then
  sed 's/^/  | /' "$scan_err" >&2
  die "the tree could not be read (exit ${seen_rc})"
fi
if [ -s "$scan_err" ]; then
  sed 's/^/  | /' "$scan_err" >&2
  die "the tree could not be read"
fi
[ "${n_seen:-0}" -gt 0 ] || die "the scan matched ZERO readable files in $(pwd)"

# --- scan the tracked tree ---------------------------------------------------

grep_rc=0
git grep -IznE "$PATTERN" "${PATHSPEC[@]}" >"$hits" 2>"$scan_err" || grep_rc=$?
if [ "$grep_rc" -gt 1 ]; then
  sed 's/^/  | /' "$scan_err" >&2
  die "git grep failed (exit ${grep_rc})"
fi

uncovered=0
while IFS= read -r -d '' path && IFS= read -r -d '' ln && IFS= read -r line; do
  rest="${line//"$GO_CALL"/}"
  for i in "${!e_path[@]}"; do
    [ "${e_path[$i]}" = "$path" ] || continue
    [ "${e_expired[$i]}" -eq 0 ] || continue
    text="${e_text[$i]}"
    if [ "$text" = "*" ]; then
      rest=""
      e_used[i]=1
    elif [[ "$rest" == *"$text"* ]]; then
      rest="${rest//"$text"/}"
      e_used[i]=1
    fi
  done
  strip_tracked "$rest" "${path}:${ln}"
  rest="$STRIPPED"
  if has_marker "$rest"; then
    if [ "$uncovered" -eq 0 ]; then
      echo "work marker gate: work markers that name no issue:" >&2
    fi
    uncovered=$((uncovered + 1))
    shown="$(trim "$line")"
    [ "${#shown}" -le 200 ] || shown="${shown:0:200}..."
    echo "  ${path}:${ln}: ${shown}" >&2
    # An annotation on the line, so the PR shows it where the marker is.
    echo "::error file=${path},line=${ln},title=work marker::This work marker names no issue. Write it as MARKER(#N) or MARKER(owner/repo#N)."
  fi
done <"$hits"

stale=0
for i in "${!e_path[@]}"; do
  [ "${e_used[$i]}" -eq 1 ] && continue
  stale=$((stale + 1))
  if [ "${e_expired[$i]}" -eq 1 ]; then
    echo "  ALLOW-EXPIRED  ${ALLOWLIST}:${e_line[$i]}  ${e_path[$i]} | ${e_text[$i]} expired ${e_expires[$i]}; fix the marker, or re-decide and set a new date" >&2
  else
    echo "  ALLOW-STALE  ${ALLOWLIST}:${e_line[$i]}  ${e_path[$i]} | ${e_text[$i]} covers nothing; delete the entry" >&2
  fi
done

# --- check that every reference is an open issue -----------------------------

# issue_state <owner/repo> <N> prints open, closed, pr or missing, or
# "error: <why>" when the issue could not be read. An error stops the gate
# with exit 2: a rate limit or an outage is not a bad marker.
issue_state() {
  if [ -n "${WORK_MARKER_ISSUE_CMD:-}" ]; then
    $WORK_MARKER_ISSUE_CMD "$1" "$2"
    return
  fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}" out code body
  if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi
  local -a auth=()
  [ -z "$token" ] || auth=(-H "Authorization: Bearer ${token}")
  if ! out="$(curl -sS --max-time 20 --retry 2 -w '\n%{http_code}' "${auth[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/issues/$2" 2>&1)"; then
    echo "error: curl failed: ${out##*$'\n'}"
    return
  fi
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
  200) ;;
  404 | 410)
    echo missing
    return
    ;;
  *)
    echo "error: GitHub answered HTTP ${code}"
    return
    ;;
  esac
  printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("pr" if "pull_request" in d else d.get("state", "missing"))
' 2>/dev/null || echo "error: cannot parse the answer for $1#$2"
}

not_open=0
n_refs=0
if [ "$CHECK_ISSUES" -eq 1 ]; then
  if [ -z "${WORK_MARKER_ISSUE_CMD:-}" ]; then
    command -v curl >/dev/null 2>&1 || die "--check-issues needs curl"
    command -v python3 >/dev/null 2>&1 || die "--check-issues needs python3"
  fi
  declare -A state=()
  for i in "${!refs[@]}"; do
    r="${refs[$i]}"
    if [ -z "${state[$r]:-}" ]; then
      n_refs=$((n_refs + 1))
      state[$r]="$(issue_state "${r%%#*}" "${r##*#}")"
    fi
    case "${state[$r]}" in
    open) ;;
    closed) msg="is closed; point the marker at an open issue, or do the work" ;;
    pr) msg="is a pull request, not an issue" ;;
    missing) msg="could not be read (no such issue, or the token cannot read it; an issue in another private repo needs a token that can read that repo)" ;;
    error:*) die "cannot read ${r}: ${state[$r]#error: }" ;;
    *) msg="has unknown state '${state[$r]}'" ;;
    esac
    if [ "${state[$r]}" != "open" ]; then
      not_open=$((not_open + 1))
      echo "  ISSUE-NOT-OPEN  ${refs_at[$i]}  ${r} ${msg}" >&2
    fi
  done
fi

if [ "$uncovered" -gt 0 ] || [ "$stale" -gt 0 ] || [ "$not_open" -gt 0 ]; then
  if [ "$uncovered" -gt 0 ]; then
    echo "work marker gate: ${uncovered} line(s) with a marker that names no issue. Do the work, or open an issue and write" >&2
    echo "  the marker as MARKER(#NNN) or MARKER(owner/repo#NNN). Words that are not work go in ${ALLOWLIST}." >&2
  fi
  [ "$stale" -gt 0 ] && echo "work marker gate: ${stale} allowlist entry(ies) cover nothing or have expired." >&2
  [ "$not_open" -gt 0 ] && echo "work marker gate: ${not_open} reference(s) are not open issues." >&2
  if [ "$uncovered" -gt 0 ] || [ "$stale" -gt 0 ]; then migration_hint; fi
  echo "::error title=work markers::${uncovered} marker(s) name no issue, ${stale} allowlist entry(ies) are stale or expired, ${not_open} reference(s) are not open issues. Open the job log for the list."
  exit 1
fi

if [ "$CHECK_ISSUES" -eq 1 ]; then
  echo "work marker gate: clean (${n_seen} files scanned, ${#e_path[@]} allowlist entries, ${n_refs} issues open)"
else
  echo "work marker gate: clean (${n_seen} files scanned, ${#e_path[@]} allowlist entries; issues not checked)"
fi
