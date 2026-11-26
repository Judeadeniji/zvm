#!/bin/sh
# Removes AI attribution trailers from a commit message.
#
# Dropped lines: anything starting with the robot emoji, "Generated with
# Codebuff" (with or without trailing text), and
# "Co-Authored-By: Codebuff <...>". Trailing blank lines left behind by the
# removal are trimmed as well.
#
# Usage:
#   scripts/strip-commit-attribution.sh <message-file>   # rewrite in place
#   printf '%s' "$msg" | scripts/strip-commit-attribution.sh   # filter stdin
set -eu

in_place=0
if [ "$#" -gt 0 ]; then
    in_place=1
    src="$1"
else
    src="$(mktemp)"
    trap 'rm -f "$src"' EXIT
    cat >"$src"
fi

filtered="$(mktemp)"
trap 'rm -f "$filtered" ${src_tmp-}' EXIT

grep -viE '^(🤖|co-authored-by:[[:space:]]*codebuff|generated with codebuff)' "$src" >"$filtered" || true

# Keep everything up to the last non-blank line, dropping trailing blank lines.
awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) print line[i] }' \
    "$filtered" >"$filtered.trimmed"

if [ "$in_place" -eq 1 ]; then
    cat "$filtered.trimmed" >"$src"
else
    cat "$filtered.trimmed"
fi
