#!/usr/bin/env bash
# Tests of check/dockerfile.sh that need no docker (ci.yml runs it).
#
# Why: the Dockerfile check decides which steps may follow the kit, and the
# action reads the kit from it (--list-kits). Each case pins the exit code,
# so a check that passes everything, or fails everything, turns CI red.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check=$here/../../actions/harden-check/check/dockerfile.sh
d=$here/dockerfiles
kit=luthersystems/build-harden:v0.1.46@sha256:f3c02942cf086e8b976f0bf3e7a089bd29efdb34e788f0eaad64f38db76d4c05
rc_all=0

# expect NAME CODE ARGS...: dockerfile.sh ARGS exits CODE.
expect() {
	local name=$1 want=$2 rc=0
	shift 2
	bash "$check" "$@" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq "$want" ]; then
		echo "ok: $name (exit $rc)"
	else
		echo "::error::$name: want exit $want, got $rc"
		bash "$check" "$@" || true
		rc_all=1
	fi
}

expect "CMD and HEALTHCHECK after the kit" 0 "$d/pass-cmd-after.Dockerfile"
expect "a package step after the kit" 1 "$d/fail-run-after.Dockerfile"
expect "a package step in a RUN heredoc after the kit" 1 "$d/fail-heredoc-after.Dockerfile"
expect "a lowercase run after the kit" 1 "$d/fail-lowercase-after.Dockerfile"
expect "a heredoc line that starts with env" 1 "$d/fail-env-heredoc-after.Dockerfile"
expect "a lowercase copy --from after the kit" 1 "$d/fail-lowercase-copy-after.Dockerfile"
expect "a lowercase from final stage" 1 "$d/fail-lowercase-from.Dockerfile"
expect "a local COPY after the kit" 0 "$d/pass-copy-after.Dockerfile"
expect "an indented RUN after the kit" 1 "$d/fail-indented-run-after.Dockerfile"
expect "a << in a CMD, then COPY --from" 1 "$d/fail-cmd-heredoc-after.Dockerfile"
expect "CRLF line endings" 0 "$d/pass-crlf.Dockerfile"
expect "a heredoc that fakes the kit RUN" 1 "$d/fail-fake-kit-in-heredoc.Dockerfile"
expect "the fixture Dockerfiles" 0 "$here/nss-other-nickname" "$here/chrome-no-nssdb"

got=$(bash "$check" --list-kits "$d/pass-cmd-after.Dockerfile")
if [ "$got" = "$kit" ]; then
	echo "ok: --list-kits joins a continued FROM line"
else
	echo "::error::--list-kits: want $kit, got '$got'"
	rc_all=1
fi

exit "$rc_all"
