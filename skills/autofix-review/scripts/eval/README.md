# The precision harness

The skill claims that when it says `accept` or `reject`, you can act on it
without re-reading the diff. This measures whether that is true, against the only
yardstick that matters: **what human reviewers actually did**.

## The idea

Take PRs written by people (no AI co-author), find the commits that existed
before the first human review, and judge *those* — blind to the review. Then
compare the verdict against what the reviewers went on to do.

```
collect.sh  →  slice.sh  →  label.sh  →  run.sh  →  score.sh
 which PRs     what did      what did     our        the two
 count         a reviewer    they do      verdict    numbers
               first see     about it
```

## The seer arm (start here)

A Seer/autofix PR that one person merged or closed is the sharpest ground truth
available, and the closest match to what this skill is actually for:

- The chain exists by construction — a Sentry issue, an RCA, a stated fix. No
  hunting for a linked issue that may not be there.
- **The decision is explicit.** Merged means the reviewer accepted the autofix;
  closed unmerged means they rejected it. No inferring intent from review
  comments, no joining a comment to a later commit.

```bash
$E/collect.sh --repo getsentry/sentry --arm seer \
  --bot-author app/seer-by-sentry --decider ryan953 --limit 60 --out raw.jsonl
```

It inverts the human-authorship filter on purpose: the *code* being bot-written
is the point. What makes it ground truth is that the *judgement* was a human's,
which is why `--decider` drops anything decided by somebody else or by
automation.

One rule differs from the other arms and is worth knowing before you read the
numbers: **an unexplained close still counts as a reject here.** On a human PR,
closing is ambiguous and silence is not evidence; on an autofix PR, closing it
*is* the triage verdict — that is what the queue is for. The carve-out survives:
a closing comment saying the fix stopped mattering is still `EXCLUDED`, because
the code was never judged. Every label prints its reason, so scan them before
trusting the matrix.

## Two more arms, for human-written code

**Merged.** Reviewers saw it, it landed. Did they make the author change it?

**Closed, unmerged.** It never landed. Why not?

The merged arm alone is survivorship bias — a change bad enough to be abandoned
never appears in it, and those are exactly the cases a reject is supposed to
catch. So the closed arm is where the cleanest reject signal lives: nobody has to
be diplomatic about a PR that is not going to merge.

The cost is that "why was it closed" is only knowable when somebody said so.
`label.sh` reads the closing comments and sorts them into *a problem with the
change* (`REJECT_TRUTH`), *it stopped mattering* (`EXCLUDED` — the code was never
judged), and *no reason given* (`EXCLUDED` — we cannot judge why, and silence is
not evidence).

## Running it

```bash
cd ~/code/sentry   # or wherever the clone is

E=~/code/skills/skills/autofix-review/scripts/eval

$E/collect.sh --repo getsentry/sentry --label Frontend --arm both --limit 60 \
  --since 2025-01-01 --out raw.jsonl      # or --arm seer, above; --arm all for both
$E/slice.sh   --repo getsentry/sentry --from raw.jsonl --out sliced.jsonl
$E/label.sh   sliced.jsonl > labelled.jsonl

# check the labels before trusting any number they produce
jq -r '[.pr, .arm, .label, .label_why] | @tsv' labelled.jsonl | column -t -s$'\t'

$E/run.sh   --cases labelled.jsonl --repo-path ~/code/sentry --out predictions.jsonl
$E/score.sh --predictions predictions.jsonl --by-arm --reasons reasons.tsv
```

Where there is no `claude` binary (an agent session driving this itself), use
`run.sh --print-briefs`: it prepares each case's worktree and gathered inputs and
emits one dispatch brief per line, for the caller to fan out. Add `--read-only`
when the probe wave cannot run; `score.sh` will refuse to let you forget, and
those cases are labelled `scored: read-only` in the output.

## Reading the result

**Reject precision** — of the changes we rejected, how many did a human also
reject. **Accept precision** — of the ones we accepted, how many stood as
written. Both are reported per arm, because the arms have different base rates.

`needs-human` is counted separately and never folded into either. It is the
designed fallback, not a wrong answer; scoring it as a miss would create pressure
to guess, and a reviewer that guesses is the thing this whole design is arranged
to avoid.

`--reasons` writes the true rejects side by side with what the human actually
said. **Read that file by hand.** Agreeing on "reject" for the wrong reason is a
miss the confusion matrix cannot see, and it is the most common way a rubric
looks better than it is.

The false-rejects-by-code breakdown is the actionable half: a false reject is a
bug in one taxonomy code, and the fix belongs in that code's definition or in the
brief of the validator that produced it — not in the verdict rule.

## What these numbers are not

- **Not a statistical claim at pilot size.** 20–25 cases finds broken rules; it
  does not measure precision. That needs 50+, and more on the closed arm, which
  is always the thinner one.
- **Reviewer nits are counted as rejects by the labels, and are deliberately not
  rejects to this skill.** They will show up as false accepts. Adjudicate them
  out by hand before drawing a conclusion; that is the one step no script here
  can do for you.
- **PR bodies get edited after review.** `gh` exposes no body history, so the
  `intent` card sometimes reads a description written *after* the feedback it is
  supposed to be judged against. It biases toward accept.
- **Sentry issue state is today's, not the state at review time** — volume,
  resolution, regression status have all moved.
- **The closed arm over-represents changes bad enough to abandon**, which is not
  the same distribution as changes that were merely revised.
- **The seer arm measures agreement with one person.** That is the right target
  if the skill is meant to triage their queue, and the wrong one if you want a
  verdict a whole team would sign off on.
