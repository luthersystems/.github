#!/usr/bin/env bash
# Check that a built image holds every build-harden policy.
#
# Why: harden.sh checks its own work while the image builds, but a later
# Dockerfile step (a package upgrade, a COPY --from, a tool that brings its own
# CA bundle) can undo it. This check runs on the finished image, so the
# result is proved on what ships.
#
# How: the image's file system is exported (docker create + docker export, so
# the image needs no shell or tools, and an image of another architecture
# needs no emulation) and every check runs on the host, with the host's
# openssl, keytool and certutil, so a broken tool in the image cannot make it
# pass. For the ca-distrust policy:
#
#   - no PEM file in the image holds a listed certificate (each block's DER
#     sha256 is compared with the list, whatever the file's name or layout);
#   - no listed certificate verifies (openssl verify) against any PEM file in
#     the image, so a leaked intermediate cannot chain to a root that is still
#     trusted, such as one that cross-signed it;
#   - the system bundle still holds at least --min-roots roots (default 100),
#     so an emptied trust store fails instead of passing as clean;
#   - no Java cacerts keystore holds a listed certificate, and each JDK
#     keystore has a lib/security/blocked.certs beside it that blocks every
#     one;
#   - every NSS database distrusts every listed certificate (trust p,p,p).
#
#   - the image's environment points each client with its own root list at
#     the system store: Node (NODE_OPTIONS=--use-openssl-ca and
#     SSL_CERT_FILE), uv
#     (SSL_CERT_FILE, REQUESTS_CA_BUNDLE), and Chrome needs an NSS database;
#   - an image with no system bundle fails (--min-roots 0 allows it);
#   - the positive control: each CA in ca-keep.list (USERTrust, which
#     today's Sectigo chains end at) is still trusted in every store, so a
#     store emptied or stripped too far fails instead of passing as clean.
#
# A binary or program source file that holds a listed certificate, as PEM
# text or as its public key in DER (a built-in root list), is reported, and
# fails with --strict-binaries. The DER search needs python3 on the host.
#
# Usage: image.sh --policy DIR [--platform P] [--min-roots N]
#                 [--strict-binaries] [--allow PATH_GLOB]... IMAGE
# --policy is the policy directory of the kit the image was hardened with
# (/harden/policy in luthersystems/build-harden): the check proves the policy
# that harden.sh applied, so it must read the same list.
# --allow skips a file (in the image's paths) for every check; give the
# reason in the caller, where a reviewer sees it.
# Exit: 0 holds the policy, 1 does not, 2 could not check, 3 the host needs
# keytool, 4 the host needs certutil.
#
# Why this copy is in luthersystems/.github and not only in the kit: a fix to
# the check then reaches every repo through the harden-check@v1 tag, with no
# new kit release and no PR per repo. The policy stays in the kit, so the
# certificates that harden.sh distrusts and the ones checked here are always
# the same list.
set -euo pipefail
# An unexpected failure (a tool that crashes, a full disk) means the image
# could not be checked: exit 2, never 1, which is kept for a policy failure.
trap 'echo "image.sh: unexpected error at line $LINENO" >&2; exit 2' ERR
# Exit codes: 0 the image holds the policy, 1 it does not, 2 it could not be
# checked, 3 the host needs keytool, 4 the host needs certutil (a caller can
# install the tool and run again).

P11_TRUST=/etc/pki/ca-trust/extracted/openssl/ca-bundle.trust.crt

policy=
platform=
min_roots=100
strict_binaries=0
allow=()
while [ $# -gt 0 ]; do
	case $1 in
	--policy) policy=$2; shift 2 ;;
	--platform) platform=$2; shift 2 ;;
	--min-roots) min_roots=$2; shift 2 ;;
	--strict-binaries) strict_binaries=1; shift ;;
	--allow) allow+=("$2"); shift 2 ;;
	-*) echo "image.sh: unknown option $1" >&2; exit 2 ;;
	*) break ;;
	esac
done
[ $# -eq 1 ] || { echo "usage: image.sh --policy DIR [options] IMAGE" >&2; exit 2; }
IMAGE=$1
[ -n "$policy" ] || { echo "image.sh: --policy DIR is required" >&2; exit 2; }
LIST=$policy/ca-distrust.list
CERTS=$policy/ca-distrust
if [ ! -f "$LIST" ] || [ ! -d "$CERTS" ]; then
	echo "image.sh: $policy has no ca-distrust.list and ca-distrust/" >&2
	exit 2
fi
# The positive control's list (ca-keep.list). A kit of v0.1.47 or older
# has none: use the copy beside this script, so every repo on
# harden-check@v1 gets the check now, not at its next kit bump.
KEEP_LIST=$policy/ca-keep.list
KEEP=$policy/ca-keep
if [ ! -f "$KEEP_LIST" ]; then
	KEEP_LIST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/keep/ca-keep.list
	KEEP=${KEEP_LIST%.list}
	echo "policy: the kit has no ca-keep.list; using the action's copy"
fi

for tool in docker openssl awk sha256sum tar; do
	command -v "$tool" >/dev/null || { echo "image.sh: needs $tool" >&2; exit 2; }
done

work=$(mktemp -d)
cid=
cleanup() {
	local rc=$?
	# Exit 1 is kept for a policy failure, which only the end of the script
	# returns. Anything else that stops the script early with 1 (an unbound
	# variable, a failing command in a function) could not check the image.
	if [ "$rc" -eq 1 ] && [ "${policy_failed:-0}" != 1 ]; then
		echo "image.sh: stopped by an unexpected error" >&2
		rc=2
	fi
	[ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || true
	# An image can hold read-only directories; make them writable to remove
	# them, and never let the cleanup change the result.
	chmod -R u+rwX "$work" 2>/dev/null || true
	rm -rf "$work" || true
	exit "$rc"
}
trap cleanup EXIT
root=$work/root
mkdir "$root"

fail=0
bad() {
	echo "FAIL: $*" >&2
	fail=1
}

# The policy: fingerprints, and the PEM lines used to find a certificate in
# a binary.
declare -A listed=() listed_key=()
: >"$work/probes"
while read -r fp kind file _; do
	case $fp in '' | '#'*) continue ;; esac
	got=$(openssl x509 -in "$CERTS/$file" -outform der | sha256sum | cut -c1-64)
	[ "$got" = "$fp" ] || { echo "image.sh: $file has sha256 $got, the list says $fp" >&2; exit 2; }
	listed[$fp]="$kind $file"
	# The key too: a cross-signed copy of a listed CA is another certificate
	# with the same key, and must be distrusted the same way.
	kfp=$(openssl x509 -in "$CERTS/$file" -noout -pubkey | openssl pkey -pubin -outform der | sha256sum | cut -c1-64)
	listed_key[$kfp]=$file
	n=$(sed '/^-----/d' "$CERTS/$file" | wc -l)
	sed '/^-----/d' "$CERTS/$file" | sed -n "4p;$(((n + 1) / 2))p" >>"$work/probes"
done <"$LIST"
echo "policy: ${#listed[@]} listed certificate(s)"

# Export the file system. tar skips device files it cannot create.
# Exit 2, not docker's own code: a pull error is a check that could not run,
# not an image that fails the policy.
cid=$(docker create ${platform:+--platform "$platform"} "$IMAGE" /nonexistent) ||
	{ echo "image.sh: cannot create a container of $IMAGE${platform:+ ($platform)}" >&2; exit 2; }
# A failed export must not pass as a clean image: any tar error fails.
if ! docker export "$cid" | tar -x -C "$root" --no-same-owner --no-same-permissions --exclude='dev/*' 2>"$work/tar.err"; then
	echo "image.sh: could not export $IMAGE:" >&2
	head -20 "$work/tar.err" >&2
	exit 2
fi
[ -d "$root/etc" ] || [ -d "$root/usr" ] || { echo "image.sh: $IMAGE has no /etc or /usr" >&2; exit 2; }
# A host that is not root cannot read a file the image keeps mode 000
# (/etc/shadow): make every file readable, so no file is skipped.
chmod -R u+rwX "$root"


# is_binary FILE: FILE holds a NUL byte.
# The read stops at the first NUL and after 16 MiB, so a large file is not
# read in full. A binary whose first NUL is later is read as text, which can
# only make the check stricter (a PEM scan fails, a binary only warns).
# tr's broken pipe, once head has its byte, is expected: its message is
# dropped.
is_binary() { [ "$(head -c 16777216 "$1" 2>/dev/null | tr -dc '\000' 2>/dev/null | head -c 1 | wc -c)" -gt 0 ]; }

# in_root PATH: the file PATH names in the image, with every link resolved
# inside the image root. A plain test of "$root$PATH" would follow an absolute
# link (/etc/pki/tls/certs/ca-bundle.crt on RHEL) to the host's own file.
# Prints the host path of the target; fails if it is not a regular file.
in_root() {
	local todo=$1 done_='' part hops=0 t
	while [ -n "$todo" ]; do
		todo=${todo#/}
		part=${todo%%/*}
		if [ "$part" = "$todo" ]; then todo=; else todo=${todo#*/}; fi
		case $part in '' | .) continue ;; ..) done_=${done_%/*}; continue ;; esac
		if [ -L "$root$done_/$part" ]; then
			hops=$((hops + 1))
			[ "$hops" -le 40 ] || return 1
			t=$(readlink "$root$done_/$part")
			case $t in /*) done_= ;; esac
			todo=$t${todo:+/$todo}
		else
			done_=$done_/$part
		fi
	done
	if [ ! -f "$root$done_" ] || [ -L "$root$done_" ]; then return 1; fi
	printf '%s\n' "$root$done_"
}

allowed() {
	local p
	for p in "${allow[@]}"; do
		# shellcheck disable=SC2053 # a glob match is the point
		[[ $1 == $p ]] && return 0
	done
	return 1
}

# Host tools that only some images need. Ask for them now, before the scans,
# so a caller that installs the tool and runs again does not pay for a full
# scan first. The same files count as in the checks below: an allowed path
# and a PEM file named cacerts need no tool.
need_keytool=0
while IFS= read -r -d '' ks; do
	allowed "${ks#"$root"}" && continue
	if is_binary "$ks"; then need_keytool=1; break; fi
done < <(find "$root" -type f -name cacerts -print0)
if [ "$need_keytool" = 1 ] && ! command -v keytool >/dev/null; then
	echo "image.sh: the image has a Java keystore; install keytool (a JDK) on the host" >&2
	exit 3
fi
need_certutil=0
while IFS= read -r -d '' db; do
	allowed "$(dirname "${db#"$root"}")" || { need_certutil=1; break; }
done < <(find "$root" -type f \( -name cert9.db -o -name cert8.db \) -print0)
if [ "$need_certutil" = 1 ] && ! command -v certutil >/dev/null; then
	echo "image.sh: the image has an NSS database; install certutil (libnss3-tools) on the host" >&2
	exit 4
fi

# Every regular file with a PEM certificate or a probe line. Links are left
# out: they point at a path in the image, which is scanned as itself.
# A grep error (an unreadable file) fails the check: exit 1 only means no
# match.
find "$root" -type f -print0 >"$work/all-files"
rc=0
xargs -0 grep -laF -e '-----BEGIN CERTIFICATE-----' -e '-----BEGIN TRUSTED CERTIFICATE-----' -f "$work/probes" <"$work/all-files" >"$work/files.unsorted" 2>"$work/grep.err" || rc=$?
# xargs exits 123 when a grep finds nothing, so a grep error shows only on
# stderr.
if [ -s "$work/grep.err" ] || { [ "$rc" -gt 1 ] && [ "$rc" -ne 123 ]; }; then
	echo "image.sh: grep failed ($rc) while scanning $IMAGE:" >&2
	head -20 "$work/grep.err" >&2
	exit 2
fi
sort "$work/files.unsorted" >"$work/files"

# Every listed certificate is offered as an untrusted intermediate, so an
# intermediate whose issuer is listed too still finds its path.
cat "$CERTS"/*.pem >"$work/all.pem"

# The verify test uses only the bundle given (-no-CApath, and -no-CAstore
# in OpenSSL 3), or a root the host trusts would be blamed on the image. A
# listed root must verify against itself, or the test is broken.
certs=()
while read -r fp kind file _; do
	case $fp in '' | '#'*) continue ;; esac
	certs+=("$CERTS/$file")
	[ -n "${control:-}" ] || [ "$kind" != root ] || control=$CERTS/$file
done <"$LIST"
verify_flags=()
# -no_check_time: a listed certificate must not verify even after it expires
# (Comodo AAA expires at the end of 2028), and the control root must keep
# verifying, or the check would stop working on that date.
for flags in "-no_check_time -no-CApath -no-CAstore" "-no_check_time -no-CApath"; do
	read -r -a try <<<"$flags"
	if openssl verify "${try[@]}" -CAfile "$control" "$control" >/dev/null 2>&1; then
		verify_flags=("${try[@]}")
		break
	fi
done
[ "${#verify_flags[@]}" -gt 0 ] || { echo "image.sh: the host's openssl verify cannot verify a listed root against itself" >&2; exit 2; }

files=0
bundles=0
binaries=0
while IFS= read -r f; do
	path=${f#"$root"}
	allowed "$path" && { echo "allowed: $path"; continue; }
	# p11-kit sources are input to update-ca-trust, not trust stores: a
	# blocklist entry beside them overrides them, and the extracted stores
	# below are what clients read.
	case $path in /usr/share/pki/ca-trust-source/* | /etc/pki/ca-trust/source/*) continue ;; esac
	# A binary, or program source (Go module cache test data, a vendored
	# library), is reported, not failed: it is not a trust store until a
	# program is built from it. Keep this list the same as the module's.
	is_src=0
	case $path in *.go | *.c | *.h | *.cc | *.cpp | *.java | *.rs | *.js | *.mjs | *.cjs | *.ts | *.rb | *.py) is_src=1 ;; esac
	if [ "$is_src" = 1 ] || is_binary "$f"; then
		if grep -qaF -f "$work/probes" "$f"; then
			binaries=$((binaries + 1))
			if [ "$strict_binaries" = 1 ]; then
				bad "$path: a binary or source file that holds a listed certificate"
			else
				echo "WARN: $path: a binary or source file that holds a listed certificate (not edited)" >&2
			fi
		fi
		continue
	fi
	files=$((files + 1))
	# Split the blocks (any line width, CRLF too) and fingerprint each one.
	dir=$(mktemp -d -p "$work")
	tr -d '\r' <"$f" | awk -v dir="$dir" '
		/^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { n++; out = sprintf("%s/%05d.pem", dir, n); inblk = 1 }
		inblk { print > out }
		/^-----END (TRUSTED )?CERTIFICATE-----$/ { inblk = 0; close(out) }'
	ncerts=0
	for pem in "$dir"/*.pem; do
		[ -e "$pem" ] || continue
		der=$(openssl x509 -in "$pem" -outform der 2>/dev/null | sha256sum | cut -c1-64) || continue
		ncerts=$((ncerts + 1))
		cat "$pem" >>"$dir/bundle"
		[ -n "${listed[$der]:-}" ] || continue
		if [ "$path" = "$P11_TRUST" ]; then
			# p11-kit keeps a blocked certificate in this file on purpose,
			# marked as rejected for every use.
			openssl x509 -in "$pem" -noout -text -trustout 2>/dev/null | grep -A1 '^Rejected Uses:' | grep -q 'TLS Web Server Authentication' ||
				bad "$path: holds ${listed[$der]#* } (${listed[$der]%% *}) and does not reject it"
		else
			bad "$path: holds ${listed[$der]#* } (${listed[$der]%% *})"
		fi
	done
	# A listed certificate's text outside the blocks parsed above (an
	# indented or quoted PEM, a broken BEGIN line) is still a listed
	# certificate, even in a file with other certificates.
	if tr -d '\r' <"$f" | awk '
		/^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { inblk = 1; buf = ""; next }
		inblk && /^-----END (TRUSTED )?CERTIFICATE-----$/ { inblk = 0; next }
		inblk { buf = buf $0 "\n"; next }
		{ print }
		END { if (inblk) printf "%s", buf }' | grep -F -f "$work/probes" >/dev/null; then
		bad "$path: holds a listed certificate's text in a layout openssl cannot read"
	fi
	# Does a listed certificate verify against this file as a trust store?
	# P11_TRUST is left out: openssl verify ignores its rejected uses, and
	# tls-ca-bundle.pem, extracted from the same store, is verified.
	if [ "$ncerts" -gt 0 ] && [ "$path" != "$P11_TRUST" ]; then
		bundles=$((bundles + 1))
		# A public root bundle, for the positive control below.
		if [ "$ncerts" -ge 100 ]; then printf '%s\n' "$f" >>"$work/root-bundles"; fi
		while IFS= read -r ok; do
			bad "$path: ${ok##*/} verifies against it"
		done < <(openssl verify "${verify_flags[@]}" -CAfile "$dir/bundle" -untrusted "$work/all.pem" "${certs[@]}" 2>/dev/null | sed -n 's/: OK$//p')
	fi
	rm -rf "$dir"
done <"$work/files"
echo "scanned $files PEM file(s), $bundles verified as trust stores"

# The system bundle must not be empty.
sysb=
for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/cert.pem; do
	if [ -f "$root$b" ] && [ ! -L "$root$b" ]; then
		sysb=$b
		break
	fi
done
if [ -n "$sysb" ]; then
	c=$(grep -c '^-----BEGIN CERTIFICATE-----' "$root$sysb" || true)
	echo "$sysb: $c certificate(s)"
	[ "$c" -ge "$min_roots" ] || bad "$sysb: $c certificate(s), expected at least $min_roots"
else
	# Every TLS client needs one; an image with none either has no TLS
	# client (pass --min-roots 0) or one that uses a built-in list.
	[ "$min_roots" -eq 0 ] || bad "no system CA bundle (node:alpine and others ship none: install ca-certificates before the kit)"
fi

# Java. Every keystore must not hold a listed certificate, and every JDK
# (a lib/security directory with a cacerts, a file or a link) needs its own
# blocked.certs that blocks every listed certificate. Debian and RHEL JDKs
# link both files to /etc, so each is resolved inside the image. A keystore
# that only p11-kit extracts for a JDK that is not in the image needs no
# blocked.certs.
# check_blocked FILE PATH: FILE (PATH in the image) blocks every listed one.
check_blocked() {
	local fp
	for fp in "${!listed[@]}"; do
		grep -qxi "$fp" "$1" || bad "$2: does not block ${listed[$fp]#* }"
	done
	echo "$2: checked"
}
find "$root" -type f -name cacerts -print0 2>/dev/null >"$work/keystores" || true
while IFS= read -r -d '' ks; do
	path=${ks#"$root"}
	allowed "$path" && continue
	# A PEM file named cacerts (some distributions) is checked above.
	is_binary "$ks" || continue
	if ! out=$(keytool -list -keystore "$ks" -storepass changeit 2>&1); then
		bad "$path: keytool cannot read it: $out"
		continue
	fi
	while read -r fp; do
		fp=$(tr -d : <<<"$fp" | tr 'A-F' 'a-f')
		[ -n "${listed[$fp]:-}" ] && bad "$path: holds ${listed[$fp]#* }"
	done < <(sed -n 's/.*fingerprint (SHA-256): //p' <<<"$out")
	echo "$path: checked"
done <"$work/keystores"
# Each JDK security directory, found by its cacerts or its blocked.certs
# (a file or a link). The allow list applies to the directory: allowing
# either file skips the JDK. Each blocked.certs is checked once, as the image
# resolves it.
declare -A seen_blocked=()
find "$root" \( -path '*/lib/security/cacerts' -o -path '*/lib/security/blocked.certs' \) \( -type f -o -type l \) -print 2>/dev/null |
	sed -e "s#^$root##" -e 's#/[^/]*$##' | sort -u >"$work/jdks"
while IFS= read -r sec; do
	allowed "$sec/cacerts" && continue
	allowed "$sec/blocked.certs" && continue
	if ! bc=$(in_root "$sec/blocked.certs"); then
		bad "$sec: a JDK with no blocked.certs"
		continue
	fi
	[ -z "${seen_blocked[$bc]:-}" ] || continue
	seen_blocked[$bc]=1
	check_blocked "$bc" "${bc#"$root"}"
done <"$work/jdks"

# NSS.
find "$root" -type f \( -name cert9.db -o -name cert8.db \) -print0 2>/dev/null >"$work/nss" || true
if [ -s "$work/nss" ]; then
	while IFS= read -r -d '' db; do
		d=$(dirname "$db")
		path=${d#"$root"}
		allowed "$path" && continue
		case $db in *cert9.db) spec=sql:$d ;; *) spec=dbm:$d ;; esac
		out=$(certutil -L -d "$spec" 2>&1) || { bad "$path: certutil cannot read it: $out"; continue; }
		# Match each certificate by the sha256 of its DER, not by its
		# nickname: certutil -A does not rename a certificate the database
		# already holds, so a listed certificate that was in the database
		# before the kit ran keeps its old nickname (buildenv#165). NSS keeps
		# one trust per certificate, so every nickname of it shows the same
		# trust.
		declare -A nss_trust=()
		while IFS=$'\t' read -r nick trust; do
			pems=$(certutil -L -d "$spec" -n "$nick" -a 2>/dev/null) || { bad "$path: certutil cannot export '$nick'"; continue; }
			ndir=$(mktemp -d -p "$work")
			awk -v dir="$ndir" '
				/^-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/%05d.pem", dir, n); inblk = 1 }
				inblk { print > out }
				/^-----END CERTIFICATE-----/ { inblk = 0; close(out) }' <<<"$pems"
			for pem in "$ndir"/*.pem; do
				[ -e "$pem" ] || continue
				fp=$(openssl x509 -in "$pem" -outform der 2>/dev/null | sha256sum | cut -c1-64)
				[ -n "${listed[$fp]:-}" ] && nss_trust[$fp]=$trust
				# Any other certificate with a listed key (a cross-signed
				# copy) must be distrusted too: the DER search skips NSS
				# databases, so this is where it is caught.
				# A key the host openssl cannot load is not a listed key.
				kfp=$(openssl x509 -in "$pem" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -c1-64) || kfp=
				if [ -z "${listed[$fp]:-}" ] && [ -n "${listed_key[$kfp]:-}" ] && [ "$trust" != p,p,p ]; then
					bad "$path: '$nick' has the key of ${listed_key[$kfp]} and trust $trust, not p,p,p"
				fi
			done
			rm -rf "$ndir"
		# A listing line is the nickname, spaces, then the trust (three
		# comma-separated flag sets). The header lines have none, or a slash.
		done < <(sed -nE 's/^(.*[^[:space:]])[[:space:]]+([A-Za-z]*,[A-Za-z]*,[A-Za-z]*)[[:space:]]*$/\1\t\2/p' <<<"$out")
		for fp in "${!listed[@]}"; do
			file=${listed[$fp]#* }
			# Absent is a failure too: Chrome trusts its built-in roots unless
			# the database distrusts them.
			[ "${nss_trust[$fp]:-}" = p,p,p ] || bad "$path: does not distrust $file (trust '${nss_trust[$fp]:-absent}', want p,p,p)"
		done
		unset nss_trust
		echo "$path: checked"
	done <"$work/nss"
fi

# Clients with their own root list. A clean system store does nothing for a
# client that does not read it, so the image's environment must point each
# one at the store (lessons of connectorhub#262 and hyphae#71/#72).
# Read it from the container made above, not the image name: on a
# multi-platform image the name can resolve to another platform's config.
docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" >"$work/env" 2>/dev/null ||
	{ echo "image.sh: cannot read the environment of $IMAGE" >&2; exit 2; }
envval() { sed -n "s/^$1=//p" "$work/env" | tail -1; }
find "$root" -type f -perm -u+x \( -name node -o -name uv -o -name uvx -o -name chrome -o -name chromium -o -name chromium-browser -o -name headless_shell -o -name headless-shell \) -print >"$work/clients"
while IFS= read -r exe; do
	path=${exe#"$root"}
	allowed "$path" && continue
	case ${exe##*/} in
	node)
		# Node trusts its built-in list (it holds the emSign roots and, in
		# some versions, AAA) unless --use-openssl-ca makes it read only
		# OpenSSL's store. An official Node binary's OpenSSL looks in its own
		# directory, not the distribution's, so it trusts nothing (and every
		# TLS call fails) unless SSL_CERT_FILE names the bundle.
		# --use-system-ca adds the system store to the built-in list, which
		# keeps the emSign roots: it does not count.
		cf=$(envval SSL_CERT_FILE)
		case " $(envval NODE_OPTIONS) " in
		*" --use-openssl-ca "*)
			if [ -n "$cf" ] && in_root "$cf" >/dev/null; then
				echo "$path: NODE_OPTIONS=--use-openssl-ca, SSL_CERT_FILE=$cf"
			else
				bad "$path: --use-openssl-ca without SSL_CERT_FILE set to the system bundle: an official Node binary then trusts no root"
			fi
			;;
		*) bad "$path: Node uses its built-in root list; set ENV NODE_OPTIONS=--use-openssl-ca and SSL_CERT_FILE=<system bundle> (--use-system-ca keeps the built-in list)" ;;
		esac
		;;
	uv | uvx)
		# uv trusts its built-in list unless SSL_CERT_FILE (or native TLS)
		# is set, and uvx installs a fresh certifi when it runs, which no
		# build step can clean, so requests must read the bundle too.
		cf=$(envval SSL_CERT_FILE)
		if [ "$(envval UV_NATIVE_TLS)" != 1 ] && { [ -z "$cf" ] || ! in_root "$cf" >/dev/null; }; then
			bad "$path: uv uses its built-in root list; set ENV SSL_CERT_FILE to the system bundle"
		fi
		[ -n "$(envval REQUESTS_CA_BUNDLE)" ] || bad "$path: a certifi that uv installs at run time is not hardened; set ENV REQUESTS_CA_BUNDLE (and SSL_CERT_FILE) to the system bundle"
		;;
	*)
		# Chrome trusts the Chrome Root Store built into its binary and takes
		# distrust only from an NSS database in $HOME/.pki/nssdb. The kit
		# distrusts the listed certificates in every NSS database in the
		# image; the program must copy one to $HOME/.pki/nssdb when it starts
		# (hyphae pdfserv/pdfgen/nssdb.go) and check that Chrome opens it.
		[ -s "$work/nss" ] || bad "$path: Chrome uses its built-in roots and the image has no NSS database to distrust them (ship one, made with certutil before the kit, and copy it to \$HOME/.pki/nssdb at start)"
		echo "WARN: $path: Chrome reads distrust only from \$HOME/.pki/nssdb at run time; the program must install the image's NSS database there" >&2
		;;
	esac
done <"$work/clients"

# The positive control (policy/ca-keep.list): what the policy keeps is still
# trusted. The checks above prove that the listed CAs fail, and an emptied or
# over-edited store passes them too, so they cannot tell a correct block from
# one that breaks every TLS client. Here:
#
#   - each kept intermediate (a current Sectigo CA) verifies against each
#     public root bundle: a PEM file with 100 or more certificates (the
#     system bundle, certifi), and the file that SSL_CERT_FILE or
#     REQUESTS_CA_BUNDLE names. Go, Node (--use-openssl-ca), uv, Python
#     requests, curl and git read these files, so a chain they accept
#     verifies here;
#   - each kept root (USERTrust RSA and ECC) is in each Java keystore, and no
#     blocked.certs blocks a kept certificate;
#   - no NSS database distrusts a kept certificate, or one with its key.
#
# A kept certificate that ca-distrust.list lists too, or that has a listed
# key, is a broken policy: the check exits 2.
if [ -f "$KEEP_LIST" ]; then
	declare -A keep=() keep_key=() distrust_key=()
	for c in "$CERTS"/*.pem; do
		distrust_key[$(openssl x509 -in "$c" -noout -pubkey | openssl pkey -pubin -outform der | sha256sum | cut -c1-64)]=1
	done
	keep_roots=() keep_ints=()
	while read -r fp kind file _; do
		case $fp in '' | '#'*) continue ;; esac
		got=$(openssl x509 -in "$KEEP/$file" -outform der | sha256sum | cut -c1-64)
		[ "$got" = "$fp" ] || { echo "image.sh: $file has sha256 $got, the keep list says $fp" >&2; exit 2; }
		kfp=$(openssl x509 -in "$KEEP/$file" -noout -pubkey | openssl pkey -pubin -outform der | sha256sum | cut -c1-64)
		if [ -n "${listed[$fp]:-}" ] || [ -n "${distrust_key[$kfp]:-}" ]; then
			echo "image.sh: $file is kept and distrusted: fix the policy" >&2
			exit 2
		fi
		keep[$fp]=$file
		keep_key[$kfp]=$file
		case $kind in
		root) keep_roots+=("$fp") ;;
		intermediate) keep_ints+=("$KEEP/$file") ;;
		*) echo "image.sh: $KEEP_LIST: $fp: kind must be root or intermediate, not $kind" >&2; exit 2 ;;
		esac
	done <"$KEEP_LIST"

	# -no_check_time: the kept intermediates expire in 2030, and the control
	# must not start to fail on that date.
	keep_flags=("${verify_flags[@]}")
	if openssl verify -no_check_time "${verify_flags[@]}" -CAfile "$control" "$control" >/dev/null 2>&1; then
		keep_flags=(-no_check_time "${verify_flags[@]}")
	fi
	for v in SSL_CERT_FILE REQUESTS_CA_BUNDLE; do
		cf=$(envval "$v")
		[ -n "$cf" ] || continue
		# A file the variable names that is not in the image is reported by
		# the client rules above.
		if host=$(in_root "$cf"); then
			allowed "${host#"$root"}" || printf '%s\n' "$host" >>"$work/root-bundles"
		fi
	done
	touch "$work/root-bundles"
	sort -u "$work/root-bundles" -o "$work/root-bundles"
	nkeep=0
	while IFS= read -r f; do
		for c in "${keep_ints[@]}"; do
			if openssl verify "${keep_flags[@]}" -CAfile "$f" "$c" >/dev/null 2>&1; then
				nkeep=$((nkeep + 1))
			else
				bad "${f#"$root"}: kept ${c##*/} does not verify against it (a root it needs was removed)"
			fi
		done
	done <"$work/root-bundles"
	echo "keep: ${#keep_ints[@]} kept intermediate(s), $(wc -l <"$work/root-bundles") root bundle(s)"

	# Java.
	while IFS= read -r -d '' ks; do
		path=${ks#"$root"}
		allowed "$path" && continue
		is_binary "$ks" || continue
		out=$(keytool -list -keystore "$ks" -storepass changeit 2>&1) || continue # reported above
		ksfps=$(sed -n 's/.*fingerprint (SHA-256): //p' <<<"$out" | tr -d : | tr 'A-F' 'a-f')
		for fp in "${keep_roots[@]}"; do
			grep -qx "$fp" <<<"$ksfps" || bad "$path: does not hold kept root ${keep[$fp]}"
		done
	done <"$work/keystores"
	while IFS= read -r -d '' bc; do
		path=${bc#"$root"}
		allowed "$path" && continue
		for fp in "${!keep[@]}"; do
			if grep -qxi "$fp" "$bc"; then bad "$path: blocks kept ${keep[$fp]}"; fi
		done
	done < <(find "$root" -type f -name blocked.certs -print0)

	# NSS: a CA with no trust flag for TLS (C, c or T) that is marked p is
	# distrusted.
	if [ -s "$work/nss" ]; then
		while IFS= read -r -d '' db; do
			d=$(dirname "$db")
			path=${d#"$root"}
			allowed "$path" && continue
			case $db in *cert9.db) spec=sql:$d ;; *) spec=dbm:$d ;; esac
			out=$(certutil -L -d "$spec" 2>/dev/null) || continue # reported above
			while IFS=$'\t' read -r nick trust; do
				ssl=${trust%%,*}
				case $ssl in *[CcT]*) continue ;; *p*) ;; *) continue ;; esac
				pems=$(certutil -L -d "$spec" -n "$nick" -a 2>/dev/null) || continue
				ndir=$(mktemp -d -p "$work")
				awk -v dir="$ndir" '
					/^-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/%05d.pem", dir, n); inblk = 1 }
					inblk { print > out }
					/^-----END CERTIFICATE-----/ { inblk = 0; close(out) }' <<<"$pems"
				for pem in "$ndir"/*.pem; do
					[ -e "$pem" ] || continue
					fp=$(openssl x509 -in "$pem" -outform der 2>/dev/null | sha256sum | cut -c1-64)
					kfp=$(openssl x509 -in "$pem" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | cut -c1-64) || kfp=
					if [ -n "${keep[$fp]:-}" ]; then
						bad "$path: distrusts kept ${keep[$fp]} ('$nick', trust $trust)"
					elif [ -n "${keep_key[$kfp]:-}" ]; then
						bad "$path: '$nick' has the key of kept ${keep_key[$kfp]} and trust $trust"
					fi
				done
				rm -rf "$ndir"
			done < <(sed -nE 's/^(.*[^[:space:]])[[:space:]]+([A-Za-z]*,[A-Za-z]*,[A-Za-z]*)[[:space:]]*$/\1\t\2/p' <<<"$out")
		done <"$work/nss"
	fi
	[ "$fail" -ne 0 ] || echo "keep: $nkeep chain check(s) passed; kept roots in every Java keystore, no kept certificate distrusted"
fi

# Roots compiled into a binary as DER (Go's x509roots/fallback, Node,
# Chrome, uv): search each binary for each listed certificate's public key,
# which a cross-signed copy shares (mars#306 searched by name).
if command -v python3 >/dev/null; then
	for c in "$CERTS"/*.pem; do
		printf '%s ' "$(basename "$c")"
		openssl x509 -in "$c" -noout -pubkey | openssl pkey -pubin -outform der | od -An -v -tx1 | tr -d ' \n'
		echo
	done >"$work/spki"
	cat >"$work/der.py" <<'PY'
import mmap, sys
keys = {}
for line in open(sys.argv[1]):
    name, hexkey = line.split()
    keys.setdefault(bytes.fromhex(hexkey), []).append(name)
for path in open(sys.argv[2], "rb").read().split(b"\0"):
    if not path:
        continue
    # mmap, not read(): a file of several GB (a model, a data set) must not
    # be loaded into memory.
    try:
        with open(path, "rb") as f:
            if f.seek(0, 2) == 0:
                continue
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as data:
                if data.find(b"\0") < 0:
                    continue
                hits = sorted({n for k, ns in keys.items() if data.find(k) >= 0 for n in ns})
    except (OSError, ValueError) as e:
        print("ERROR", path.decode(errors="replace"), e)
        continue
    if hits:
        print(path.decode(errors="replace") + "\t" + " ".join(hits))
PY
	python3 -I "$work/der.py" "$work/spki" "$work/all-files" >"$work/der-hits"
	if grep -q '^ERROR ' "$work/der-hits"; then
		grep '^ERROR ' "$work/der-hits" >&2
		echo "image.sh: could not read a file of $IMAGE" >&2
		exit 2
	fi
	while IFS=$'\t' read -r f hits; do
		path=${f#"$root"}
		allowed "$path" && continue
		# An NSS database holds each listed certificate on purpose, with
		# trust p,p,p: the NSS check above proves that.
		case $path in */cert9.db | */cert8.db) continue ;; esac
		binaries=$((binaries + 1))
		if [ "$strict_binaries" = 1 ]; then
			bad "$path: a binary that holds the key of $hits"
		else
			echo "WARN: $path: a binary that holds the key of $hits in DER (a built-in root list: point it at the system store)" >&2
		fi
	done <"$work/der-hits"
else
	echo "WARN: no python3 on the host: binaries were not searched for DER roots" >&2
fi

if [ "$fail" -ne 0 ]; then
	policy_failed=1
	echo "FAIL: $IMAGE does not hold the build-harden policy" >&2
	exit 1
fi
echo "OK: $IMAGE holds the build-harden policy ($binaries binary or source file(s) warned)"
