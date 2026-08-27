# Validation run — getsentry/sentry, 2026-08

One run, on real data, recorded because two of the fixes in this skill only make
sense if you know what produced them. A dated snapshot, not a live document.

**Four merged Seer autofix PRs**, judged at their merge commit under read-only
scoring (no probe wave — that container had no sentry toolchain).

| PR | label | verdict | outcome |
|---|---|---|---|
| [#106834](https://github.com/getsentry/sentry/pull/106834) | merged | accept | agrees |
| [#106831](https://github.com/getsentry/sentry/pull/106831) | merged | accept | agrees |
| [#106483](https://github.com/getsentry/sentry/pull/106483) | merged | accept | agrees |
| [#105306](https://github.com/getsentry/sentry/pull/105306) | merged | **reject (R1)** | **the label was wrong** |

## The one disagreement is the result

[#105306](https://github.com/getsentry/sentry/pull/105306) guarded
`event_data["tags"]` against being `None`, then iterated `for key, value in
tags:` — container guarded, unpack not. `L4b` found the surviving path and the
refuter failed to kill it. Both cited commit `b35b698bd46`
([#105446](https://github.com/getsentry/sentry/pull/105446)), which re-fixes the
same Sentry issue and says:

> Following up on the PR we did with seer there #105306, turns out the `tags`
> themselves being none wasnt the problem, its none elements inside the array
> being broken into `value, key`.

A human merged it; a human later had to fix it again. Scored naively that is a
false reject. It is the ground truth that is wrong — and a harness that punishes
the skill for being right gets "fixed" by tuning the rubric until it stops
finding real defects.

## What it changed

- **`superseded_later`** (`eval/label.sh`) — on the seer arm, merged is
  `ACCEPT_TRUTH` only if no later commit re-fixes the same issue.
- **`divergence_markers`** (`extract.sh`) — #106483's body says "does not
  directly address its root cause", the sentence that converts an `R2` into
  `N4`. It sits in the framing paragraph, which is the *evidence* writer's
  input, so the intent card came back with `divergence_rationale: null` and the
  conversion would have failed silently. Those lines are now extracted
  separately and given to the intent writer wherever they appear.

## What it could not measure

**The reject arm.** Closed Seer PRs carry only a one-line commit subject — the
Root Cause / Solution text lives in the PR *description*, which reaches git only
when a merge squashes it in. Every closed case would land on `N1` for want of
evidence, so this run measured the accept side only. `scripts/eval/RUNBOOK.md`
has the commands for the rest; it needs the GitHub PR API and the toolchain.

Four cases find broken rules. They do not measure precision — that needs 50+,
and the closed arm will always be the thinner half.
