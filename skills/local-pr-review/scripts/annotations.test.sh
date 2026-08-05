#!/usr/bin/env bash
# Tests for annotations.sh — parsing revdiff's annotation format into TSV.
#
# The parser is the seam between "what I typed in the diff view" and "what gets
# posted to GitHub or applied as an edit", so the cases that matter are the ones
# where a mis-parse would put a comment on the wrong line, the wrong side, or in
# the wrong file: multi-line ranges, `(-)` vs `(+)`, file-level notes with no
# line at all, and body text that itself looks like a header.
#
# Run:  skills/local-pr-review/scripts/annotations.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANN="$SCRIPT_DIR/annotations.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/annotations-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
N=0

# fixture <content> -> path to a file holding it
fixture() {
    N=$((N+1))
    local p="$TMPROOT/ann-$N.txt"
    printf '%s' "$1" > "$p"
    printf '%s' "$p"
}

# eq <name> <expected> <actual>
eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$(printf '%s' "$expected" | tr '\n\t' '|>')" \
            "$(printf '%s' "$actual" | tr '\n\t' '|>')"
    fi
}

# parse_of <content> -> parse output with TABs shown as > and newlines as |
parse_of() {
    bash "$ANN" parse "$(fixture "$1")" | tr '\n\t' '|>' | sed 's/|$//'
}

echo "single annotations"
eq "added line -> RIGHT, start==end" \
    'src/app.tsx>43>43>RIGHT>directive>use the shared hook here' \
    "$(parse_of '## src/app.tsx:43 (+)
use the shared hook here
')"

eq "removed line -> LEFT" \
    'store.ts>18>18>LEFT>directive>keep this validation' \
    "$(parse_of '## store.ts:18 (-)
keep this validation
')"

eq "line range keeps both bounds" \
    'store.ts>18>24>LEFT>directive>this whole block was load-bearing' \
    "$(parse_of '## store.ts:18-24 (-)
this whole block was load-bearing
')"

eq "file-level -> 0/0/FILE" \
    'config.ts>0>0>FILE>question>?? why is this file in the diff at all' \
    "$(parse_of '## config.ts (file-level)
?? why is this file in the diff at all
')"

eq "question wording is classified, not just ??" \
    'util.ts>9>9>RIGHT>question>explain what this regex does' \
    "$(parse_of '## util.ts:9 (+)
explain what this regex does
')"

echo ""
echo "shape edge cases"
# A path with no :N and no (file-level) marker still has no line to attach to.
eq "bare path with no marker -> FILE" \
    'notes.md>0>0>FILE>directive>drop this file' \
    "$(parse_of '## notes.md
drop this file
')"

# revdiff space-prefixes a body line that starts with ##; one space comes back off
# so the body survives intact instead of being read as a second annotation.
eq "space-escaped ## stays in the body" \
    'src/app.tsx>43>43>RIGHT>directive>use the hook\n## not a header, literal' \
    "$(parse_of '## src/app.tsx:43 (+)
use the hook
 ## not a header, literal
')"

eq "multi-line body joins with \\n" \
    'a.ts>3>3>RIGHT>directive>first line\nsecond line' \
    "$(parse_of '## a.ts:3 (+)
first line
second line
')"

# Blank lines between blocks are separators, not body content.
eq "trailing blank lines are trimmed" \
    'a.ts>3>3>RIGHT>directive>only line' \
    "$(parse_of '## a.ts:3 (+)
only line


')"

eq "nested path with dots survives" \
    'src/views/foo.bar.spec.tsx>120>121>RIGHT>directive>assert the label too' \
    "$(parse_of '## src/views/foo.bar.spec.tsx:120-121 (+)
assert the label too
')"

echo ""
echo "multiple annotations in one file"
eq "four blocks, in file order, one record each" \
    'src/app.tsx>43>43>RIGHT>directive>use the shared hook here|store.ts>18>24>LEFT>directive>keep this validation|config.ts>0>0>FILE>question>?? why is this here|util.ts>9>9>RIGHT>question>explain what this regex does' \
    "$(parse_of '## src/app.tsx:43 (+)
use the shared hook here

## store.ts:18-24 (-)
keep this validation

## config.ts (file-level)
?? why is this here

## util.ts:9 (+)
explain what this regex does
')"

echo ""
echo "empty input"
eq "no annotations -> no records" '' "$(parse_of '')"
eq "whitespace only -> no records" '' "$(parse_of '

')"
# Body text with no header above it has no location, so it is not an annotation.
eq "orphan body with no header -> no records" '' "$(parse_of 'just some text
with no header
')"

echo ""
echo "summary"
eq "counts directives and questions separately" \
    '4 annotation(s): 2 directive(s), 2 question(s)' \
    "$(bash "$ANN" summary "$(fixture '## a.ts:1 (+)
change this

## b.ts:2 (-)
and this

## c.ts (file-level)
?? what is this

## d.ts:4 (+)
explain the cache key
')")"
eq "empty file summarizes as zero" \
    '0 annotation(s): 0 directive(s), 0 question(s)' \
    "$(bash "$ANN" summary "$(fixture '')")"

echo ""
echo "error handling"
OUT="$(bash "$ANN" parse "$TMPROOT/does-not-exist.txt" 2>&1)"; RC=$?
eq "missing file exits non-zero" 1 "$RC"
case "$OUT" in *"no annotation file"*) eq "missing file explains itself" yes yes ;;
                *) eq "missing file explains itself" yes "$OUT" ;; esac
OUT="$(bash "$ANN" bogus "$(fixture '')" 2>&1)"; RC=$?
eq "unknown subcommand exits non-zero" 1 "$RC"
# Called with no file at all it must not silently parse stdin or $PWD.
OUT="$(bash "$ANN" parse 2>&1)"; RC=$?
eq "no file argument exits non-zero" 1 "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
