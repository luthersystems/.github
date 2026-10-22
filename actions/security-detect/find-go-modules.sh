#!/usr/bin/env bash
# Prints the directory of each Go module in the repo, one per line, relative
# to the current directory ("." for the root module).
#
# Why it skips vendor, testdata and node_modules: a go.mod there is a copy or
# a test input, not a module we ship, and scanning a test input that holds a
# known vulnerability on purpose would fail every run. A repo that needs a
# different list passes go-directories to the workflow instead.
set -euo pipefail

git ls-files -- '*go.mod' 'go.mod' 2>/dev/null |
  grep -vE '(^|/)(vendor|testdata|node_modules)/' |
  sed -e 's|/\?go\.mod$||' -e 's|^$|.|' |
  sort -u || true
