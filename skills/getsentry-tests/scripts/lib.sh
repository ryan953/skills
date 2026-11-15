#!/usr/bin/env bash
# lib.sh — helpers and pure decision functions for getsentry-tests. Sourced,
# never run; lib.test.sh covers the decisions without the network.

sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# The label getsentry's dispatch workflow in getsentry/sentry listens for. Only
# sentry has that workflow, so it is the one repo this skill labels.
TEST_LABEL="Trigger: getsentry tests"
SENTRY_REPO="getsentry/sentry"

# parse_target <target> [repo] -> "owner name number", or nothing when gh has to
# resolve it. A bare number means getsentry/sentry, the only repo this labels.
parse_target() {
    local t="${1#\#}" repo="${2:-$SENTRY_REPO}"
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
        *) printf '%s %s %s' "${repo%%/*}" "${repo#*/}" "$t" ;;
    esac
    return 0
}

# next_step <repo> <state> <has_label> <is_fork> <rerun> -> stop | ask | apply
#
# The label runs getsentry's CI, with its secrets, on the PR's code, so a PR
# from a fork is asked about first. A push strips the label, so a present label
# means the current head was already sent; --rerun takes it off and puts it
# back to send it again.
next_step() {
    local repo="$1" state="$2" has="$3" fork="$4" rerun="$5"
    if [ "$repo" != "$SENTRY_REPO" ] || [ "$state" != OPEN ]; then printf 'stop'
    elif [ "$has" = yes ] && [ "$rerun" != yes ]; then printf 'stop'
    elif [ "$fork" = true ]; then printf 'ask'
    else printf 'apply'
    fi
}

# stop_reason <repo> <state> <has_label> <rerun> -> one line, empty when none
stop_reason() {
    local repo="$1" state="$2" has="$3" rerun="$4"
    if [ "$repo" != "$SENTRY_REPO" ]; then
        printf '%s has no getsentry dispatch workflow; the label only works on %s.' "$repo" "$SENTRY_REPO"
    elif [ "$state" != OPEN ]; then
        printf 'PR is %s, not open.' "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
    elif [ "$has" = yes ] && [ "$rerun" != yes ]; then
        printf 'Already labelled "%s" at this head. Run /getsentry-tests <pr> --rerun to send it again.' "$TEST_LABEL"
    fi
}
