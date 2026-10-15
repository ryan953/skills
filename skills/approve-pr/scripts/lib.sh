#!/usr/bin/env bash
# lib.sh — shared helpers and the pure decision functions for approve-pr.
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
#
# Resolving locally skips a `gh pr view` round trip for the common forms.
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

# classify_author <me> <login> <typename> <head_ref> -> mine | bot | other
#
# `__typename == Bot` only covers GitHub App identities. Some automation pushes
# through ordinary user accounts, so the login list and the conventional branch
# prefixes back it up. `mine` is checked first so my own `seer/...` branch isn't
# misread as a bot's.
classify_author() {
    local me="$1" login="$2" typename="$3" head_ref="${4:-}"
    if [ -n "$me" ] && [ "$login" = "$me" ]; then printf 'mine'; return; fi
    if [ "$typename" = Bot ]; then printf 'bot'; return; fi
    case "$login" in
        *'[bot]'|seer-by-sentry|sentry-autofix|dependabot|renovate|github-actions)
            printf 'bot'; return ;;
    esac
    case "$head_ref" in
        seer/*|autofix/*|renovate/*|dependabot/*) printf 'bot'; return ;;
    esac
    printf 'other'
}

# fixup_approval_ok <author> <repo> <my_commits> -> yes | no
#
# Approving a PR that carries my own commits is only allowed for a known bot in a
# getsentry repo. The check lives here rather than in the question text, because
# the question is written by the agent and can't vouch for who authored the PR.
FIXUP_BOTS="sentry[bot] sentry-junior[bot] dependabot[bot] renovate[bot] github-actions[bot]"
fixup_approval_ok() {
    local author="$1" repo="$2" mine="$3" b
    [ "$mine" -eq 0 ] && { printf 'yes'; return; }
    case "$repo" in getsentry/*) ;; *) printf 'no'; return ;; esac
    for b in $FIXUP_BOTS; do
        [ "$author" = "$b" ] && { printf 'yes'; return; }
    done
    printf 'no'
}

# comment_ok <text> -> yes | no
#
# The approval comment is posted verbatim, so it must not double as a command to
# other automation: a slash command on its own line, an @sentry mention (Seer and
# the other Sentry bots act on those), or a keyword that closes an issue on merge.
comment_ok() {
    if printf '%s\n' "${1-}" | grep -Eiq \
        '^[[:space:]]*/[a-z]|@sentry|(^|[^a-z])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]:]+([a-z0-9_.-]+/[a-z0-9_.-]+)?#[0-9]+'; then
        printf 'no'
    else
        printf 'yes'
    fi
}

# next_step <pr_state> <class> <my_approval> <auto_merge_on> -> stop | done | ask | apply
#
# An existing approval only drops the comment question: a bot PR still needs its
# label and merge decision. `apply` is a bot PR with nothing left to ask that may
# still be missing its ready state or label.
next_step() {
    local state="$1" class="$2" approved="$3" auto_on="$4"
    if [ "$state" != OPEN ] || [ "$class" = mine ]; then printf 'stop'; return; fi
    if [ "$class" != bot ]; then
        if [ "$approved" = yes ]; then printf 'done'; else printf 'ask'; fi
        return
    fi
    if [ "$approved" = yes ] && [ "$auto_on" = yes ]; then printf 'apply'; else printf 'ask'; fi
}

# ask_merge <class> <auto_merge_on> -> yes | no
ask_merge() {
    if [ "$1" = bot ] && [ "$2" != yes ]; then printf 'yes'; else printf 'no'; fi
}

# stop_reason <pr_state> <class> <my_approval> -> one line, empty when nothing stops
stop_reason() {
    local state="$1" class="$2" approved="$3"
    if [ "$state" != OPEN ]; then
        printf 'PR is %s, not open.' "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
    elif [ "$class" = mine ]; then
        printf 'This is your own PR; GitHub does not allow approving it.'
    elif [ "$approved" = yes ] && [ "$class" != bot ]; then
        printf 'Already approved by you; nothing else to do for a human-authored PR.'
    fi
}

# requeue_dispatch <checks_json> <label_will_queue> -> checks_json
#
# A push strips the getsentry label and fails `getsentry dispatch`, and a rerun
# replays that stale event. Adding the label fires a fresh run, so when that is
# about to happen the old failure counts as pending instead of blocking the merge.
requeue_dispatch() {
    if [ "$2" != yes ]; then printf '%s' "$1"; return; fi
    printf '%s' "$1" | jq -c 'map(if .name == "getsentry dispatch" and (.bucket == "fail" or .bucket == "cancel")
                                   then .bucket = "pending" else . end)'
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

# merge_choice <ci_state> <merge_state> <auto_allowed> [label_will_queue]
#   -> merge-now | automerge
#
# The one merge option the question offers. It is asked before approving, so this
# predicts the state after the follow-through: a label about to be added queues
# new checks, which makes a green run pending. Anything short of a clean, finished
# run goes to automerge, which waits for GitHub's own requirements instead of
# guessing when they'll be met.
merge_choice() {
    local ci="$1" merge_state="$2" auto_allowed="$3" label="${4:-no}"
    if [ "$auto_allowed" != true ]; then printf 'merge-now'
    elif [ "$label" = yes ]; then printf 'automerge'
    elif { [ "$ci" = green ] || [ "$ci" = none ]; } && [ "$merge_state" = CLEAN ]; then printf 'merge-now'
    else printf 'automerge'
    fi
}

# recommend <unresolved_threads> <ci_state> <merge_state> <auto_allowed> [label_will_queue]
#   -> not-now | merge-now | automerge
#
# Unresolved threads or failing CI need a person to look first. Without automerge,
# merge-now is still offered, but recommended only when it would go through.
recommend() {
    local unresolved="$1" ci="$2" merge_state="$3" auto_allowed="$4" label="${5:-no}"
    if [ "$unresolved" -gt 0 ] || [ "$ci" = failing ]; then printf 'not-now'
    elif [ "$auto_allowed" = true ] || [ "$(merge_choice "$ci" "$merge_state" true "$label")" = merge-now ]; then
        merge_choice "$ci" "$merge_state" "$auto_allowed" "$label"
    else printf 'not-now'
    fi
}

# merge_options <recommended> <merge_choice> -> comma-separated, recommended first
merge_options() {
    if [ "$1" = not-now ]; then printf 'not-now,%s' "$2"; else printf '%s,not-now' "$2"; fi
}

# summary <ci_state> <pass> <fail> <pending> <skipping> <failing_names>
#         <unresolved> <thread_lines> [label: no | yes | rerun]
#
# `rerun` means the label will also replace a failed `getsentry dispatch`.
#
# `skipping` is reported apart from `pass`: path-filtered suites report it, and
# folding it in would claim tests ran that didn't.
summary() {
    local ci="$1" pass="$2" fail="$3" pending="$4" skipping="$5" failing="$6"
    local unresolved="$7" threads="$8" label="${9:-no}"
    printf 'CI: %s (%s pass, %s fail, %s pending, %s skipping)' \
        "$ci" "$pass" "$fail" "$pending" "$skipping"
    [ -n "$failing" ] && printf '\nFailing: %s' "$failing"
    case "$label" in
        yes)   printf '\nAdding the getsentry label will queue more checks.' ;;
        rerun) printf '\ngetsentry dispatch failed before; the new label will run it again.' ;;
    esac
    if [ "$unresolved" -gt 0 ]; then
        printf '\nUnresolved review threads: %s\n%s' "$unresolved" "$threads"
    else
        printf '\nNo unresolved review threads.'
    fi
}
