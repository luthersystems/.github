#!/usr/bin/env bash
# Writes the commands the agent runs, into BIN (put on PATH):
#
#   security-gate-govulncheck    the govulncheck gate, as the scan ran it
#   security-gate-dependencies   the osv-scanner gate, as the scan ran it
#   run-untrusted CMD...         CMD with no credentials in its environment
#
# Why the gate commands: the agent must see exactly what the gate saw, the
# same modules, exemptions, excludes and fail rule. A plain
# `osv-scanner scan source -r .` or `govulncheck ./...` reports findings the
# gate exempts or leaves out, and the agent would then "fix" those.
#
# Why run-untrusted: a bump downloads code, and building and testing it runs
# that code in this job, which holds the OIDC request token (Bedrock, Claude
# App), the AWS credentials and the deploy key's ssh-agent. run-untrusted
# runs a command with only an allowlist of variables, so that code does not
# find them in its environment. It is not a sandbox: the code runs as the
# same user, so it could still read the agent's /proc/<pid>/environ, find
# the ssh-agent socket, or read the App token in the git remote. A real
# boundary (another user, or a job with no credentials) is a later step;
# this removes the easy path, the one a careless package would take.
#
# Env: BIN, ACTIONS_DIR (this repo's actions/), DIRS, EXEMPTIONS, EXCLUDE.
set -euo pipefail

: "${BIN:?}" "${ACTIONS_DIR:?}"
mkdir -p "$BIN"

# printf %q quotes each value so the written script holds it as data.
{
  echo '#!/usr/bin/env bash'
  printf 'export DIRS=%q EXEMPTIONS=%q BINARY=true\n' "${DIRS:-}" "${EXEMPTIONS:-}"
  printf 'exec bash %q "$@"\n' "$ACTIONS_DIR/govulncheck/govulncheck.sh"
} >"$BIN/security-gate-govulncheck"

{
  echo '#!/usr/bin/env bash'
  printf 'export SKIP_GO=true EXCLUDE=%q\n' "${EXCLUDE:-}"
  printf 'exec bash %q "$@"\n' "$ACTIONS_DIR/osv-scan/osv-scan.sh"
} >"$BIN/security-gate-dependencies"

cat >"$BIN/run-untrusted" <<'SH'
#!/usr/bin/env bash
# Runs a command with an allowlist of environment variables: no OIDC
# request token, AWS credentials, GitHub tokens or ssh-agent socket.
set -euo pipefail
keep=(PATH HOME LANG TMPDIR CI RUNNER_TEMP GOTOOLCHAIN GOFLAGS GOPRIVATE GOPATH GOMODCACHE GOCACHE GIT_LFS_SKIP_SMUDGE NODE_OPTIONS)
args=()
for v in "${keep[@]}"; do
  [ -n "${!v+x}" ] && args+=("$v=${!v}")
done
exec env -i "${args[@]}" "$@"
SH

chmod +x "$BIN"/security-gate-govulncheck "$BIN"/security-gate-dependencies "$BIN"/run-untrusted
echo "$BIN" >>"${GITHUB_PATH:-/dev/null}"
