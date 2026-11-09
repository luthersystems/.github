#!/usr/bin/env bash
# Tests actions/go-private-modules/tagged-keys.sh: keys tagged with their
# repository get their own SSH host alias and git URL rewrite, untagged
# input changes nothing, and malformed input fails.
#
# Needs on PATH: bash, git. The keys are fake text: the script does not read
# them, it only copies them.
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

# run <case dir> <keys>: runs the script in a fresh SSH and git home.
run() {
  local d="$work/$1"
  mkdir -p "$d"
  : >"$d/gitconfig"
  SSH_HOME="$d/ssh" GIT_CONFIG_GLOBAL="$d/gitconfig" GITHUB_OUTPUT="$d/out" KEYS="$2" \
    bash "$script" >"$d/log" 2>&1
}

url() {
  GIT_CONFIG_GLOBAL="$work/$1/gitconfig" git ls-remote --get-url "$2"
}

# Pass: two tagged keys, each on its own alias.
keys="# git@github.com:luthersystems/substrate.git
$(key substrate-secret)
# git@github.com:luthersystems/license.git
$(key license-secret)"
if run two "$keys"; then
  d="$work/two"
  grep -qx 'tagged=true' "$d/out" || fail "two: no tagged=true"
  grep -qx 'substrate-secret' "$d/ssh/key-1" || fail "two: key-1 is not the substrate key"
  grep -qx 'license-secret' "$d/ssh/key-2" || fail "two: key-2 is not the license key"
  [ "$(stat -c %a "$d/ssh/key-1")" = 600 ] || fail "two: key-1 is not mode 600"
  grep -q '^# git@' "$d/ssh/key-1" && fail "two: the tag line is in the key file"
  [ "$(url two https://github.com/luthersystems/substrate)" = "git@key-1.github.com:luthersystems/substrate" ] ||
    fail "two: substrate's https URL is not on key-1"
  [ "$(url two git@github.com:luthersystems/license)" = "git@key-2.github.com:luthersystems/license" ] ||
    fail "two: license's ssh URL is not on key-2"
  grep -q 'IdentitiesOnly yes' "$d/ssh/config" || fail "two: no IdentitiesOnly"
  grep -q 'HostKeyAlias github.com' "$d/ssh/config" || fail "two: no HostKeyAlias"
  grep -q '^github.com ssh-ed25519 ' "$d/ssh/known_hosts" || fail "two: no pinned host key"
  grep -q 'secret' "$d/log" && fail "two: the log shows key text"
else
  fail "two: the script failed: $(cat "$work/two/log")"
fi

# Pass: one untagged key is left to webfactory/ssh-agent.
if run plain "$(key plain-secret)"; then
  grep -qx 'tagged=false' "$work/plain/out" || fail "plain: no tagged=false"
  [ -e "$work/plain/ssh" ] && fail "plain: wrote SSH files"
  [ -s "$work/plain/gitconfig" ] && fail "plain: changed git config"
else
  fail "plain: the script failed"
fi

# Fail: a key with no tag line among tagged ones.
run mixed "# git@github.com:luthersystems/substrate.git
$(key a)
$(key b)" && fail "mixed: passed"
grep -q 'has no tag line' "$work/mixed/log" || fail "mixed: wrong reason: $(cat "$work/mixed/log")"

# Fail: a tag line with no key after it.
run dangling "$(printf '# git@github.com:luthersystems/substrate.git\n%s\n# git@github.com:luthersystems/license.git' "$(key a)")" &&
  fail "dangling: passed"
grep -q 'no key after it' "$work/dangling/log" || fail "dangling: wrong reason"

# Fail: a key with no END line.
run noend "$(printf '# git@github.com:luthersystems/substrate.git\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc')" &&
  fail "noend: passed"
grep -q 'no END line' "$work/noend/log" || fail "noend: wrong reason"

# Fail: other text outside a key.
run junk "$(printf 'hello\n# git@github.com:luthersystems/substrate.git\n%s' "$(key a)")" && fail "junk: passed"
grep -q 'outside a key' "$work/junk/log" || fail "junk: wrong reason"

if [ "$fails" -gt 0 ]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all tagged-key cases pass"
