#!/usr/bin/env bash
# A surface-script for the test: it copies each tree's lisp.json to the
# files the gate passes to apibreak as -lisp-base and -lisp-head, as elps's
# and substrate's scripts write `elps doc --json -l` output there.
# Usage: surface.sh BASE_TREE HEAD_TREE OUT_DIR
set -euo pipefail
cp "$1/lisp.json" "$3/lisp-base.json"
cp "$2/lisp.json" "$3/lisp-head.json"
