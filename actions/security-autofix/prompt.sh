#!/usr/bin/env bash
# Prints the agent's prompt as a GITHUB_OUTPUT entry named `prompt`.
#
# Why a template file: the prompt is long and reviewed as prose, and keeping
# it out of the YAML keeps its quoting and expressions out of the way. The
# values are put in with a plain text replace, not a shell or envsubst
# expansion, so nothing in them is evaluated.
#
# Usage: FAILED=... EXEMPTIONS=... RUN_URL=... prompt.sh TEMPLATE
set -euo pipefail

template="$1"
: "${FAILED:?}" "${EXEMPTIONS:?}" "${RUN_URL:?}"

prompt="$(<"$template")"
prompt="${prompt//@FAILED@/"$FAILED"}"
prompt="${prompt//@EXEMPTIONS@/"$EXEMPTIONS"}"
prompt="${prompt//@RUN_URL@/"$RUN_URL"}"

# A random delimiter, so no line of the prompt can end the output early.
delim="PROMPT_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
printf 'prompt<<%s\n%s\n%s\n' "$delim" "$prompt" "$delim"
