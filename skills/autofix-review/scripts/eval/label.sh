#!/usr/bin/env bash
# label.sh — derive ground truth for one evaluation case from what happened to
# the PR *after* the commits under review. Pure: sourced by label.test.sh, no
# network, no repo.
#
# The evaluation asks whether autofix-review's verdict on the pre-review commits
# matches what human reviewers actually did about them. Two arms:
#
#   merged  — reviewers saw it and it landed. Did they make the author change it?
#   closed  — it never landed. Why not?
#   seer    — a bot opened it and one named human merged or closed it
#             (a close with no stated reason is EXCLUDED, same as the human arm)
#
# The closed arm exists because the merged arm alone is survivorship bias: a
# change bad enough to be abandoned never appears in it, and those are exactly
# the cases a reject is supposed to catch. The cost is that "why was it closed"
# is only knowable when somebody said so, which is why an unexplained close is
# excluded rather than guessed at.
#
# Labels:
#   ACCEPT_TRUTH  the commits under review stood as written
#   REJECT_TRUTH  a human required them to change, or said why they were wrong
#   AMBIGUOUS     signal exists but does not resolve — for a person to adjudicate
#   EXCLUDED      not judgeable; keep it out of the numbers entirely

# Vocabulary that says a reviewer had a problem with the *change*.
PROBLEM_RE='wrong approach|not the right (fix|approach)|does ?n.?t (actually )?fix|doesn.t address|not the root cause|band-?aid|masks the|papers over|only (fixes|handles) (one|part)|introduces a (bug|regression)|breaks |will break|this is incorrect|misses the|should (instead|rather)|instead we should|not how we|wrong (place|layer|level)'

# Vocabulary that says the change stopped mattering. The code was never judged,
# so it is not evidence about a verdict either way.
MOOT_RE='no longer (needed|relevant)|not needed anymore|stale|obsolete|duplicate of|dupe of|superseded by|closing in favou?r of|fixed elsewhere|fixed by|already (fixed|landed|merged)|out of date|abandon|deprioriti|won.?t fix|wontfix|moved to|reopening as|will redo|opening a (new|fresh)'

# superseded_later <issue-id> <later-commit-subjects-and-bodies>
#
# A merged fix that a LATER commit re-fixes against the same issue was not
# correct — it was merely merged. Found the hard way: the pilot rejected a
# merged Seer PR for guarding a container while the crash was in the unpack one
# line later, and the repo contained a follow-up commit against the same Sentry
# issue saying in as many words that the original diagnosis "wasnt the problem".
# Scored naively that reads as a false reject; it is the label that is wrong.
#
# So `merged` alone is not ACCEPT_TRUTH. It is ACCEPT_TRUTH only if nothing
# afterwards had to fix the same issue again.
superseded_later() {
    local issue="${1-}" later="${2-}"
    [ -n "$issue" ] || return 1
    printf '%s' "$later" | grep -qiF "$issue"
}

# classify_close_comment <text> — problem | moot | none | unclear
#
# Checked problem-first: "superseded by #123 because it fixes the wrong layer"
# is a judgement about this change that happens to mention a replacement, and
# reading it as merely moot would throw away a real reject.
classify_close_comment() {
    local t
    # Strip quoted reply lines FIRST, while newlines still delimit them: a quote
    # of someone else's text is not this commenter's reason for closing. Doing it
    # after the newline collapse made `> [^>]*` run to the end of the comment and
    # swallow the real reason, so a close that quoted anything before explaining
    # itself classified as `none` and the case was silently EXCLUDED.
    t="$(printf '%s' "${1-}" | sed 's/^[[:space:]]*>.*$//' | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
    [ -n "$(printf '%s' "$t" | tr -d '[:space:]')" ] || { printf 'none\n'; return; }
    if printf '%s' "$t" | grep -qE "$PROBLEM_RE"; then printf 'problem\n'; return; fi
    if printf '%s' "$t" | grep -qE "$MOOT_RE"; then printf 'moot\n'; return; fi
    printf 'unclear\n'
}

# label_case <case-json> — prints LABEL<TAB>why
#
# Case shape (built by slice.sh):
#   state                 MERGED | CLOSED
#   review_decision       CHANGES_REQUESTED | APPROVED | REVIEW_REQUIRED | null
#   review_comment_paths  [paths a human review comment was left on]
#   post_review_files     [paths touched by commits pushed after the first review]
#   post_review_commits   count of non-merge commits after the first review
#   close_comments        [{author, body}] — on the closed arm
label_case() {
    local c="$1"
    q() { printf '%s' "$c" | jq -r "$1"; }

    local state decision post_n arm decided_by
    state="$(q '.state // ""')"
    decision="$(q '.review_decision // ""')"
    post_n="$(q '.post_review_commits // 0')"
    arm="$(q '.arm // ""')"
    decided_by="$(q '.decided_by // ""')"

    # ---- the seer arm ------------------------------------------------------
    # A bot opened it; one person decided. That decision IS the label, with none
    # of the inference the other arms need — no joining comments to commits, no
    # reading intent out of review threads.
    #
    # It departs from the other arms in one place worth being explicit about: an
    # unexplained close still counts as a reject here. On a human PR, closing is
    # ambiguous and silence is not evidence. On an autofix PR, closing it *is*
    # the triage verdict — that is what the queue is for — so the close carries
    # meaning that a human PR's close does not. The one exception is a comment
    # saying the change stopped mattering, which is excluded exactly as elsewhere.
    if [ "$arm" = seer ]; then
        [ -n "$decided_by" ] || { printf 'EXCLUDED\tno recorded decider\n'; return; }
        if [ "$state" = MERGED ]; then
            # Merged, but did it hold? A later commit against the same issue
            # says it did not, whatever the merge implied at the time.
            local issue later
            issue="$(q '.issue_id // ""')"
            later="$(q '.later_commits_text // ""')"
            if [ -n "$issue" ] && [ -n "$later" ] && superseded_later "$issue" "$later"; then
                printf 'REJECT_TRUTH\ta later commit re-fixed %s, so the merged fix did not hold\n' "$issue"; return
            fi
            printf 'ACCEPT_TRUTH\t%s merged the autofix\n' "$decided_by"; return
        fi
        # A formal changes-requested review is an explicit human signal and does
        # not need a closing comment to stand. The generic CLOSED branch below
        # checks this too, but the seer branch returns before reaching it.
        if [ "$decision" = CHANGES_REQUESTED ]; then
            printf 'REJECT_TRUTH\t%s requested changes, then it was closed unmerged\n' "$decided_by"; return
        fi
        local n i verdict best=none
        n="$(q '(.close_comments // []) | length')"
        for ((i = 0; i < n; i++)); do
            verdict="$(classify_close_comment "$(q ".close_comments[$i].body // \"\"")")"
            case "$verdict" in
                problem) best=problem; break ;;
                moot)    [ "$best" = none ] && best=moot ;;
                unclear) [ "$best" = none ] && best=unclear ;;
            esac
        done
        if [ "$best" = unclear ]; then
            printf 'AMBIGUOUS\tclosed with a comment that names no reason\n'; return
        fi
        if [ "$best" = moot ]; then
            printf 'EXCLUDED\tclosed because it stopped mattering, not because the fix was wrong\n'; return
        fi
        if [ "$best" = problem ]; then
            printf 'REJECT_TRUTH\t%s closed it with a stated problem in the fix\n' "$decided_by"; return
        fi
        printf 'EXCLUDED\tclosed with no stated reason; not reconstructable, so not ground truth\n'; return
    fi

    if [ "$state" = MERGED ]; then
        # A formal changes-requested review is the least ambiguous signal there
        # is: a human read these commits and said no.
        if [ "$decision" = CHANGES_REQUESTED ]; then
            printf 'REJECT_TRUTH\ta reviewer formally requested changes\n'; return
        fi
        # Otherwise: did a comment on a file lead to a change to that same file?
        # Same-file is the join because it is the one that survives without
        # reading the comment — a follow-up commit elsewhere is usually unrelated
        # work, not a response.
        local overlap
        overlap="$(printf '%s' "$c" | jq -r '
            [ (.review_comment_paths // [])[] as $p
              | select((.post_review_files // []) | index($p)) | $p ] | unique | join(",")')"
        if [ -n "$overlap" ]; then
            printf 'REJECT_TRUTH\ta review comment on %s was followed by a change to it\n' "$overlap"; return
        fi
        if [ "$post_n" -eq 0 ]; then
            printf 'ACCEPT_TRUTH\tthe commits under review merged unchanged\n'; return
        fi
        # Commits landed after review but nothing ties them to reviewer comments.
        # Could be a response, could be the author's own follow-up work.
        printf 'AMBIGUOUS\t%s commit(s) after review, none on a commented file\n' "$post_n"; return
    fi

    if [ "$state" = CLOSED ]; then
        # A changes-requested review on a PR that then died is a reject whatever
        # the closing comment says — or does not say.
        if [ "$decision" = CHANGES_REQUESTED ]; then
            printf 'REJECT_TRUTH\tchanges requested, then closed unmerged\n'; return
        fi
        local n i verdict best="none"
        n="$(q '(.close_comments // []) | length')"
        for ((i = 0; i < n; i++)); do
            verdict="$(classify_close_comment "$(q ".close_comments[$i].body // \"\"")")"
            case "$verdict" in
                problem) best=problem; break ;;
                moot)    [ "$best" = none ] && best=moot ;;
                unclear) [ "$best" = none ] && best=unclear ;;
            esac
        done
        case "$best" in
            problem) printf 'REJECT_TRUTH\tclosed with a stated problem in the change\n'; return ;;
            moot)    printf 'EXCLUDED\tclosed because it stopped mattering; the code was never judged\n'; return ;;
            # The user's rule: with no comment we cannot judge why, so it is not
            # ground truth. Silence is not evidence.
            none)    printf 'EXCLUDED\tclosed with no explanation; not judgeable\n'; return ;;
            unclear) printf 'AMBIGUOUS\tclosed with a comment that names no reason\n'; return ;;
        esac
    fi

    printf 'EXCLUDED\tunknown state: %s\n' "$state"
}

# scoreable <label> — does this case count toward the precision numbers?
scoreable() { case "$1" in ACCEPT_TRUTH|REJECT_TRUTH) return 0 ;; *) return 1 ;; esac; }

# ---- CLI --------------------------------------------------------------------
[ "${BASH_SOURCE[0]}" = "${0}" ] || return 0
set -euo pipefail

IN="${1:--}"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r LABEL WHY < <(label_case "$line")
    printf '%s' "$line" | jq -c --arg l "$LABEL" --arg w "$WHY" '. + {label:$l, label_why:$w}'
done < <([ "$IN" = - ] && cat || cat "$IN")
