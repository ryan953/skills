#!/usr/bin/env bash
# lib.sh — shared helpers and the pure decision functions for merge-pr.
# Sourced, never run. The decision functions take facts as arguments and print a
# decision, with no network calls, so lib.test.sh can cover every branch.

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# GUI launches (the desktop app) can start without the login shell's PATH, which
# is where Homebrew puts gh and jq.
command -v gh >/dev/null 2>&1 || PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# parse_target <target> [repo] -> "owner name number", or nothing when gh has to
# resolve it (a branch name, or a bare number with no repo given).
parse_target() {
    local t="${1#\#}" repo="${2:-}"
    case "$t" in
        https://github.com/*/*/pull/*)
            t="${t#https://github.com/}"
            local owner="${t%%/*}"; t="${t#*/}"
            local name="${t%%/*}"; t="${t#*/pull/}"
            printf '%s %s %s' "$owner" "$name" "${t%%[/?#]*}"
            ;;
        */*\#*[0-9])
            local r="${t%%#*}"
            printf '%s %s %s' "${r%%/*}" "${r#*/}" "${t##*#}"
            ;;
        *[!0-9]*|'') ;;
        *) [ -n "$repo" ] && printf '%s %s %s' "${repo%%/*}" "${repo#*/}" "$t" ;;
    esac
    return 0
}

# ci_state <total> <fail> <cancel> <pending> -> none | failing | pending | green
ci_state() {
    local total="$1" fail="$2" cancel="$3" pending="$4"
    if [ "$total" -eq 0 ]; then printf 'none'
    elif [ "$fail" -gt 0 ] || [ "$cancel" -gt 0 ]; then printf 'failing'
    elif [ "$pending" -gt 0 ]; then printf 'pending'
    else printf 'green'
    fi
}

# next_step <pr_state> <is_draft> <auto_merge_on> -> stop | ask
next_step() {
    if [ "$1" != OPEN ] || [ "$2" = true ]; then printf 'stop'; else printf 'ask'; fi
}

# stop_reason <pr_state> <is_draft> -> one line, empty when nothing stops
stop_reason() {
    if [ "$1" != OPEN ]; then
        printf 'PR is %s, not open.' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    elif [ "$2" = true ]; then
        printf 'PR is a draft; mark it ready for review first.'
    fi
}

# merge_choice <ci_state> <merge_state> <auto_allowed> -> merge-now | automerge
#
# A clean, finished run merges now. Anything else (checks running, a required
# review missing, the branch behind) goes to automerge, which waits for
# GitHub's own requirements instead of guessing when they'll be met.
merge_choice() {
    local ci="$1" merge_state="$2" auto_allowed="$3"
    if [ "$auto_allowed" != true ]; then printf 'merge-now'
    elif { [ "$ci" = green ] || [ "$ci" = none ]; } && [ "$merge_state" = CLEAN ]; then printf 'merge-now'
    else printf 'automerge'
    fi
}

# recommend <unresolved> <ci_state> <merge_state> <auto_allowed> <review_decision>
#   -> not-now | merge-now | automerge
#
# Failing CI, unresolved threads, requested changes or conflicts need a person
# to look first. Without automerge, merge-now is recommended only when it would
# go through.
recommend() {
    local unresolved="$1" ci="$2" merge_state="$3" auto_allowed="$4" review="$5"
    if [ "$unresolved" -gt 0 ] || [ "$ci" = failing ] || [ "$review" = CHANGES_REQUESTED ] \
        || [ "$merge_state" = DIRTY ]; then
        printf 'not-now'
    elif [ "$auto_allowed" = true ] || [ "$merge_state" = CLEAN ]; then
        merge_choice "$ci" "$merge_state" "$auto_allowed"
    else
        printf 'not-now'
    fi
}

# merge_options <recommended> <merge_choice> -> comma-separated, recommended first
merge_options() {
    if [ "$1" = not-now ]; then printf 'not-now,%s' "$2"; else printf '%s,not-now' "$2"; fi
}

# blockers <ci_state> <failing_names> <unresolved> <review_decision> <merge_state>
#   -> one line per thing holding the merge back, empty when none
blockers() {
    local ci="$1" failing="$2" unresolved="$3" review="$4" merge_state="$5"
    [ "$ci" = failing ] && printf 'CI failing: %s\n' "$failing"
    [ "$ci" = pending ] && printf 'CI still running\n'
    [ "$unresolved" -gt 0 ] && printf '%s unresolved review thread(s)\n' "$unresolved"
    case "$review" in
        CHANGES_REQUESTED) printf 'Changes requested\n' ;;
        REVIEW_REQUIRED) printf 'Needs an approving review\n' ;;
    esac
    case "$merge_state" in
        DIRTY) printf 'Merge conflicts with the base branch\n' ;;
        BEHIND) printf 'Branch is behind its base\n' ;;
    esac
    return 0
}
