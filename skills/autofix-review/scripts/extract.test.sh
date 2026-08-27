#!/usr/bin/env bash
# Tests for extract.sh — the pure Wave 0 parsing. No repo, no network.
#
# Run:  skills/autofix-review/scripts/extract.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=extract.sh
. "$SCRIPT_DIR/extract.sh"

PASS=0
FAIL=0

eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$(printf '%s' "$expected" | tr '\n' '|')" \
            "$(printf '%s' "$actual" | tr '\n' '|')"
    fi
}

echo "parse_issue_refs — finds"
eq "sentry org-subdomain url" \
   "sentry	https://sentry.sentry.io/issues/6789012" \
   "$(parse_issue_refs 'Fixes https://sentry.sentry.io/issues/6789012/')"
eq "sentry /organizations/ url" \
   "sentry	https://acme.sentry.io/organizations/acme/issues/42" \
   "$(parse_issue_refs 'see https://acme.sentry.io/organizations/acme/issues/42/')"
eq "sentry short id" \
   "sentry	JAVASCRIPT-2K3F" \
   "$(parse_issue_refs 'Fixes JAVASCRIPT-2K3F in the issues stream')"
eq "linear needs a cue word" \
   "linear	ABC-123" \
   "$(parse_issue_refs 'Fixes ABC-123')"
eq "linear url" \
   "linear	FE-901" \
   "$(parse_issue_refs 'https://linear.app/acme/issue/FE-901/some-title')"
eq "github issues url" \
   "github	https://github.com/getsentry/sentry/issues/70001" \
   "$(parse_issue_refs 'Closes https://github.com/getsentry/sentry/issues/70001')"
eq "owner/repo#n" \
   "github	getsentry/sentry#70001" \
   "$(parse_issue_refs 'related: getsentry/sentry#70001')"
eq "bare #n with a closing cue" \
   "github	#4242" \
   "$(parse_issue_refs 'Fixes #4242')"
eq "dedupes repeats" \
   "github	#4242" \
   "$(parse_issue_refs 'Fixes #4242 and also closes #4242')"

echo ""
echo "parse_issue_refs — does not find"
# A confident verdict about the wrong issue is worse than no verdict, so each of
# these stays silent rather than guessing.
eq "bare #n with no cue"            "" "$(parse_issue_refs 'rolled back in #4242 last week')"
eq "bare ABC-123 with no cue"       "" "$(parse_issue_refs 'the ABC-123 spec says otherwise')"
eq "short hyphenated caps"          "" "$(parse_issue_refs 'uses UTF-8 and TLS-1.3')"
eq "plain prose"                    "" "$(parse_issue_refs 'fix the flaky test in the header')"
eq "empty input"                    "" "$(parse_issue_refs '')"

echo ""
echo "lint_signals"
DIFF_SUPPRESS='--- a/src/a.tsx
+++ b/src/a.tsx
@@
-const x = y.z;
+// eslint-disable-next-line no-unsafe-optional-chaining
+const x = y?.z;'
eq "added eslint-disable" \
   "suppress	eslint: eslint-disable-next-line no-unsafe-optional-chaining" \
   "$(lint_signals "$DIFF_SUPPRESS")"
eq "added ts-expect-error" \
   "suppress	ts: @ts-expect-error" \
   "$(lint_signals '+++ b/a.ts
+// @ts-expect-error narrow later')"
eq "added python noqa" \
   "suppress	py: # noqa" \
   "$(lint_signals '+++ b/a.py
+import os  # noqa')"
eq "eslint config touched" \
   "config	.eslintrc.js" \
   "$(lint_signals '+++ b/.eslintrc.js
+  rules: {}')"
# A removed suppression is the good direction and must not read as one being
# added — this is the difference between satisfying a rule and silencing it.
eq "removed suppression is not a signal" \
   "" \
   "$(lint_signals '--- a/a.ts
+++ b/b.ts
-// eslint-disable-next-line no-console
 console.log(1)' | grep suppress || true)"
eq "clean diff has no signals" "" "$(lint_signals '+++ b/a.ts
+const x = 1;')"

echo ""
echo "body_evidence — evidence written into the description"
eq "a Bug heading" \
   "section	## Bug" \
   "$(body_evidence '## Bug

start.sh passed the wrong base.')"
eq "a Root cause heading" \
   "section	## Root cause" \
   "$(body_evidence '## Root cause

the ref was the tip, not the fork point')"
eq "a js stack frame" \
   "stack	js frame    at useThing (" \
   "$(body_evidence '    at useThing (bar.tsx:88)')"
eq "a python traceback" \
   "stack	Traceback (most recent call last)" \
   "$(body_evidence 'Traceback (most recent call last):')"
eq "an error line" \
   "stack	TypeError:" \
   "$(body_evidence 'TypeError: cannot read id of undefined')"
eq "a repro marker" \
   "repro	Reproduced today on staging with an empty org" \
   "$(body_evidence 'Reproduced today on staging with an empty org')"

echo ""
echo "body_evidence — deliberately narrow"
# Loose causal prose appears in nearly every commit message. Accepting it would
# hollow out the N1 guard that stops a review being anchored to nothing, so it
# has to not fire.
eq "causal prose alone"       "" "$(body_evidence 'this was broken because the ref was wrong, so instead we use the fork point')"
eq "a plain summary"          "" "$(body_evidence '## Summary

Tidies up the header. No behaviour change.')"
eq "a test-plan heading"      "" "$(body_evidence '## Test plan

ran the suite')"
eq "the word bug in prose"    "" "$(body_evidence 'this fixes a bug in the header')"
eq "empty"                    "" "$(body_evidence '')"

echo ""
echo "classify_mode"
eq "lint title, no issue"        lintfix "$(classify_mode 'ref(lint): drop unused imports' 3 0)"
eq "eslint title, no issue"      lintfix "$(classify_mode 'fix eslint no-unused-vars' 1 0)"
# The linked issue wins: it is the strongest input we have, and judging this as
# a lint fix would discard it.
eq "lint title but issue linked" bugfix  "$(classify_mode 'ref(lint): drop unused imports' 3 2)"
eq "suppressions, no issue"      lintfix "$(classify_mode 'chore: tidy' 2 0)"
eq "suppressions with an issue"  bugfix  "$(classify_mode 'chore: tidy' 2 1)"
eq "plain fix"                   bugfix  "$(classify_mode 'fix(issues): guard null org' 0 1)"
eq "nothing at all"              bugfix  "$(classify_mode 'wip' 0 0)"
eq "typecheck title"             lintfix "$(classify_mode 'fix typecheck errors' 0 0)"

echo ""
echo "changed_files"
eq "post-image paths only" \
   "src/a.tsx
src/b.tsx" \
   "$(changed_files '--- a/src/a.tsx
+++ b/src/a.tsx
--- a/src/b.tsx
+++ b/src/b.tsx')"
eq "skips /dev/null (deletions)" \
   "src/a.tsx" \
   "$(changed_files '--- a/src/gone.tsx
+++ /dev/null
--- a/src/a.tsx
+++ b/src/a.tsx')"

echo ""
echo "doc_candidates"
eq "walks up one path, shallowest first" \
   "CLAUDE.md
AGENTS.md
CONVENTIONS.md
CONTRIBUTING.md
static/CLAUDE.md
static/AGENTS.md
static/CONVENTIONS.md
.claude/skills
.cursor/rules
docs/CONTRIBUTING.md
static/app/CLAUDE.md
static/app/AGENTS.md
static/app/CONVENTIONS.md" \
   "$(doc_candidates static/app/foo.tsx)"
eq "a root-level file still yields the root names" \
   "CLAUDE.md
AGENTS.md
CONVENTIONS.md
CONTRIBUTING.md
.claude/skills
.cursor/rules
docs/CONTRIBUTING.md" \
   "$(doc_candidates foo.ts)"

echo ""
printf 'extract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
