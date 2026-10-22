#!/usr/bin/env bash
# Scans for committed secrets with gitleaks.
#
# Why gitleaks: GitHub secret scanning and push protection are free only on
# public repos, and all 23 private luthersystems repos had none. The owner
# chose gitleaks in the shared workflow over the paid add-on (design question
# 3), so every repo gets the same scan at no cost.
#
# What it scans, by event:
#   pull_request  the commits the PR adds (base..head), so a secret that is
#                 added and then deleted in a later commit is still caught:
#                 it is in history once the PR merges.
#   push          the commits the push adds (before..after).
#   other         the files at HEAD (a scheduled run). Not history: a secret
#                 in old history that was rotated would fail every run, and
#                 the PR scan already checked each commit as it came in.
#
# A false positive goes in .gitleaksignore (its fingerprint, from the log) or
# the repo's .gitleaks.toml allowlist; gitleaks reads both from the repo root.
# Secrets are redacted in the log.
#
# Env: EVENT, BASE, HEAD, BEFORE, AFTER (from the workflow).
set -uo pipefail

zero=0000000000000000000000000000000000000000
# gitleaks exits 1 on its own errors too (a bad range, a bad config), so a
# found secret gets its own code. Otherwise a scan that never ran would read
# as "found a secret" and send someone to rotate a key that never leaked.
leak=99
common=(--no-banner --redact -v --exit-code "$leak")

range=""
case "${EVENT:-}" in
  pull_request|pull_request_target) range="${BASE}..${HEAD}" ;;
  push) [ -n "${BEFORE:-}" ] && [ "${BEFORE}" != "$zero" ] && range="${BEFORE}..${AFTER}" ;;
esac

status=0
if [ -n "$range" ]; then
  echo "gitleaks: scanning commits $range"
  gitleaks git "${common[@]}" --log-opts="$range" . 2>&1 || status=$?
else
  echo "gitleaks: scanning the files at HEAD"
  gitleaks dir "${common[@]}" . 2>&1 || status=$?
fi

case "$status" in
  0) exit 0 ;;
  "$leak") echo "::error title=gitleaks found a secret::Rotate it first, then remove it. A false positive goes in .gitleaksignore (the fingerprint is in the log)."
     exit 1 ;;
  *) echo "::error title=gitleaks failed::gitleaks exited $status, so nothing was scanned"
     exit 1 ;;
esac
