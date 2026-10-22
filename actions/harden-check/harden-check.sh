#!/usr/bin/env bash
# Driver of the harden-check action (action.yml): read the inputs, get the
# policy from the pinned build-harden kit, then run check/dockerfile.sh on
# the Dockerfiles and check/image.sh on each image and platform.
#
# Why a script and not steps in action.yml: the logic (kit resolution, the
# image list, installing host tools only when an image needs them) can then
# be linted with shellcheck and run by hand, and action.yml stays a thin
# shim. Each repo used to carry its own copy of this glue; this is the one
# copy.
#
# Inputs come from the environment, set by action.yml:
#   HC_KIT              kit image, luthersystems/build-harden:<tag>@sha256:<digest>
#                       (empty: read it from the Dockerfiles)
#   HC_DOCKERFILES      Dockerfiles or directories, one per line or space
#   HC_SAME_KIT         files that must pin the kit checked (no Dockerfile
#                       check), one per line or space
#   HC_IMAGES           one image per line: REF, or REF PLATFORM
#   HC_PLATFORMS        platforms for an image line with no platform
#   HC_MIN_ROOTS        passed to image.sh --min-roots
#   HC_STRICT_BINARIES  true: pass --strict-binaries
#   HC_ALLOW            path globs, one per line: passed as --allow
#   HC_INSTALL_TOOLS    true: install openssl, certutil and keytool with apt
#                       when the host lacks one that the check needs
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

die() {
	echo "::error::harden-check: $*" >&2
	exit 2
}

# words TEXT: the whitespace-separated words of TEXT, one per line.
words() { tr -s '[:space:]' '\n' <<<"$1" | sed '/^$/d'; }

kit_re='^luthersystems/build-harden:[^[:space:]@]+@sha256:[0-9a-f]{64}$'

dockerfiles=()
while IFS= read -r f; do dockerfiles+=("$f"); done < <(words "${HC_DOCKERFILES:-}")
same_kit=()
while IFS= read -r f; do same_kit+=("$f"); done < <(words "${HC_SAME_KIT:-}")
image_lines=()
while IFS= read -r l; do
	l=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$l")
	[ -n "$l" ] && image_lines+=("$l")
done <<<"${HC_IMAGES:-}"
platforms=()
while IFS= read -r p; do platforms+=("$p"); done < <(words "${HC_PLATFORMS:-}")
[ "${#dockerfiles[@]}" -gt 0 ] || [ "${#image_lines[@]}" -gt 0 ] || die "set dockerfiles, images or both"

# Check every input before any work, so a typo fails at once.
[[ ${HC_MIN_ROOTS:-100} =~ ^[0-9]+$ ]] || die "min-roots must be a whole number, not '${HC_MIN_ROOTS}'"
case ${HC_STRICT_BINARIES:-false} in true | false) ;; *) die "strict-binaries must be true or false, not '${HC_STRICT_BINARIES}'" ;; esac
case ${HC_INSTALL_TOOLS:-true} in true | false) ;; *) die "install-tools must be true or false, not '${HC_INSTALL_TOOLS}'" ;; esac
for line in "${image_lines[@]}"; do
	read -r _ _ extra <<<"$line"
	[ -z "${extra:-}" ] || die "image line '$line': want REF or REF PLATFORM"
done
check_args=(--min-roots "${HC_MIN_ROOTS:-100}")
[ "${HC_STRICT_BINARIES:-false}" = false ] || check_args+=(--strict-binaries)
while IFS= read -r a; do
	a=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$a")
	[ -n "$a" ] && check_args+=(--allow "$a")
done <<<"${HC_ALLOW:-}"

# The Dockerfiles' kits: the build-harden stages they pin. The image check
# must read the policy of the kit that hardened the image, so a Dockerfile
# that pins another kit than the one checked fails.
for f in "${dockerfiles[@]}" "${same_kit[@]}"; do
	[ -e "$f" ] || die "$f: no such file or directory"
done
# dockerfile.sh parses the Dockerfiles (comments, continued lines, which
# files of a directory count), so the kit found here is the one it checks.
df_kits=()
if [ "${#dockerfiles[@]}" -gt 0 ]; then
	kits_out=$(bash "$here/check/dockerfile.sh" --list-kits "${dockerfiles[@]}") || die "cannot read the Dockerfiles: $kits_out"
	while IFS= read -r k; do df_kits+=("$k"); done <<<"$kits_out"
fi
mapfile -t df_kits < <(printf '%s\n' "${df_kits[@]}" | sed '/^$/d' | sort -u)

kit=${HC_KIT:-}
if [ -z "$kit" ]; then
	[ "${#df_kits[@]}" -gt 0 ] || die "set the kit input: no Dockerfile given pins a luthersystems/build-harden stage"
	[ "${#df_kits[@]}" -eq 1 ] || die "the Dockerfiles pin more than one kit (${df_kits[*]}); pin one, or check them in separate steps"
	kit=${df_kits[0]}
fi
# A tag alone can move; the digest makes the policy the one reviewed.
[[ $kit =~ $kit_re ]] || die "kit '$kit' is not luthersystems/build-harden:<tag>@sha256:<digest>"
for k in "${df_kits[@]}"; do
	[ "$k" = "$kit" ] || die "a Dockerfile pins $k, but the kit checked is $kit"
done
# The same-kit files: each must pin exactly the kit checked. Why: a file
# such as connectorhub's Dockerfile-go hardens an earlier stage and ships a
# hardened base image, so the Dockerfile check (final stage only) cannot
# take it. Without this, a kit bump that misses the file goes unseen.
for f in "${same_kit[@]}"; do
	[ -f "$f" ] || die "same-kit: $f is not a file"
	got=$(bash "$here/check/dockerfile.sh" --list-kits "$f") || die "cannot read $f: $got"
	got=$(sed '/^$/d' <<<"$got" | sort -u)
	[ -n "$got" ] || die "same-kit: $f pins no luthersystems/build-harden stage"
	[ "$got" = "$kit" ] || die "same-kit: $f pins $(paste -sd ' ' - <<<"$got"), but the kit checked is $kit"
done
echo "kit: $kit"

# Get the policy out of the kit. The kit is FROM scratch, so docker create
# needs no command that runs; it is never started.
work=$(mktemp -d -p "$tmp" harden-check.XXXXXX)
kcid=
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
cleanup() {
	[ -z "$kcid" ] || docker rm -f "$kcid" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT
kcid=$(docker create "$kit" /nonexistent) || die "cannot pull $kit"
docker cp "$kcid:/harden/policy" "$work/policy" >/dev/null || die "$kit has no /harden/policy"
docker rm -f "$kcid" >/dev/null
kcid=

fail=0
echo "## build-harden check" >>"$summary"
echo "Kit: \`$kit\`" >>"$summary"

if [ "${#dockerfiles[@]}" -gt 0 ]; then
	if bash "$here/check/dockerfile.sh" "${dockerfiles[@]}"; then
		echo "- Dockerfiles: ok (${dockerfiles[*]})" >>"$summary"
	else
		echo "- Dockerfiles: **FAIL** (${dockerfiles[*]})" >>"$summary"
		fail=1
	fi
fi

# apt_install PKG...: install host tools, only on a host that has apt.
apt_install() {
	[ "${HC_INSTALL_TOOLS:-true}" = true ] || return 1
	command -v apt-get >/dev/null || return 1
	local sudo=
	[ "$(id -u)" -eq 0 ] || sudo=sudo
	$sudo apt-get update -qq && $sudo apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}
for t in openssl python3; do
	command -v "$t" >/dev/null || apt_install "$t" || true
done

# check_image REF PLATFORM: run image.sh. keytool and certutil are installed
# only when image.sh says the image needs them (exit 3: keytool, 4:
# certutil), so an image with no Java keystore and no NSS database skips the
# apt work. image.sh asks before it scans, so a retry costs one export.
check_image() {
	local ref=$1 platform=$2 rc
	for _ in 1 2 3; do
		rc=0
		bash "$here/check/image.sh" --policy "$work/policy" "${check_args[@]}" ${platform:+--platform "$platform"} "$ref" 2>&1 || rc=$?
		case $rc in
		3) apt_install default-jre-headless || return 2 ;;
		4) apt_install libnss3-tools || return 2 ;;
		*) return "$rc" ;;
		esac
	done
	return 2
}

for line in "${image_lines[@]}"; do
	read -r ref lplat <<<"$line"
	if [ -n "${lplat:-}" ]; then
		plats=("$lplat")
	elif [ "${#platforms[@]}" -gt 0 ]; then
		plats=("${platforms[@]}")
	else
		plats=("")
	fi
	for p in "${plats[@]}"; do
		echo "::group::image check: $ref${p:+ ($p)}"
		# An image the daemon does not hold is pulled by the check. Remove it
		# after, so the next platform pulls its own copy: the classic image
		# store keeps one platform per digest and refuses a second pull of
		# the same digest ("cannot overwrite digest"). An image built into
		# the daemon is the caller's and is kept.
		pulled=0
		docker image inspect "$ref" >/dev/null 2>&1 || pulled=1
		rc=0
		check_image "$ref" "$p" || rc=$?
		[ "$pulled" = 0 ] || docker image rm -f "$ref" >/dev/null 2>&1 || true
		echo "::endgroup::"
		case $rc in
		0) echo "- \`$ref\`${p:+ ($p)}: ok" >>"$summary" ;;
		1)
			echo "::error::harden-check: $ref${p:+ ($p)} does not hold the build-harden policy"
			echo "- \`$ref\`${p:+ ($p)}: **FAIL**" >>"$summary"
			fail=1
			;;
		*)
			echo "::error::harden-check: could not check $ref${p:+ ($p)} (exit $rc)"
			echo "- \`$ref\`${p:+ ($p)}: **ERROR** (exit $rc)" >>"$summary"
			# A check that could not run must not pass as clean.
			[ "$fail" -ne 0 ] || fail=2
			;;
		esac
	done
done
exit "$fail"
