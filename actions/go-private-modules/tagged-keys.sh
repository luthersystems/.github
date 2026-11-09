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
# Input: KEYS, the secret. Writes the output tagged=true to $GITHUB_OUTPUT
# (stdout when it is unset) when KEYS has a tagged key, and tagged=false (and
# changes nothing) when it has none. Mixed input, with a
# key that has no tag line, fails: the untagged key would read no
# repository.
#
# SSH_HOME (default ~/.ssh) is where the files go; the tests set it.
set -euo pipefail

ssh_home="${SSH_HOME:-$HOME/.ssh}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
tag_re='^# git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git$'

if ! grep -Eq "$tag_re" <<<"${KEYS:-}"; then
  echo "tagged=false" >>"$out"
  exit 0
fi

mkdir -p "$ssh_home"
chmod 700 "$ssh_home"

# GitHub's published host keys (docs.github.com, "GitHub's SSH key
# fingerprints"). The aliases check the server against these, as
# webfactory/ssh-agent does for github.com.
known="$ssh_home/known_hosts"
cat >>"$known" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF

n=0
repo=""
file=""
in_key=false
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ $tag_re ]]; then
    if $in_key; then
      echo "::error::a tag line is inside a key: the key before it has no END line"
      exit 1
    fi
    repo="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" == "-----BEGIN "*" PRIVATE KEY-----" ]]; then
    if [ -z "$repo" ]; then
      echo "::error::a key has no tag line before it (# git@github.com:owner/repo.git)"
      exit 1
    fi
    n=$((n + 1))
    file="$ssh_home/key-$n"
    : >"$file"
    chmod 600 "$file"
    in_key=true
  fi
  if $in_key; then
    printf '%s\n' "$line" >>"$file"
    if [[ "$line" == "-----END "*" PRIVATE KEY-----" ]]; then
      host="key-$n.github.com"
      cat >>"$ssh_home/config" <<EOF

Host $host
  HostName github.com
  User git
  IdentityFile $file
  IdentitiesOnly yes
  HostKeyAlias github.com
  UserKnownHostsFile $known
EOF
      # Both URL forms that go and git use for a GOPRIVATE module.
      git config --global --add "url.git@$host:$repo.insteadOf" "https://github.com/$repo"
      git config --global --add "url.git@$host:$repo.insteadOf" "git@github.com:$repo"
      echo "key $n reads $repo" >&2
      repo=""
      in_key=false
    fi
  elif [ -n "$line" ]; then
    echo "::error::text outside a key that is not a tag line"
    exit 1
  fi
done <<<"$KEYS"

if $in_key; then
  echo "::error::the last key has no END line"
  exit 1
fi
if [ -n "$repo" ]; then
  echo "::error::a tag line has no key after it"
  exit 1
fi
echo "tagged=true" >>"$out"
