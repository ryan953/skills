#!/usr/bin/env bash
# extract.sh — the pure parts of Wave 0. Sourced, never run.
#
# Everything here is a function of its arguments: no git, no gh, no network, no
# filesystem. gather.sh does the impure work and calls these; extract.test.sh
# pins them without needing a repo. The split matters because "which issue does
# this PR claim to fix" and "is this a lint fix" decide which chain gets built,
# and a misparse there is a wrong verdict two waves later.

# ---- issue references -------------------------------------------------------
# Emits `kind<TAB>ref`, deduped, in the order first seen. Kinds:
#   sentry  a Sentry issue URL or short id
#   linear  a Linear ticket id
#   github  #123, owner/repo#123, or an issues URL
#
# Deliberately conservative. A false positive here anchors the whole review to
# the wrong issue and produces a confident verdict about the wrong bug, which is
# far worse than finding nothing and routing to N1.
parse_issue_refs() {
    local text="${1-}"
    {
        # Sentry issue URLs, both the org-subdomain and /organizations/ shapes.
        printf '%s' "$text" | grep -oiE 'https?://[a-z0-9-]+\.sentry\.io/(organizations/[a-z0-9_-]+/)?issues/[0-9]+' \
            | sed 's/^/sentry\t/' || true
        printf '%s' "$text" | grep -oiE 'https?://sentry\.io/organizations/[a-z0-9_-]+/issues/[0-9]+' \
            | sed 's/^/sentry\t/' || true

        # Sentry short ids: PROJECT-SUFFIX where the suffix is base32-ish and at
        # least 4 chars (JAVASCRIPT-2K3F). The length floor is what keeps this
        # from swallowing every hyphenated capital in a PR body.
        printf '%s' "$text" | grep -oE '\b[A-Z][A-Z0-9]{2,}-[A-Z0-9]{4,}\b' \
            | sed 's/^/sentry\t/' || true

        # Linear: two-to-six letters, a dash, digits. Requires a cue word in
        # front — a bare ABC-123 in prose is usually not a ticket.
        printf '%s' "$text" | grep -oiE '(fix(es|ed)?|close[sd]?|resolve[sd]?|ref|see)[[:space:]:]+[A-Z]{2,6}-[0-9]+' \
            | grep -oE '[A-Z]{2,6}-[0-9]+' | sed 's/^/linear\t/' || true
        printf '%s' "$text" | grep -oiE 'https?://linear\.app/[a-z0-9_-]+/issue/[A-Z]{2,6}-[0-9]+' \
            | grep -oE '[A-Z]{2,6}-[0-9]+' | sed 's/^/linear\t/' || true

        # GitHub: an issues URL, owner/repo#N, or a #N carrying a closing cue.
        printf '%s' "$text" | grep -oiE 'https?://github\.com/[a-z0-9_.-]+/[a-z0-9_.-]+/issues/[0-9]+' \
            | sed 's/^/github\t/' || true
        printf '%s' "$text" | grep -oE '\b[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\b' \
            | sed 's/^/github\t/' || true
        printf '%s' "$text" | grep -oiE '(fix(es|ed)?|close[sd]?|resolve[sd]?)[[:space:]:]+#[0-9]+' \
            | grep -oE '#[0-9]+' | sed 's/^/github\t/' || true
    } | awk 'NF && !seen[$0]++'
}

# ---- evidence written into the description ----------------------------------
# Not every fix links a tracker. Plenty of real bug fixes carry the whole case in
# the PR body — a "## Bug" section, a pasted stack trace, a reproduction — and
# treating those as "no anchor" would send the most self-documenting changes
# straight to needs-human.
#
# Emits `kind<TAB>detail`. Deliberately narrow: structured headings, stack
# traces, and explicit repro markers only. Loose causal prose ("because", "the
# actual problem") is NOT enough — nearly every commit message contains some, and
# accepting it would hollow out the N1 guard that stops a review being anchored
# to nothing.
#
# Evidence found this way is weaker than a tracker issue, and reference/cards.md
# says why: the author wrote both the evidence and the intent, so the two are no
# longer independent. It is enough to build a chain, not enough to skip a probe.
body_evidence() {
    local text="${1-}"
    [ -n "$text" ] || { return 0; }
    {
        printf '%s\n' "$text" | grep -oiE '^#{1,4}[[:space:]]*(the )?(bug|problem|issue|symptom|root ?cause|why (it|this) (broke|happens|fails)|what (broke|went wrong))\b.*' \
            | sed 's/^/section\t/' || true
        # Stack frames in three common shapes: JS `at fn (file:line)`, Python
        # tracebacks, and a bare `SomeError: message` line.
        printf '%s\n' "$text" | grep -oE '^[[:space:]]*at [A-Za-z_$][A-Za-z0-9_$.]*[[:space:]]*\(' \
            | sed 's/^/stack\tjs frame/' || true
        printf '%s\n' "$text" | grep -oE 'Traceback \(most recent call last\)' \
            | sed 's/^/stack\t/' || true
        printf '%s\n' "$text" | grep -oE '\b[A-Z][A-Za-z]*(Error|Exception)\b:' \
            | sed 's/^/stack\t/' || true
        printf '%s\n' "$text" | grep -oiE '(reproduced?( (it|on|with|today))?|steps to reproduce|repro:)[^.]{0,60}' \
            | sed 's/^/repro\t/' || true
    } | awk 'NF && !seen[$0]++'
}

# ---- lint signals -----------------------------------------------------------
# Emits `kind<TAB>detail` for anything in the diff that looks like lint work.
# Reads a unified diff on stdin or as $1.
#
# Two families, and the difference is the whole point of R7: satisfying a rule
# (config untouched, no new suppressions) versus silencing it.
lint_signals() {
    local diff="${1-}"
    [ -n "$diff" ] || diff="$(cat)"
    {
        printf '%s\n' "$diff" | grep -E '^\+' | grep -oE 'eslint-disable(-next-line|-line)?[^*]*' \
            | sed 's/^/suppress\teslint: /' || true
        printf '%s\n' "$diff" | grep -E '^\+' | grep -oE '@ts-(expect-error|ignore)' \
            | sed 's/^/suppress\tts: /' || true
        printf '%s\n' "$diff" | grep -E '^\+' | grep -oE '#[[:space:]]*(noqa|type:[[:space:]]*ignore)[^[:space:]]*' \
            | sed 's/^/suppress\tpy: /' || true
        printf '%s\n' "$diff" | grep -E '^\+\+\+ ' \
            | grep -iE '(eslintrc|eslint\.config|biome\.json|\.prettierrc|prettier\.config|ruff\.toml|setup\.cfg|tslint|stylelint)' \
            | sed 's/^+++ [ab]\///; s/^/config\t/' || true
    } | awk 'NF && !seen[$0]++'
}

# ---- mode -------------------------------------------------------------------
# classify_mode <title-and-commit-text> <lint-signal-count> <issue-ref-count>
#
# A linked issue anchors the chain to real evidence, so it wins: a lint-titled PR
# that cites a Sentry issue is still a bug fix, and judging it as a lint fix
# would throw away the strongest input we have. Lint vocabulary in the title is
# the next signal, then suppressions in a diff nothing else explains.
classify_mode() {
    local text="${1-}" lint_count="${2:-0}" ref_count="${3:-0}"
    local titleish
    titleish="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

    case "$titleish" in
        *lint*|*eslint*|*prettier*|*biome*|*typecheck*|*tsc\ *|*ruff*|*flake8*|*"style("*|*codemod*|*"no-unused"*)
            [ "$ref_count" -gt 0 ] && { printf 'bugfix\n'; return; }
            printf 'lintfix\n'; return ;;
    esac
    if [ "$ref_count" -eq 0 ] && [ "$lint_count" -gt 0 ]; then
        printf 'lintfix\n'; return
    fi
    printf 'bugfix\n'
}

# ---- repo docs --------------------------------------------------------------
# doc_candidates <file>... — every path worth checking for repo-specific
# guidance that governs the changed files: each ancestor directory of each
# changed file, up to the root, plus the well-known root locations.
#
# Emits candidate paths (deduped, shallowest first). Existence is gather.sh's
# problem — keeping this pure is what makes it testable.
doc_candidates() {
    local names="CLAUDE.md AGENTS.md CONVENTIONS.md"
    {
        local f d n
        for f in "$@"; do
            d="$(dirname "$f")"
            while :; do
                for n in $names; do
                    if [ "$d" = "." ]; then printf '%s\n' "$n"; else printf '%s/%s\n' "$d" "$n"; fi
                done
                [ "$d" = "." ] && break
                d="$(dirname "$d")"
            done
        done
        printf '.claude/skills\n.cursor/rules\ndocs/CONTRIBUTING.md\nCONTRIBUTING.md\n'
    } | awk '!seen[$0]++' | awk '{print gsub(/\//,"/") "\t" $0}' | sort -s -n -k1,1 | cut -f2-
}

# ---- changed files ----------------------------------------------------------
# changed_files <diff> — the post-image paths a unified diff touches.
changed_files() {
    local diff="${1-}"
    [ -n "$diff" ] || diff="$(cat)"
    printf '%s\n' "$diff" | grep -E '^\+\+\+ ' | sed 's/^+++ //; s/^[ab]\///' \
        | grep -v '^/dev/null$' | awk 'NF && !seen[$0]++'
}
