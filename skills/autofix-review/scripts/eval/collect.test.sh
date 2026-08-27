#!/usr/bin/env bash
# Tests for collect.sh's pure filters — who gets into the sample.
#
# Sample selection is not a detail: let an AI-co-authored PR in and the
# evaluation quietly becomes a test of whether this skill agrees with the model
# that wrote the patch, which is not the question anyone asked.
#
# Run:  skills/autofix-review/scripts/eval/collect.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=collect.sh
. "$SCRIPT_DIR/collect.sh"

PASS=0
FAIL=0
yes_() { if "$@"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$T"; else FAIL=$((FAIL+1)); printf '  FAIL %s (expected included)\n' "$T"; fi; }
no_()  { if "$@"; then FAIL=$((FAIL+1)); printf '  FAIL %s (expected excluded)\n' "$T"; else PASS=$((PASS+1)); printf '  ok   %s\n' "$T"; fi; }

echo "is_human_authored"
T="a plain human";            yes_ is_human_authored ryan953 false ""
T="gh is_bot";                no_  is_human_authored someapp true ""
T="[bot] suffix";             no_  is_human_authored 'dependabot[bot]' false ""
T="seer";                     no_  is_human_authored seer-by-sentry false ""
T="claude co-author trailer"; no_  is_human_authored ryan953 false 'Co-Authored-By: Claude <noreply@anthropic.com>'
T="claude generated-with";    no_  is_human_authored ryan953 false 'Generated with [Claude Code](https://claude.com)'
T="copilot co-author";        no_  is_human_authored ryan953 false 'Co-authored-by: Copilot <x@y>'
T="a human co-author is fine"; yes_ is_human_authored ryan953 false 'Co-Authored-By: Alice <a@b.com>'

echo ""
echo "is_fix_shaped"
T="conventional fix scope";   yes_ is_fix_shaped 'fix(issues): guard null org' 'fix/null-org'
T="bare fix:";                yes_ is_fix_shaped 'fix: crash on empty list' 'x'
T="lint ref";                 yes_ is_fix_shaped 'ref(lint): drop unused imports' 'x'
T="eslint in the title";      yes_ is_fix_shaped 'satisfy eslint no-unused-vars' 'x'
T="typecheck";                yes_ is_fix_shaped 'fix typecheck errors in views' 'x'
T="a revert is a fix";        yes_ is_fix_shaped 'Revert "feat(x): thing"' 'x'
T="branch name alone";        yes_ is_fix_shaped 'tidy up the header' 'bugfix/header'
T="a feature is out of scope"; no_ is_fix_shaped 'feat(dashboards): add widget' 'feat/widget'
T="a plain refactor";          no_ is_fix_shaped 'ref(views): extract a hook' 'ref/hook'
T="docs";                      no_ is_fix_shaped 'docs: update the readme' 'docs/readme'

echo ""
printf 'collect: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
