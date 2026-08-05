#!/usr/bin/env bash
# classify.sh — pure decision functions for local-pr-review. No network, no tmux,
# no filesystem: given facts, print a decision. Kept side-effect-free so
# classify.test.sh can exercise every branch without a GitHub token or a repo.
#
# Sourced by pr-context.sh (which supplies the facts) and by the test.

# classify_author <me> <login> <is_bot> <head_branch> -> mine | bot | other
#
# `mine` is checked first and wins outright: a login equal to the authenticated
# user is authoritative, and testing it first keeps the branch-prefix heuristic
# below from misreading my own `seer/...` branch as a bot's.
#
# Bot detection is deliberately broader than GitHub's `author.is_bot`, which is
# only true for App/Actions identities. Plenty of automation pushes through an
# ordinary user account (`seer-by-sentry`, `renovate`), so a login list and the
# conventional branch prefixes back it up. Adding a login to $LPR_BOT_LOGINS
# (space/comma separated) extends the list without editing this file.
classify_author() {
    local me="$1" login="$2" is_bot="$3" head_branch="${4:-}"
    local extra="${LPR_BOT_LOGINS:-}"

    # unknown author (e.g. no PR yet) with no login to compare: caller decides
    [ -n "$login" ] || { printf 'other'; return; }

    if [ -n "$me" ] && [ "$login" = "$me" ]; then
        printf 'mine'; return
    fi
    if [ "$is_bot" = "true" ]; then
        printf 'bot'; return
    fi
    case "$login" in
        *'[bot]') printf 'bot'; return ;;
    esac
    local b
    for b in seer-by-sentry sentry-autofix dependabot renovate github-actions \
             codecov-commenter $(printf '%s' "$extra" | tr ',' ' '); do
        [ -n "$b" ] || continue
        if [ "$login" = "$b" ]; then printf 'bot'; return; fi
    done
    case "$head_branch" in
        seer/*|autofix/*|renovate/*|dependabot/*) printf 'bot'; return ;;
    esac
    printf 'other'
}

# wants_desc_pane <class> -> yes | no
# The PR description goes in its own pane for work I did not write — for my own
# branch I already know the intent, and the pane would only cost diff height.
wants_desc_pane() {
    case "$1" in
        bot|other) printf 'yes' ;;
        *)         printf 'no' ;;
    esac
}

# wants_review_panes <class> -> yes | no
# Someone else's PR: I read the automated findings alongside the code, so they
# get panes. My own or a bot's: the agent consumes the findings and acts on them,
# so panes would just be output I have to close.
wants_review_panes() {
    case "$1" in
        other) printf 'yes' ;;
        *)     printf 'no' ;;
    esac
}

# annotation_route <class> <has_pr> -> apply | comment
# Annotations on someone else's PR are review comments on GitHub; on my own or a
# bot's they are work orders to apply locally. With no PR there is nowhere to
# post, so local edits are the only option regardless of class.
annotation_route() {
    local class="$1" has_pr="${2:-yes}"
    if [ "$has_pr" != "yes" ]; then printf 'apply'; return; fi
    case "$class" in
        other) printf 'comment' ;;
        *)     printf 'apply' ;;
    esac
}

# iterate_ok <class> -> yes | no
# The fix-and-re-review loop only makes sense where this skill is allowed to
# change the code: my own branch/PR, or a bot's.
iterate_ok() {
    case "$1" in
        mine|bot) printf 'yes' ;;
        *)        printf 'no' ;;
    esac
}

# annotation_kind <text> -> question | directive
#
# revdiff's own convention, mirrored here so the router doesn't have to re-derive
# it: `??` anywhere, or an opening question word, means "answer me", not "change
# this". Questions are answered in chat and never become GitHub comments or edits
# — posting my own question to the author's PR as a review comment would be a
# different act than asking it, and applying it as an edit would be nonsense.
annotation_kind() {
    local t
    t="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')"
    case "$t" in
        *'??'*) printf 'question'; return ;;
    esac
    case "$t" in
        explain*|remind*|describe*|clarify*|'what is'*|'what are'*|"what's"*|\
        'how does'*|'how do'*|'why is'*|'why does'*|'why '*) printf 'question'; return ;;
    esac
    printf 'directive'
}

# normalize_tier <text> -> trivial | small | medium | large | risky
#
# The complexity call comes back from a Haiku subagent, so accept the words it
# plausibly uses and collapse them onto the five tiers the plan is written for.
# Anything unrecognized becomes `medium`: a wrong guess there over-reviews a
# small PR (cheap) instead of under-reviewing a large one (expensive).
normalize_tier() {
    local t
    t="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]"')"
    case "$t" in
        trivial|tiny|xs|noop)                  printf 'trivial' ;;
        small|simple|low|s)                    printf 'small' ;;
        medium|moderate|mid|m)                 printf 'medium' ;;
        large|big|complex|high|l|xl)           printf 'large' ;;
        risky|dangerous|critical|security|sensitive) printf 'risky' ;;
        *)                                     printf 'medium' ;;
    esac
}

# plan_skills <tier> <class> <frontend:yes|no> -> one skill name per line
#
# The whole point of a fixed table: depth is a function of the change, not of how
# thorough the agent feels. Two rules shape it beyond size —
#   * `simplify` and every other fix-applying skill are gated on class, because
#     rewriting someone else's PR is not reviewing it.
#   * frontend diffs add `frontend-conventions` at every tier above trivial;
#     convention drift is exactly what a correctness-focused pass misses.
# `meat-pr-review` earns its place from `medium` up: it abridges a long diff to
# the parts worth a human's attention, which is only a win once the diff is long.
plan_skills() {
    local tier="$1" class="${2:-mine}" frontend="${3:-no}"
    local mine=no
    case "$class" in mine|bot) mine=yes ;; esac

    case "$tier" in
        trivial)
            # Nothing. A read of the diff is the review; the caller says so.
            ;;
        small)
            printf 'review\n'
            [ "$frontend" = yes ] && printf 'frontend-conventions\n'
            ;;
        medium)
            printf 'review\n'
            printf 'meat-pr-review\n'
            [ "$frontend" = yes ] && printf 'frontend-conventions\n'
            [ "$mine" = yes ] && printf 'simplify\n'
            ;;
        large)
            printf 'deep-pr-review\n'
            printf 'meat-pr-review\n'
            [ "$frontend" = yes ] && printf 'frontend-conventions\n'
            [ "$mine" = yes ] && printf 'simplify\n'
            ;;
        risky)
            printf 'deep-pr-review\n'
            printf 'review\n'
            printf 'meat-pr-review\n'
            [ "$frontend" = yes ] && printf 'frontend-conventions\n'
            [ "$mine" = yes ] && printf 'simplify\n'
            ;;
    esac
    return 0
}

# skill_runner <skill> -> script | skill
# `meat-pr-review` is a CLI wrapped in a script, so the harness can run and cache
# it without a subagent. Everything else is a Claude skill the model invokes.
skill_runner() {
    case "$1" in
        meat-pr-review) printf 'script' ;;
        *)              printf 'skill' ;;
    esac
}

# skill_mutates <skill> -> yes | no
# Skills that edit code rather than report on it. Never planned for another
# human's PR (plan_skills enforces it); flagged here so the caller can also
# refuse one passed explicitly with --add.
skill_mutates() {
    case "$1" in
        simplify|frontend-conventions-fix) printf 'yes' ;;
        *)                                 printf 'no' ;;
    esac
}
