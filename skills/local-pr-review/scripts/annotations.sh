#!/usr/bin/env bash
# annotations.sh — parse a revdiff annotation file into records the rest of the
# flow can route without re-reading revdiff's prose format.
#
# revdiff writes blocks:
#
#   ## src/app.tsx:43 (+)
#   use the shared hook here
#
#   ## store.ts:18-24 (-)
#   don't drop this validation
#
#   ## config.ts (file-level)
#   ?? why is this file in the diff at all
#
# `(+)` = added line (GitHub side RIGHT), `(-)` = removed line (LEFT),
# `(file-level)` = a note about the whole file, which has no line to attach to.
# A body line that itself begins with `## ` is written space-prefixed by revdiff,
# so one leading space is stripped back off here.
#
# Usage:
#   annotations.sh parse   <out-file>   # TSV records (format below)
#   annotations.sh summary <out-file>   # one human-readable line
#
# TSV: file <TAB> start <TAB> end <TAB> side <TAB> kind <TAB> text
#   start/end   line numbers, or 0/0 for file-level
#   side        RIGHT | LEFT | FILE
#   kind        question | directive   (see classify.sh:annotation_kind)
#   text        newlines encoded as \n so one annotation is always one record

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=classify.sh
. "$HERE/classify.sh"

CMD="${1:-parse}"
FILE="${2:-}"
[ -n "$FILE" ] || die "usage: annotations.sh {parse|summary} <out-file>"
[ -f "$FILE" ] || die "no annotation file at $FILE"

# Header parsing is awk's job (grouping blocks); the question/directive call stays
# in classify.sh so it's testable and shared with the SKILL's documented rules.
parse() {
    awk '
        function flush() {
            if (path == "") return
            gsub(/\n+$/, "", body)
            gsub(/\n/, "\\n", body)
            printf "%s\t%s\t%s\t%s\t%s\n", path, start, end, side, body
            path = ""; body = ""
        }
        /^## / {
            flush()
            hdr = substr($0, 4)
            side = "RIGHT"
            if (hdr ~ /\(file-level\)$/)  side = "FILE"
            else if (hdr ~ /\(-\)$/)      side = "LEFT"
            sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", hdr)
            # trailing :N or :N-M is the location; anything else is a bare path
            if (match(hdr, /:[0-9]+(-[0-9]+)?$/)) {
                loc = substr(hdr, RSTART + 1)
                path = substr(hdr, 1, RSTART - 1)
                if (split(loc, r, "-") == 2) { start = r[1]; end = r[2] }
                else                         { start = loc;  end = loc }
            } else {
                path = hdr; start = 0; end = 0; side = "FILE"
            }
            next
        }
        { line = $0; sub(/^ ##/, "##", line); body = body line "\n" }
        END { flush() }
    ' "$FILE"
}

# parse output plus the question/directive call, which is the form every caller
# wants. Kept as a function so `summary` counts exactly what `parse` prints.
records() {
    parse | while IFS=$'\t' read -r path start end side body; do
        [ -n "$path" ] || continue
        # \n back to real newlines only for the classifier's benefit; the emitted
        # record keeps the escaped form.
        kind="$(annotation_kind "$(printf '%b' "$body")")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$start" "$end" "$side" "$kind" "$body"
    done
}

case "$CMD" in
parse)
    records
    ;;
summary)
    TOTAL=0 Q=0 D=0
    while IFS=$'\t' read -r _ _ _ _ kind _; do
        TOTAL=$((TOTAL + 1))
        if [ "$kind" = question ]; then Q=$((Q + 1)); else D=$((D + 1)); fi
    done < <(records)
    printf '%s annotation(s): %s directive(s), %s question(s)\n' "$TOTAL" "$D" "$Q"
    ;;
*) die "unknown subcommand: $CMD" ;;
esac
