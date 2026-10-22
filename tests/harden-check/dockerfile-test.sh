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
kit=luthersystems/build-harden:v0.1.45@sha256:ed783a0cd4faf6cd791b844970f00309cec76c4ab90b1e111d641ba44d67ba46
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
expect "the fixture Dockerfiles" 0 "$here/nss-other-nickname" "$here/chrome-no-nssdb"

got=$(bash "$check" --list-kits "$d/pass-cmd-after.Dockerfile")
if [ "$got" = "$kit" ]; then
	echo "ok: --list-kits joins a continued FROM line"
else
	echo "::error::--list-kits: want $kit, got '$got'"
	rc_all=1
fi

exit "$rc_all"
