#!/usr/bin/env bash
# Tests actions/work-markers/work-markers.sh. Ported from luthersystems/
# substrate scripts/work-marker-gate-test.sh.
#
# Each case builds a small git repository in a temp directory, runs the gate
# in it and checks the exit code. Where the reason matters, it also checks
# the log, so a gate that fails for another reason (a crash, a missing tool)
# does not pass the case. Issue states come from a stub
# (WORK_MARKER_ISSUE_CMD) or a stub curl, so the test needs no network and
# no token.
#
# Needs on PATH: bash, git. Run from anywhere:
#   bash tests/quality/work-markers-test.sh
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/actions/work-markers/work-markers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The markers, assembled so that no marker appears literally in this file
# (this repo runs the gate on itself).
T="TO""DO"
F="FIX""ME"

# The repo that `#N` means in these cases.
REPO=luthersystems/example
# The default allowlist path of the action.
AL=.github/quality/work-markers.txt

# Issue stub: luthersystems/example#1 and other/repo#5 are open, #2 is
# closed, #3 is a pull request, #4 cannot be read, anything else is missing.
cat >"${TMP}/issues" <<'EOF'
#!/usr/bin/env bash
case "$1#$2" in
luthersystems/example#1 | other/repo#5) echo open ;;
luthersystems/example#2) echo closed ;;
luthersystems/example#3) echo pr ;;
luthersystems/example#4) echo "error: GitHub answered HTTP 503" ;;
*) echo missing ;;
esac
EOF
chmod +x "${TMP}/issues"

pass=0
fail=0

# repo <allowlist-content|<none>> <file-content>...: a fresh repository with
# the allowlist at its default path and src/f<i>.txt files, all tracked.
# Prints its path. It runs in a command substitution, so it takes a new
# directory from mktemp: a counter would not survive the subshell.
repo() {
  local d i=0 c
  d="$(mktemp -d "${TMP}/r.XXXXXX")"
  mkdir -p "${d}/.github/quality" "${d}/src"
  git -C "$d" init -q
  if [ "$1" != "<none>" ]; then printf '%s\n' "$1" >"${d}/${AL}"; fi
  shift
  for c in "$@"; do
    i=$((i + 1))
    printf '%s\n' "$c" >"${d}/src/f${i}.txt"
  done
  git -C "$d" add -A
  printf '%s' "$d"
}

# result <desc> <want-exit> <got-exit>: records one case.
result() {
  if [ "$3" -eq "$2" ]; then
    pass=$((pass + 1))
    echo "ok   ${1}"
  else
    fail=$((fail + 1))
    echo "FAIL ${1}: exit ${3}, want ${2}"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi
}

# check <desc> <want-exit> <dir> [gate args...]: runs the gate with the stub.
check() {
  local desc="$1" want="$2" dir="$3" got
  shift 3
  out="$(cd "$dir" && env -u GITHUB_REPOSITORY WORK_MARKER_REPO="$REPO" WORK_MARKER_TODAY=2026-10-19 \
    WORK_MARKER_ISSUE_CMD="${TMP}/issues" bash "$GATE" "$@" 2>&1)"
  got=$?
  result "$desc" "$want" "$got"
}

# want_output <desc> <text>: the last case's log contains text.
want_output() {
  if [[ "$out" == *"$2"* ]]; then
    pass=$((pass + 1))
    echo "ok   ${1}"
  else
    fail=$((fail + 1))
    echo "FAIL ${1}: log lacks '${2}'"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi
}

EMPTY="# no entries"

# --- markers -----------------------------------------------------------------

d="$(repo "$EMPTY" "x := 1")"
check "a tree with no marker passes" 0 "$d"
want_output "the clean run says clean" "work marker gate: clean"

d="$(repo "$EMPTY" "x := 1" "// ${T}(#1): later" "// ${F}(other/repo#5): later")"
check "markers with open issues pass the issue check" 0 "$d" --check-issues
check "markers with references pass without the issue check" 0 "$d"

d="$(repo "$EMPTY" "// ${T}: later")"
check "a marker with no reference fails" 1 "$d"
want_output "the failure names the line" "src/f1.txt:1"
want_output "the failure annotates the line" "::error file=src/f1.txt,line=1"
want_output "the failure gives the migration hint" "elps-style allowlist"

d="$(repo "$EMPTY" "// ${T} (#1): later")"
check "a reference that does not follow the marker at once fails" 1 "$d"

d="$(repo "$EMPTY" "// ${T}(#1) and ${F}: later")"
check "a second marker on a line needs its own reference" 1 "$d"

d="$(repo "$EMPTY" "ctx := context.${T}()")"
check "Go's context call is not a marker" 0 "$d"

d="$(repo "$EMPTY" "debug := ${T}S + _${T}")"
check "a marker inside a word is not a marker" 0 "$d"

# An untracked file is not in the tree a PR merges, so the scan skips it.
d="$(repo "$EMPTY" "x := 1")"
printf '// %s: later\n' "$T" >"${d}/src/untracked.txt"
check "an untracked file is not scanned" 0 "$d"
git -C "$d" add src/untracked.txt
check "the same file, once tracked, fails" 1 "$d"
want_output "the failure names the tracked file" "src/untracked.txt:1"

# --- issue check -------------------------------------------------------------

d="$(repo "$EMPTY" "// ${T}(#2): later")"
check "a closed issue passes without the issue check" 0 "$d"
check "a closed issue fails the issue check" 1 "$d" --check-issues
want_output "the failure names the closed issue" "luthersystems/example#2 is closed"
out="$(cd "$d" && WORK_MARKER_REPO="$REPO" WORK_MARKER_TODAY=2026-10-19 CHECK_ISSUES=true \
  WORK_MARKER_ISSUE_CMD="${TMP}/issues" bash "$GATE" 2>&1)"
result "CHECK_ISSUES=true turns the issue check on" 1 $?

d="$(repo "$EMPTY" "// ${T}(#3): later")"
check "a pull request fails the issue check" 1 "$d" --check-issues
want_output "the failure says it is a pull request" "is a pull request"

d="$(repo "$EMPTY" "// ${T}(#9): later")"
check "a missing issue fails the issue check" 1 "$d" --check-issues

d="$(repo "$EMPTY" "// ${T}(other/repo#5): later")"
check "a cross-repo reference to an open issue passes" 0 "$d" --check-issues
d="$(repo "$EMPTY" "// ${T}(other/repo#9): later")"
check "a cross-repo reference the token cannot read fails" 1 "$d" --check-issues
want_output "the failure names the other repo" "other/repo#9 could not be read"

d="$(repo "$EMPTY" "// ${T}(#4): later")"
check "an issue that cannot be read stops the gate" 2 "$d" --check-issues

# #N means GITHUB_REPOSITORY when WORK_MARKER_REPO is not set.
d="$(repo "$EMPTY" "// ${T}(#2): later")"
out="$(cd "$d" && env -u WORK_MARKER_REPO GITHUB_REPOSITORY="$REPO" WORK_MARKER_TODAY=2026-10-19 \
  WORK_MARKER_ISSUE_CMD="${TMP}/issues" bash "$GATE" --check-issues 2>&1)"
result "#N means GITHUB_REPOSITORY by default" 1 $?
want_output "the default repo is read" "luthersystems/example#2 is closed"
out="$(cd "$d" && env -u WORK_MARKER_REPO -u GITHUB_REPOSITORY bash "$GATE" 2>&1)"
result "no repo name stops the gate" 2 $?
want_output "the stop names the variables" "WORK_MARKER_REPO or GITHUB_REPOSITORY"

# The real lookup, with a stub curl on PATH that answers by issue number.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/curl" <<'EOF2'
#!/usr/bin/env bash
case "${*: -1}" in
*/issues/1) printf '{"state":"open","milestone":{"state":"closed"}}\n200' ;;
*/issues/2) printf '{"state":"closed"}\n200' ;;
*/issues/3) printf '{"state":"open","pull_request":{}}\n200' ;;
*/issues/9) printf '{"message":"Not Found"}\n404' ;;
*) printf '{"message":"rate limit"}\n403' ;;
esac
EOF2
chmod +x "${TMP}/bin/curl"
# lookup <desc> <want-exit> <dir>: runs the gate's own lookup through the stub.
lookup() {
  local desc="$1" want="$2" dir="$3" got
  out="$(cd "$dir" && PATH="${TMP}/bin:${PATH}" WORK_MARKER_REPO="$REPO" WORK_MARKER_TODAY=2026-10-19 \
    GH_TOKEN=x bash "$GATE" --check-issues 2>&1)"
  got=$?
  result "$desc" "$want" "$got"
}
lookup "the lookup reads an open issue" 0 "$(repo "$EMPTY" "// ${T}(#1): later")"
lookup "the lookup reads a closed issue" 1 "$(repo "$EMPTY" "// ${T}(#2): later")"
lookup "the lookup reads a pull request" 1 "$(repo "$EMPTY" "// ${T}(#3): later")"
lookup "the lookup reads a 404 as missing" 1 "$(repo "$EMPTY" "// ${T}(#9): later")"
want_output "a 404 says the issue could not be read" "could not be read"
lookup "a 403 stops the gate" 2 "$(repo "$EMPTY" "// ${T}(#7): later")"
want_output "the stop names the status" "HTTP 403"

# --- allowlist ---------------------------------------------------------------

d="$(repo "<none>" "x := 1" "// ${T}(#1): later")"
check "a missing allowlist passes" 0 "$d"
want_output "a missing allowlist prints a notice" "::notice title=work markers::${AL} does not exist"
d="$(repo "<none>" "// ${T}: later")"
check "a missing allowlist covers nothing" 1 "$d"

d="$(repo "src/f1.txt | ${T}: upstream | never | - | Upstream note in copied source." "// ${T}: upstream note")"
check "an allowlist entry covers its line" 0 "$d"
# That case also proves the scan leaves out the allowlist, which holds a
# marker as data.

d="$(repo "<none>" "// ${T}: upstream note")"
mkdir -p "${d}/conf"
printf '%s\n' "src/f1.txt | ${T}: upstream | never | - | Upstream note in copied source." >"${d}/conf/markers.txt"
git -C "$d" add -A
out="$(cd "$d" && WORK_MARKER_REPO="$REPO" ALLOWLIST=conf/markers.txt bash "$GATE" 2>&1)"
result "ALLOWLIST names another path" 0 $?

d="$(repo "src/f1.txt | * | never | - | A bundle we do not edit at all." "// ${T}: a" "// ${F}: b")"
check "a whole-file entry covers only its file" 1 "$d"
want_output "the other file still fails" "src/f2.txt:1"

d="$(repo "src/f1.txt | * | 2027-01-01 | #1 | A bundle we do not edit at all." "// ${T}: a")"
check "a whole-file entry with a date is malformed" 2 "$d"

d="$(repo "src/f1.txt | ${T}: gone | never | - | Upstream note in copied source." "x := 1")"
check "a stale allowlist entry fails" 1 "$d"
want_output "the failure says ALLOW-STALE" "ALLOW-STALE"

d="$(repo "src/f1.txt | ${T}: a | 2026-10-01 | #1 | Work deferred to issue one." "// ${T}: a")"
check "an expired allowlist entry stops covering" 1 "$d"
want_output "the failure says ALLOW-EXPIRED" "ALLOW-EXPIRED"

d="$(repo "src/f1.txt | ${T}: a | 2027-01-01 | #2 | Work deferred to issue two." "// ${T}: a")"
check "an allowlist entry's closed issue fails the issue check" 1 "$d" --check-issues

d="$(repo "src/f1.txt | ${T}: a | never" "// ${T}: a")"
check "a malformed allowlist refuses to run" 2 "$d"
want_output "the refusal says ALLOW-BAD" "ALLOW-BAD"
want_output "the refusal gives the migration hint" "elps-style allowlist"

# An elps-style row: elps accepted `elps#412` as an issue; this gate does not.
d="$(repo "src/f1.txt | ${T}: a | 2027-01-01 | elps#412 | Work deferred to issue 412." "// ${T}: a")"
check "an elps-style issue field is malformed" 2 "$d"

# --- refusals ----------------------------------------------------------------

d="$(repo "$EMPTY" "x := 1")"
check "an unknown argument refuses to run" 2 "$d" --bogus
out="$(cd "$d" && WORK_MARKER_REPO="$REPO" CHECK_ISSUES=yes bash "$GATE" 2>&1)"
result "CHECK_ISSUES other than true or false refuses to run" 2 $?

d="$(mktemp -d "${TMP}/r.XXXXXX")"
git -C "$d" init -q
check "an empty scan refuses to run" 2 "$d"
want_output "the refusal says ZERO" "ZERO readable files"

echo
echo "work-markers-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
