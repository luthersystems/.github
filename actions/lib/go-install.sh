#!/usr/bin/env bash
# Installs a pinned Go tool into a cache directory and puts it on PATH.
#
# Why go install: it checks the module against the Go checksum database, so
# the binary is built from the reviewed release, the same guarantee a pinned
# checksum gives. Why a cache: building golangci-lint or osv-scanner takes
# minutes, and every job of every PR in every repo would pay that. The action
# that calls this restores DIR from the Actions cache, keyed on the tool and
# its version, so a repo builds each version once.
#
# Usage: go-install.sh DIR MODULE@VERSION BINARY
set -euo pipefail

dir="$1" mod="$2" bin="$3"
mkdir -p "$dir"
if [ ! -x "$dir/$bin" ]; then
  # GOFLAGS and GOWORK are the caller's settings for its own code (for
  # example -mod=vendor); they must not change how a pinned tool builds.
  # TOOL_GOTOOLCHAIN lets an action pin the Go a tool needs (Trivy, see
  # trivy-config/action.yml); auto otherwise, so a tool that needs a newer
  # Go than the runner's still builds.
  GOTOOLCHAIN="${TOOL_GOTOOLCHAIN:-auto}" GOFLAGS="" GOWORK=off GOBIN="$dir" go install "$mod"
fi
echo "$dir" >>"${GITHUB_PATH:-/dev/null}"
