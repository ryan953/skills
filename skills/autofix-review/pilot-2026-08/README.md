# Pilot — getsentry/sentry seer arm, 2026-08

Four merged Seer autofix PRs, judged at their merge commit, read-only scoring
(no probe wave: this container has no sentry toolchain). The cards, link
verdicts and refutations each run produced are kept here as the record.

| PR | label | verdict | codes | outcome |
|---|---|---|---|---|
| [#106834](https://github.com/getsentry/sentry/pull/106834) | merged | accept | — | agrees |
| [#106831](https://github.com/getsentry/sentry/pull/106831) | merged | accept | — | agrees |
| [#106483](https://github.com/getsentry/sentry/pull/106483) | merged | accept | — | agrees |
| [#105306](https://github.com/getsentry/sentry/pull/105306) | merged | **reject** | R1 | **the label was wrong** |

**Reject precision 1/1. Accept precision 3/3.**

## The one disagreement is the result

#105306 guarded `event_data["tags"]` against being `None`, then iterated
`for key, value in tags:` — container guarded, unpack not. `L4b` found the
surviving path, and the refuter failed to kill it. Both cited commit
`b35b698bd46` (#105446), which re-fixes the same Sentry issue and says:

> Following up on the PR we did with seer there #105306, turns out the `tags`
> themselves being none wasnt the problem, its none elements inside the array
> being broken into `value, key`.

So a human merged it, and a human later had to fix it again. Scored naively
that is a false reject; it is the ground truth that is wrong, and
`label.sh`'s `superseded_later` now catches it.

## What the run changed

1. **`superseded_later` in `eval/label.sh`** — merged is ACCEPT_TRUTH only if no
   later commit re-fixes the same issue. Without it the harness punishes the
   skill for being right.
2. **`divergence_markers` in `extract.sh`** — #106483's body says "does not
   directly address its root cause", but that sentence sits in the framing
   paragraph, which is the evidence writer's input. The intent card came back
   with `divergence_rationale: null`, so the N4 conversion would have silently
   failed. The intent writer now gets those lines wherever they appear.

## Caveats

- Read-only: the closing link was reasoned about, not measured. Every verdict is
  marked `scored: read-only` and must not be averaged with probe-scored runs.
- Four cases find broken rules; they do not measure precision. That needs 50+.
- **The reject arm is missing.** Closed Seer PRs carry only a one-line commit
  subject — the Root Cause / Solution text lives in the PR *description*, which
  reaches git only when a merge squashes it in. Every closed case would land on
  N1 for want of evidence, so this pilot measures the accept side only. Running
  the reject arm needs the PR API.
