#!/usr/bin/env bash
# Tests actions/go-private-modules/tagged-keys.sh: keys tagged with their
# repository get their own SSH host alias and git URL rewrite, untagged
# input changes nothing, and malformed input fails and writes nothing.
#
# Needs on PATH: bash, git; ssh for the "ssh reads the alias" check (it is
# skipped without ssh). The keys are fake text: the script only copies them.
# Run from the repo root: tests/security/tagged-keys-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/actions/go-private-modules/tagged-keys.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}

key() {
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$1"
}

tag() {
  printf '# git@github.com:%s.git\n' "$1"
}

# run <case> <keys>: runs the script in the case's own key dir and git
# config. A second run of one case uses the same files.
run() {
  local d="$work/$1"
  mkdir -p "$d"
  touch "$d/gitconfig"
  KEY_DIR="$d/keys" GIT_CONFIG_GLOBAL="$d/gitconfig" GITHUB_OUTPUT="$d/out" GITHUB_ENV="$d/env" KEYS="$2" \
    bash "$script" >"$d/log" 2>&1
}

url() {
  GIT_CONFIG_GLOBAL="$work/$1/gitconfig" git ls-remote --get-url "$2"
}

# expect_fail <case> <reason pattern> <keys>
expect_fail() {
  if run "$1" "$3"; then
    fail "$1: passed"
  fi
  grep -q "$2" "$work/$1/log" || fail "$1: wrong reason: $(cat "$work/$1/log")"
  [ -e "$work/$1/keys" ] && fail "$1: wrote key files"
  [ -s "$work/$1/gitconfig" ] && fail "$1: changed git config"
}

sub=key-luthersystems--substrate
lic=key-luthersystems--license

# Pass: two tagged keys, each on its own alias.
keys="$(tag luthersystems/substrate)
$(key substrate-secret)
$(tag luthersystems/license)
$(key license-secret)"
if run two "$keys"; then
  d="$work/two"
  grep -qx 'tagged=true' "$d/out" || fail "two: no tagged=true"
  grep -qx "GIT_SSH_COMMAND=ssh -F $d/keys/config" "$d/env" || fail "two: no GIT_SSH_COMMAND"
  grep -qx 'substrate-secret' "$d/keys/$sub" || fail "two: the substrate key file"
  grep -qx 'license-secret' "$d/keys/$lic" || fail "two: the license key file"
  [ "$(stat -c %a "$d/keys/$sub")" = 600 ] || fail "two: key file is not mode 600"
  grep -q '^# git@' "$d/keys/$sub" && fail "two: the tag line is in the key file"
  [ "$(url two https://github.com/luthersystems/substrate)" = "git@$sub.github.com:luthersystems/substrate" ] ||
    fail "two: substrate's https URL"
  [ "$(url two git@github.com:luthersystems/license)" = "git@$lic.github.com:luthersystems/license" ] ||
    fail "two: license's ssh URL"
  grep -q 'secret' "$d/log" && fail "two: the log shows key text"
  if command -v ssh >/dev/null; then
    # ssh reads the alias from the -F file, whatever HOME is.
    g="$(HOME=/nonexistent ssh -F "$d/keys/config" -G "$sub.github.com")"
    grep -qx 'hostname github.com' <<<"$g" || fail "two: ssh -G hostname"
    grep -qx "identityfile $d/keys/$sub" <<<"$g" || fail "two: ssh -G identityfile"
    grep -qx 'identitiesonly yes' <<<"$g" || fail "two: ssh -G identitiesonly"
  else
    echo "skip: no ssh for the ssh -G check"
  fi
else
  fail "two: the script failed: $(cat "$work/two/log")"
fi

# Pass: CRLF line endings, as a secret pasted from Windows has.
if run crlf "$(printf '%s\n' "$keys" | sed 's/$/\r/')"; then
  grep -qx 'tagged=true' "$work/crlf/out" || fail "crlf: no tagged=true"
  grep -q $'\r' "$work/crlf/keys/$sub" && fail "crlf: CR in the key file"
else
  fail "crlf: the script failed: $(cat "$work/crlf/log")"
fi

# Pass: a second run in the same job replaces the key of a repository it
# names again, adds one it did not, and keeps the first run's rules.
if run rerun "$(tag luthersystems/substrate)
$(key old-substrate)" && run rerun "$(tag luthersystems/substrate)
$(key new-substrate)
$(tag luthersystems/license)
$(key license-secret)"; then
  d="$work/rerun"
  grep -qx 'new-substrate' "$d/keys/$sub" || fail "rerun: the substrate key was not replaced"
  [ "$(grep -c "^Host $sub.github.com$" "$d/keys/config")" = 1 ] || fail "rerun: two Host blocks for substrate"
  [ "$(GIT_CONFIG_GLOBAL="$d/gitconfig" git config --global --get-all "url.git@$sub.github.com:luthersystems/substrate.insteadOf" | wc -l)" = 2 ] ||
    fail "rerun: duplicate insteadOf"
  [ "$(url rerun https://github.com/luthersystems/license)" = "git@$lic.github.com:luthersystems/license" ] ||
    fail "rerun: license's URL"
else
  fail "rerun: the script failed: $(cat "$work/rerun/log")"
fi

# Pass: one untagged key is left to webfactory/ssh-agent.
if run plain "$(key plain-secret)"; then
  grep -qx 'tagged=false' "$work/plain/out" || fail "plain: no tagged=false"
  [ -e "$work/plain/keys" ] && fail "plain: wrote key files"
  [ -s "$work/plain/gitconfig" ] && fail "plain: changed git config"
else
  fail "plain: the script failed"
fi

expect_fail mixed 'has no tag line' "$(tag luthersystems/substrate)
$(key a)
$(key b)"
expect_fail dangling 'no key after it' "$(tag luthersystems/substrate)
$(key a)
$(tag luthersystems/license)"
expect_fail noend 'no END line' "$(tag luthersystems/substrate)
-----BEGIN OPENSSH PRIVATE KEY-----
abc"
expect_fail nested 'starts inside a key' "$(tag luthersystems/substrate)
-----BEGIN OPENSSH PRIVATE KEY-----
aaa
$(key b)"
expect_fail junk 'outside a key' "hello
$(tag luthersystems/substrate)
$(key a)"
expect_fail prefix 'would also catch' "$(tag luthersystems/license)
$(key a)
$(tag luthersystems/license-tools)
$(key b)"
expect_fail dup 'two keys are tagged' "$(tag luthersystems/license)
$(key a)
$(tag luthersystems/license)
$(key b)"

if [ "$fails" -gt 0 ]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all tagged-key cases pass"
