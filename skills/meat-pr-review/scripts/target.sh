#!/usr/bin/env bash
# target.sh — pure target-classification helpers for meat-pr-review. No network,
# no repo, no filesystem: given a token, print what kind of thing it names.
#
# Sourced by review.sh (which supplies the GitHub/git facts) and by target.test.sh.
# Kept side-effect-free so every branch of the routing is testable without a
# GitHub token, a checkout, or an LLM key.

# classify_target <token> -> auto | pr | range | ref | unknown
#
#   auto     nothing given: review.sh decides (PR for the current branch, else
#            the local branch diff)
#   pr       a PR number (`121125`, `#121125`) or a github .../pull/N URL
#   range    a git range (`main..HEAD`, `origin/main...my-branch`, `main..`)
#   ref      a bare branch name or SHA — ambiguous on its own, because a branch
#            may or may not have a PR; review.sh resolves it by asking gh
#   unknown  a URL that isn't a pull request: refuse rather than guess
classify_target() {
    local t="${1-}"
    [ -n "$t" ] || { printf 'auto'; return; }

    case "$t" in
        '#'[0-9]*)
            # `#123` is a PR only if the rest is all digits
            case "${t#\#}" in
                *[!0-9]*) printf 'unknown'; return ;;
                *) printf 'pr'; return ;;
            esac
            ;;
    esac

    # all digits -> PR number
    case "$t" in
        *[!0-9]*) : ;;
        *) printf 'pr'; return ;;
    esac

    case "$t" in
        http://*|https://*)
            case "$t" in
                */pull/*) printf 'pr' ;;
                *)        printf 'unknown' ;;
            esac
            return
            ;;
    esac

    # A range check has to come before anything else path-like: `main..HEAD`
    # contains dots but is not a ref. Two dots is git's own spelling, so trust it.
    case "$t" in
        *..*) printf 'range'; return ;;
    esac

    printf 'ref'
}

# pr_number <token> -> the bare number
# Accepts `123`, `#123`, or a .../pull/123[/files|#discussion...] URL. Prints
# nothing and returns 1 when there is no number to take, so callers can die with
# their own message.
pr_number() {
    local t="${1-}" n
    case "$t" in
        http://*|https://*)
            n="${t#*/pull/}"
            n="${n%%/*}"
            n="${n%%\?*}"
            n="${n%%#*}"
            ;;
        '#'*) n="${t#\#}" ;;
        *)    n="$t" ;;
    esac
    case "$n" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$n"
}

# split_range <token> -> base<TAB>head<TAB>dots
#
# Mirrors git's own defaulting: an omitted side means HEAD (`main..` is
# `main..HEAD`, `..main` is `HEAD..main`), and three dots is preserved so the
# caller can hand it straight to `git diff`. Three-dot is the one you usually
# want for a branch — it diffs against the merge base rather than the moving tip.
split_range() {
    local t="${1-}" base head dots
    case "$t" in
        *...*) dots='...'; base="${t%%...*}"; head="${t#*...}" ;;
        *..*)  dots='..';  base="${t%%..*}";  head="${t#*..}" ;;
        *) return 1 ;;
    esac
    printf '%s\t%s\t%s' "${base:-HEAD}" "${head:-HEAD}" "$dots"
}

# resolve_mode <class> <pr_found:yes|no> <forced:auto|pr|local> -> pr | local | unknown
#
# `forced` is --pr/--local on the command line and wins outright: `--local` on a
# branch that does have a PR is a legitimate ask (review what's on disk, including
# work not yet pushed), and it must not silently become a PR review of stale code.
resolve_mode() {
    local class="${1:-auto}" pr_found="${2:-no}" forced="${3:-auto}"

    case "$forced" in
        pr|local) printf '%s' "$forced"; return ;;
    esac

    case "$class" in
        pr)      printf 'pr' ;;
        range)   printf 'local' ;;
        unknown) printf 'unknown' ;;
        auto|ref)
            if [ "$pr_found" = yes ]; then printf 'pr'; else printf 'local'; fi
            ;;
        *) printf 'unknown' ;;
    esac
}
