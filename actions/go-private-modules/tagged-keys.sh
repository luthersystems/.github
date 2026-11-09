#!/usr/bin/env bash
# Sets up SSH keys that each name the one repository they read, so that a
# job can hold one deploy key per private module.
#
# Why: a deploy key reads one repository. A repo whose private modules are in
# two repositories (libmxf reads substrate, and substrate reads license) needs
# two keys. webfactory/ssh-agent picks a key per repository by the key's
# comment, but a key that Terraform makes (common-infrastructure
# github-org-admin/deploy_keys.tf) has no comment, and Terraform cannot set
# one. So Terraform writes a line before each key that names its repository:
#
#   # git@github.com:luthersystems/substrate.git
#   -----BEGIN OPENSSH PRIVATE KEY-----
#   ...
#   -----END OPENSSH PRIVATE KEY-----
#
# For each such key this writes the key to a file, an SSH host alias that
# uses only that file, and a git insteadOf that sends that repository's URL
# to the alias. Git uses the longest insteadOf that matches, so these win
# over the action's general git@github.com: rule.
#
# Where: the keys and the SSH config go in $RUNNER_TEMP, which the runner
# empties after each job, so no key outlives the job, also on a self-hosted
# runner whose HOME is kept. git finds the config through GIT_SSH_COMMAND
# ("ssh -F"), written to $GITHUB_ENV: ssh reads ~/.ssh from the passwd home,
# not $HOME, so in a container job a file under $HOME/.ssh is not read.
#
# Input: KEYS, the secret. Writes the output tagged=true to $GITHUB_OUTPUT
# (stdout when it is unset) when KEYS has a tagged key, and tagged=false (and
# changes nothing) when it has none. Input with a key that has no tag line,
# a key with no END line, or other text fails.
#
# Limits: no SSH agent is started (webfactory/ssh-agent is not run), so a
# later step that needs SSH_AUTH_SOCK (docker build --ssh) gets none. A git
# insteadOf matches by prefix, so a tag for owner/license also catches
# owner/license-tools; two tags where one is a prefix of the other fail.
#
# KEY_DIR (default $RUNNER_TEMP/go-private-modules) is where the files go;
# the tests set it. A second run in one job adds to the same files.
set -euo pipefail

key_dir="${KEY_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is not set}/go-private-modules}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
envf="${GITHUB_ENV:-/dev/null}"
tag_re='^# git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git$'

keys="${KEYS:-}"
keys="${keys//$'\r'/}"

if ! grep -Eq "$tag_re" <<<"$keys"; then
  echo "tagged=false" >>"$out"
  exit 0
fi

err() {
  echo "::error::$*"
  exit 1
}

# Parse first, write after: malformed input changes nothing.
repos=()
blocks=()
repo=""
block=""
in_key=false
while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ $tag_re ]]; then
    $in_key && err "a tag line is inside a key: the key before it has no END line"
    [ -n "$repo" ] && err "a tag line has no key after it"
    repo="${BASH_REMATCH[1]}"
  elif [[ "$line" == "-----BEGIN "*" PRIVATE KEY-----" ]]; then
    $in_key && err "a key starts inside a key: the key before it has no END line"
    [ -n "$repo" ] || err "a key has no tag line before it (# git@github.com:owner/repo.git)"
    in_key=true
    block="$line"$'\n'
  elif $in_key; then
    block+="$line"$'\n'
    if [[ "$line" == "-----END "*" PRIVATE KEY-----" ]]; then
      repos+=("$repo")
      blocks+=("$block")
      repo=""
      in_key=false
    fi
  elif [ -n "$line" ]; then
    err "text outside a key that is not a tag line"
  fi
done <<<"$keys"
$in_key && err "the last key has no END line"
[ -n "$repo" ] && err "a tag line has no key after it"

for a in "${repos[@]}"; do
  for b in "${repos[@]}"; do
    if [ "$a" = "$b" ]; then
      continue
    fi
    if [[ "$b" == "$a"* ]]; then
      err "the tags $a and $b: a git insteadOf for $a would also catch $b"
    fi
  done
done
dups="$(printf '%s\n' "${repos[@]}" | sort | uniq -d)"
[ -z "$dups" ] || err "two keys are tagged ${dups%%$'\n'*}"

mkdir -p "$key_dir"
chmod 700 "$key_dir"
config="$key_dir/config"
known="$key_dir/known_hosts"

# GitHub's published host keys (docs.github.com, "GitHub's SSH key
# fingerprints"), as webfactory/ssh-agent pins them for github.com.
cat >"$known" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF

for i in "${!repos[@]}"; do
  repo="${repos[$i]}"
  # One name per repository, so a second run for the same repository
  # replaces its key and alias, and one for another repository adds to them.
  name="key-${repo//\//--}"
  host="$name.github.com"
  file="$key_dir/$name"
  (umask 077 && printf '%s' "${blocks[$i]}" >"$file")
  if ! grep -qx "Host $host" "$config" 2>/dev/null; then
    cat >>"$config" <<EOF
Host $host
  HostName github.com
  User git
  IdentityFile $file
  IdentitiesOnly yes
  HostKeyAlias github.com
  UserKnownHostsFile $known
  StrictHostKeyChecking yes

EOF
  fi
  # Both URL forms that go and git use for a GOPRIVATE module.
  for from in "https://github.com/$repo" "git@github.com:$repo"; do
    # The value pattern of --replace-all is a regex: escape the dots.
    git config --global --replace-all "url.git@$host:$repo.insteadOf" "$from" "^${from//./\\.}\$"
  done
  echo "a key reads $repo" >&2
done

echo "GIT_SSH_COMMAND=ssh -F $config" >>"$envf"
echo "tagged=true" >>"$out"
