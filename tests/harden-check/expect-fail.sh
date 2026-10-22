#!/usr/bin/env bash
# The cases of the harden-check action that must fail (ci.yml runs it).
#
# Why each case checks the exit code and a line of the output: a failure for
# another reason (a pull error, a bug in the script) must not count as the
# check working. Each case sets the inputs as action.yml does (HC_*) and runs
# harden-check.sh. KIT is set by ci.yml.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../../actions/harden-check/harden-check.sh
kit=${KIT:?}
rc_all=0

# expect NAME CODE PATTERN VAR=VALUE...: run the script with the inputs, and
# want exit CODE and a line that matches PATTERN (grep -E).
expect() {
	local name=$1 want=$2 pattern=$3 log rc=0
	shift 3
	log=$(mktemp)
	env HC_KIT= HC_DOCKERFILES= HC_IMAGES= HC_PLATFORMS= HC_ALLOW= "$@" bash "$script" >"$log" 2>&1 || rc=$?
	if [ "$rc" -eq "$want" ] && grep -qE -- "$pattern" "$log"; then
		echo "ok: $name (exit $rc)"
	else
		echo "::error::$name: want exit $want and /$pattern/, got exit $rc"
		cat "$log"
		rc_all=1
	fi
	rm -f "$log"
}

expect "an image that trusts the listed CAs" 1 '^FAIL: /etc/ssl/cert.pem: holds ' \
	HC_KIT="$kit" HC_IMAGES="alpine:3.22@sha256:822614ea121e1d40a33655081af10ef85f0aa2ab9e61f649ceaf0c651822433c"

expect "headless-shell with no NSS database (buildenv#165)" 1 'headless-shell: Chrome uses its built-in roots' \
	HC_DOCKERFILES="$here/chrome-no-nssdb" HC_IMAGES="harden-check-test/chrome-no-nssdb"

expect "a Dockerfile that pins another kit" 2 'a Dockerfile pins luthersystems/build-harden:v0.1.45@' \
	HC_KIT="luthersystems/build-harden:v0.1.44@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
	HC_DOCKERFILES="$here/nss-other-nickname"

expect "a kit pinned by tag only" 2 'is not luthersystems/build-harden:<tag>@sha256:<digest>' \
	HC_KIT="luthersystems/build-harden:v0.1.45" HC_IMAGES="alpine:3.22"

expect "no input" 2 'set dockerfiles, images or both'

expect "an image line with three words" 2 "want REF or REF PLATFORM" \
	HC_KIT="$kit" HC_IMAGES="alpine:3.22 linux/amd64 extra"

exit "$rc_all"
