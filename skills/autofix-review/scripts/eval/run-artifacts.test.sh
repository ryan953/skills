#!/usr/bin/env bash
# Does run.sh clear a previous run's artifacts before it re-reviews a case?
#
# It did not. gather.sh only `mkdir -p`s cards/, links/, refutations/ and
# probes/, and nothing removed what was already in them, so a second run over
# the same work root read the FIRST run's cards back and verdict-rule.sh scored
# them as if they were new. Change the taxonomy, rerun, and you measure the old
# skill while believing you measured the new one -- silently, because a full set
# of artifacts is exactly what a successful run looks like.
#
# --print-briefs is used so the test needs no `claude` binary: it exercises
# prepare_case, which is where the clearing happens.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-runart.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
eq() {
    if [ "$3" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi
}

REPO="$T/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
printf 'function read(o) { return o.id; }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm 'init'
printf 'function read(o) { return o ? o.id : null; }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm 'fix: guard null'
SHA="$(git -C "$REPO" rev-parse HEAD)"

# The body carries an issue reference on purpose. Without one the case is
# anchorless, the precheck settles it as N1 before any review is dispatched, and
# no brief is written at all -- so the brief assertions below would pass
# vacuously against a case that was never reviewed.
CASES="$T/labelled.jsonl"
jq -nc --arg sha "$SHA" '{pr:1, label:"ACCEPT_TRUTH", state:"MERGED", arm:"seer",
    head_sha_at_review:$sha, base_ref:"main",
    body:"Fixes SENTRY-1A2B.\n\n## Bug\nNull read on o.id, stack trace attached."}' > "$CASES"

WORK_ROOT="$T/wr"
mkdir -p "$WORK_ROOT/pr-1/cards" "$WORK_ROOT/pr-1/links" "$WORK_ROOT/pr-1/refutations"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/cards/intent.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/links/L1.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/refutations/L1.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/facts.json"

"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --out "$T/preds.jsonl" >/dev/null 2>&1

eq "a stale card is cleared"       "" "$(cat "$WORK_ROOT/pr-1/cards/intent.json" 2>/dev/null)"
eq "a stale link is cleared"       "" "$(cat "$WORK_ROOT/pr-1/links/L1.json" 2>/dev/null)"
eq "a stale refutation is cleared" "" "$(cat "$WORK_ROOT/pr-1/refutations/L1.json" 2>/dev/null)"
eq "stale facts.json is cleared"   "" "$(cat "$WORK_ROOT/pr-1/facts.json" 2>/dev/null)"
# Clearing must not take the gathered inputs with it; the review needs those.
eq "gathered inputs survive"       "yes" \
   "$([ -s "$WORK_ROOT/pr-1/meta.json" ] && echo yes || echo no)"

# --keep-artifacts exists for resuming a run that died part way through.
printf '{"stale":true}' > "$WORK_ROOT/pr-1/cards/intent.json"
"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --keep-artifacts --out "$T/preds2.jsonl" >/dev/null 2>&1
eq "--keep-artifacts keeps them" '{"stale":true}' \
   "$(cat "$WORK_ROOT/pr-1/cards/intent.json" 2>/dev/null)"

# Probes are off unless asked for, so the brief must say so.
grep -q 'SKIP Wave 3' "$T/preds.jsonl" 2>/dev/null \
  && eq "probes are off by default" "yes" "yes" \
  || eq "probes are off by default" "yes" "no (brief did not skip Wave 3)"
"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --probes --out "$T/preds3.jsonl" >/dev/null 2>&1
grep -q 'Wave 3 (probes)' "$T/preds3.jsonl" 2>/dev/null \
  && eq "--probes turns them on" "yes" "yes" \
  || eq "--probes turns them on" "yes" "no (brief did not ask for Wave 3)"

# A work root that outlives a change to the sample must not review the wrong
# commit. The tree is reused to save a full checkout; it has to be moved first.
git -C "$WORK_ROOT/pr-1/tree" checkout -q --detach HEAD~1 2>/dev/null
"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --out "$T/preds4.jsonl" >/dev/null 2>&1
eq "a reused tree is moved to this case's commit" "$SHA" \
   "$(git -C "$WORK_ROOT/pr-1/tree" rev-parse HEAD 2>/dev/null)"

# The review must be dispatched with EMPTY stdin. review_one runs inside
# `while read ... done < "$CASES"`, and `claude -p` reads stdin even when given
# a prompt argument -- it appends it. That sent the whole labelled.jsonl with
# every brief (2.8MB, ~1.2M tokens against a 1M limit), so every review died on
# its first turn and wrote nothing, and the empty card directories were then
# read as N1. A stub `claude` on PATH records what it really receives.
STUB="$T/bin"
mkdir -p "$STUB"
cat > "$STUB/claude" <<'STUBEOF'
#!/usr/bin/env bash
# Record the prompt and whatever arrived on stdin, then write one card so the
# caller sees a review that produced something.
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' "$prompt" > "$STUB_OUT/prompt.txt"
cat >> "$STUB_OUT/stdin.txt"
work="$(printf '%s' "$prompt" | sed -n 's/.*inputs in \([^ .]*\).*/\1/p' | head -1)"
[ -n "$work" ] && mkdir -p "$work/cards" && printf '{"ok":true}' > "$work/cards/intent.json"
STUBEOF
chmod +x "$STUB/claude"
export STUB_OUT="$T/stubout"; mkdir -p "$STUB_OUT"

# TWO cases, and --jobs 1. With a single case the read loop is already at EOF by
# the time the review is dispatched, so nothing is left on stdin to leak and the
# check passes whether or not the bug is present. The leak only shows when a
# later case is still unread -- which is every real run.
CASES2="$T/labelled2.jsonl"
jq -nc --arg sha "$SHA" '{pr:1, label:"ACCEPT_TRUTH", state:"MERGED", arm:"seer",
    head_sha_at_review:$sha, base_ref:"main",
    body:"Fixes SENTRY-1A2B.\n\n## Bug\nNull read on o.id, stack trace attached."}' > "$CASES2"
jq -nc --arg sha "$SHA" '{pr:2, label:"ACCEPT_TRUTH", state:"MERGED", arm:"seer",
    head_sha_at_review:$sha, base_ref:"main",
    body:"Fixes SENTRY-9Z9Z.\n\n## Bug\nSecond case, present so stdin is not at EOF."}' >> "$CASES2"

rm -rf "$WORK_ROOT/pr-1/cards"
PATH="$STUB:$PATH" "$RUN" --cases "$CASES2" --repo-path "$REPO" --work-root "$WORK_ROOT" \
    --jobs 1 --out "$T/preds5.jsonl" >/dev/null 2>&1

eq "the review is dispatched with empty stdin" "0" \
   "$(wc -c < "$STUB_OUT/stdin.txt" 2>/dev/null | tr -d ' ')"
eq "the prompt is the brief, not the case file" "yes" \
   "$([ "$(wc -c < "$STUB_OUT/prompt.txt" 2>/dev/null | tr -d ' ')" -lt 4000 ] && echo yes || echo no)"
eq "no case JSON leaked into the prompt" "" \
   "$(grep -o 'ACCEPT_TRUTH' "$STUB_OUT/prompt.txt" 2>/dev/null | head -1)"

printf 'run-artifacts: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
