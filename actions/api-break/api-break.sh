#!/usr/bin/env bash
# Runs the API break gate: compares the public Go API of each module in the
# head tree (the current directory, the repo root) with the same module in a
# base commit, and lets elps's cmd/apibreak decide. Why this design: see
# action.yml.
#
# Keys. apibreak names each break by a key, and an override row must use the
# exact key the gate printed. The keys match what `apidiff -m` prints for a
# module at the repo root, so the rows elps already has keep working:
#   - ./pkg/sub.Sym: what       a symbol of the package <module>/pkg/sub
#   - Sym: what                 a symbol of the module's root package
#   - ./pkg/sub: package removed
#   - ./pkg/sub: package became a command (package main)
# For a module that is not at the repo root, every key starts with the
# module's directory (./tools/gen/pkg.Sym, ./tools/gen.Sym for its root
# package), so the same package path in two modules cannot give one key.
#
# Fail closed. A package whose API the gate cannot read is not a package with
# no break. So these stop the gate with exit 2 and a message, never a pass:
# a public package that does not load (in the base or the head), a package
# that starts to depend on an exclude-deps path, a module whose base has no
# public package, and a surface-script that fails.
#
# Env:
#   DIRS            module directories, space separated; empty = every go.mod
#   BASE_SHA        commit to compare against (not needed with API_BREAK_BASE_TREE)
#   OVERRIDES       overrides file, relative to the repo root
#   EXCLUDE_DEPS    import paths, space separated, to leave out (with dependents)
#   SURFACE_SCRIPT  optional script for other surfaces, relative to the repo root
#   API_BREAK_BASE_TREE  tests only: a directory to use as the base tree,
#                   in place of a git worktree of BASE_SHA
# apidiff and apibreak must be on PATH.
#
# Exit: 0 no unwaived break, 1 an unwaived break, 2 could not judge.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(pwd)"
OVERRIDES="${OVERRIDES:-.github/quality/api-breaks.txt}"
EXCLUDE_DEPS="${EXCLUDE_DEPS:-}"
SURFACE_SCRIPT="${SURFACE_SCRIPT:-}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
# Never wait for a password: a module CI cannot fetch must fail, not hang.
export GIT_TERMINAL_PROMPT=0

# cannot prints why the gate could not judge, as an annotation, and exits 2.
cannot() {
  echo "::error title=API break gate could not judge::$*"
  exit 2
}
for tool in apidiff apibreak go; do
  command -v "$tool" >/dev/null || cannot "$tool is not on PATH"
done

tmp="$(mktemp -d)"
worktree=""
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  if [ -n "$worktree" ]; then
    git -C "$root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
# Any command that fails and is not handled below means the gate could not
# judge. Exit 2, so it never reads as 1 (an unwaived break).
trap 'echo "::error title=API break gate could not judge::a command failed at line $LINENO of api-break.sh"; exit 2' ERR

# --- the base tree -----------------------------------------------------------
if [ -n "${API_BREAK_BASE_TREE:-}" ]; then
  base="$(cd "$API_BREAK_BASE_TREE" && pwd)"
  echo "api-break: base tree $base (API_BREAK_BASE_TREE)"
else
  [ -n "${BASE_SHA:-}" ] || cannot "base-sha is empty; pass the commit to compare against"
  git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null ||
    cannot "commit $BASE_SHA is not in the clone; check out with fetch-depth: 0 (or 2 on a PR merge commit)"
  base="$tmp/base"
  worktree="$base"
  # LFS objects are not part of a Go API, and a checkout without LFS
  # credentials cannot fetch them.
  GIT_LFS_SKIP_SMUDGE=1 git worktree add --quiet --detach "$base" "$BASE_SHA"
  echo "api-break: base $BASE_SHA, head $(git rev-parse HEAD)"
fi

# --- helpers -----------------------------------------------------------------

# public_pkgs prints the public packages of the module in the current
# directory, one import path per line. Public: not main, not under internal/,
# no load error (in the package or in one it imports, since apidiff cannot
# type-check a package whose import is broken), and not an exclude-deps path or a dependent of one. It
# writes the packages with a load error to the file $1, so the caller can
# fail closed on them.
public_pkgs() {
  local errs="$1" list
  list="$(go list -e -f '{{if ne .Name "main"}}{{.ImportPath}} {{if or .Error .DepsErrors}}ERROR{{else}}OK{{end}} {{join .Deps " "}}{{end}}' ./...)" || return 1
  printf '%s\n' "$list" | awk -v ex="$EXCLUDE_DEPS" -v errs="$errs" '
    BEGIN { n = split(ex, x, " ") }
    function excluded(p,   j) {
      for (j = 1; j <= n; j++) if (p == x[j] || index(p, x[j] "/") == 1) return 1
      return 0
    }
    NF == 0 { next }
    $1 ~ /\/internal(\/|$)/ || $1 ~ /^internal(\/|$)/ { next }
    {
      if (excluded($1)) next
      for (i = 3; i <= NF; i++) if (excluded($i)) next
      if ($2 == "ERROR") { print $1 >errs; next }
      print $1
    }'
}

# qualify PREFIX reads `apidiff -incompatible` output of one package on stdin
# and prints each change line with PREFIX after "- ", so its key names the
# package (see Keys above). Header and blank lines are dropped.
qualify() {
  awk -v p="$1" 'substr($0, 1, 2) == "- " { print "- " p substr($0, 3) }'
}

# norm_dir prints a module directory relative to the repo root, without
# "./" or a trailing "/" ("." for the root). It fails for a directory outside
# the repo, which has no base to compare with. It runs in a subshell, so it
# returns 1 and the caller reports the error.
norm_dir() {
  local d="$1"
  case "$d" in
  /*)
    case "$d/" in
    "$root"/*) d="${d#"$root"}" d="${d#/}" ;;
    *) return 1 ;;
    esac
    ;;
  esac
  while [ "${d#./}" != "$d" ]; do d="${d#./}"; done
  d="${d%/}"
  echo "${d:-.}"
}

# --- the Go surface ----------------------------------------------------------
dirs="${DIRS:-}"
if [ -z "$dirs" ]; then
  dirs="$("$here/../security-detect/find-go-modules.sh")"
fi

report="$tmp/go-report.txt"
echo "Incompatible changes:" >"$report"
n=0
for raw in $dirs; do
  d="$(norm_dir "$raw")" || cannot "module directory $raw is outside the repo"
  [ -f "$root/$d/go.mod" ] || cannot "no go.mod in $d"
  if [ ! -f "$base/$d/go.mod" ]; then
    echo "::notice title=API break gate::$d is a new module (no go.mod in the base); it has no API to break yet"
    continue
  fi
  echo "::group::API of module $d"
  mod="$(cd "$base/$d" && go list -m)" || cannot "go list -m failed in the base of $d"
  # The key prefix of the module's root package and of its other packages.
  if [ "$d" = "." ]; then
    rootpfx="" subpfx="./"
  else
    rootpfx="./$d." subpfx="./$d/"
  fi

  : >"$tmp/errs"
  (cd "$base/$d" && public_pkgs "$tmp/errs") >"$tmp/base-pkgs.txt" ||
    cannot "go list failed in the base of $d"
  if [ -s "$tmp/errs" ]; then
    cannot "these public packages do not load in the base of $d, so their API cannot be read: $(tr '\n' ' ' <"$tmp/errs")"
  fi
  if [ ! -s "$tmp/base-pkgs.txt" ]; then
    cannot "the base of $d has no public package (all main, internal or excluded); refusing to compare nothing. Leave the module out with the directories input."
  fi
  : >"$tmp/errs"
  (cd "$root/$d" && public_pkgs "$tmp/errs") >"$tmp/head-pkgs.txt" ||
    cannot "go list failed in $d"
  echo "api-break: $d ($mod): $(wc -l <"$tmp/base-pkgs.txt") public package(s) in the base"

  while read -r pkg; do
    n=$((n + 1))
    if [ "$pkg" = "$mod" ]; then
      key="${rootpfx%.}" pfx="$rootpfx"
      key="${key:-.}"
    else
      rel="${pkg#"$mod"/}"
      key="$subpfx$rel" pfx="$subpfx$rel."
    fi
    # go list does not type-check, so a type error shows up here, in apidiff.
    (cd "$base/$d" && apidiff -w "$tmp/$n.api" "$pkg") || cannot "apidiff could not load $pkg in the base, so its API cannot be read (does it build?)"
    if ! grep -qxF "$pkg" "$tmp/head-pkgs.txt"; then
      # Not in the head's public list: gone, now main, now broken, or now on
      # an excluded path. Only the first two are API verdicts.
      state="$(cd "$root/$d" && go list -e -f '{{if not .GoFiles}}gone{{else if eq .Name "main"}}main{{else if or .Error .DepsErrors}}error{{else}}excluded{{end}}' "$pkg" 2>/dev/null || echo gone)"
      case "$state" in
      gone) echo "- $key: package removed" >>"$report" ;;
      main) echo "- $key: package became a command (package main)" >>"$report" ;;
      error)
        (cd "$root/$d" && go list -e -f '{{with .Error}}{{.}}{{end}}{{range .DepsErrors}}{{.}}{{"\n"}}{{end}}' "$pkg") || true
        cannot "$pkg does not load in this change, so its API cannot be read; fix the build first"
        ;;
      *) cannot "$pkg now depends on an exclude-deps path ($EXCLUDE_DEPS), so its API cannot be compared" ;;
      esac
      continue
    fi
    (cd "$root/$d" && apidiff -incompatible "$tmp/$n.api" "$pkg") >"$tmp/$n.diff" ||
      cannot "apidiff could not load $pkg in this change, so its API cannot be read; fix the build first"
    qualify "$pfx" <"$tmp/$n.diff" >>"$report"
  done <"$tmp/base-pkgs.txt"
  echo "::endgroup::"
done
args=(-go-report "$report")

# --- other surfaces ------------------------------------------------------------
if [ -n "$SURFACE_SCRIPT" ]; then
  script="$root/$SURFACE_SCRIPT"
  [ -x "$script" ] || cannot "surface-script $SURFACE_SCRIPT is missing or not executable"
  out="$tmp/surface"
  mkdir -p "$out"
  echo "::group::surface-script $SURFACE_SCRIPT"
  "$script" "$base" "$root" "$out" || cannot "surface-script $SURFACE_SCRIPT failed"
  echo "::endgroup::"
  # Each surface needs both sides: one side alone cannot be compared, and
  # reading it as "no surface" would hide every break in it.
  for s in lisp golden; do
    if [ "$s" = lisp ]; then b="$out/lisp-base.json" h="$out/lisp-head.json"; else b="$out/golden-base" h="$out/golden-head"; fi
    if [ -e "$b" ] && [ -e "$h" ]; then
      args+=("-$s-base" "$b" "-$s-head" "$h")
    elif [ -e "$b" ] || [ -e "$h" ]; then
      cannot "surface-script wrote only one side of the $s surface; it must write both"
    fi
  done
fi

# --- judge -----------------------------------------------------------------------
overrides="$OVERRIDES"
if [ ! -f "$root/$OVERRIDES" ]; then
  # An empty file waives nothing, so a missing file can only make the gate
  # stricter.
  echo "::notice title=API break gate::no overrides file at $OVERRIDES; no break is waived"
  overrides="$tmp/no-overrides.txt"
  : >"$overrides"
fi

trap - ERR
set +e
apibreak -overrides "$overrides" "${args[@]}"
rc=$?
set -e
case "$rc" in
0) ;;
1) echo "::error title=API break gate: unwaived breaking change::add the printed line to $OVERRIDES with an issue, expiry and reason, or undo the break" ;;
*) echo "::error title=API break gate could not judge::apibreak exited $rc; read the lines above" ;;
esac
exit "$rc"
