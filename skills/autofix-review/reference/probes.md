# Probe tests

A probe is a throwaway test written to settle one question: **does the failure in
the evidence card still happen after this change?** It is the only part of this
skill that executes code, and it is what turns the closing link from a reading
into a measurement.

## The base-must-fail gate

```
run the probe against BASE (pre-change)  →  it MUST fail
run the probe against HEAD (post-change) →  now the result means something
```

| base | head | outcome | what it means |
|---|---|---|---|
| fail | pass | `proven` | The change fixes the failure. Strongest possible `accept`. |
| fail | fail | `proven-reject` | The change does not fix the failure. Strongest possible `reject` (`R1`). |
| pass | — | `invalid` | **The probe is wrong, not the code.** Discard it. |
| error | — | `unprovable` | Couldn't build or run. Not evidence of anything. |

**A probe that passes on base is discarded, never reported.** It means the repro
is wrong or the evidence/RCA card misdescribed the mechanism — so it is a signal
about our own inputs, not about the diff. Mark `L1` as `unsupported` and move on.
Skipping this gate is how a test suite full of green checkmarks proves nothing:
a test that would have passed before the change tells you the change did nothing
you can see.

`unprovable` is not a soft failure either. It routes to `N3` when a link depends
on it, because "we couldn't check" and "we checked and it's fine" are different
claims and only one of them earns an accept.

## Derive the probe from the card, not from the code

Read `cards/evidence.json` and `cards/rca.json`. The test comes from there:

- `evidence.preconditions[]` → the arrange block
- `rca.mechanism` → the act that triggers it
- `evidence.symptom` → the assertion

Reading the diff to decide what to test inverts the whole exercise: you end up
testing that the change does what it does. If the cards do not contain enough to
build an arrange/act/assert, the honest outcome is `unprovable` — not a probe
reverse-engineered from the patch.

## The scope guard

**A probe may only test a scenario named in a card.** No probe for an edge case
you thought of. Not "while I'm here, what about the empty array". That is a real
and useful activity and it belongs to `/deep-pr-review`; doing it here inflates
the reject rate with findings that have nothing to do with whether the fix does
its documented job, which is the one thing this skill's verdict claims.

If you notice something outside the cards, it goes in the report's
`observations` — never into a probe, never into the verdict.

## Mechanics

`probe-run.sh` builds a worktree pair off the target repo and runs the same test
file in both:

```bash
probe-run.sh --work "$WORK" --repo-path ~/code/sentry \
             --base "$BASE_SHA" --head "$HEAD_SHA" \
             --id p1 --test /path/to/bar.probe.test.tsx \
             --runner 'pnpm jest --silent'
```

- Worktrees land in `$WORK/wt-base` and `$WORK/wt-head`, off the existing clone,
  so the monorepo is never re-cloned and `node_modules` can be reused where the
  project layout allows it.
- The probe file is copied into both trees at the same relative path, run, and
  removed. Nothing is committed; nothing is left behind in either worktree.
- Probes are named `*.probe.test.*` / `*.probe.spec.*` so a stray one is
  obvious and greppable if a run is interrupted.
- Exit code carries the outcome (see the script's header), and the JSON record
  goes to `$WORK/probes/<id>.json`.

## When to skip probing entirely

Don't spend a worktree pair on:

- `change.behavioral == false` — nothing to observe.
- `mode: lintfix` where the rule is purely stylistic. The lint run *is* the probe;
  `--runner 'pnpm lint <file>'` against base and head is the same gate, cheaper.
- Evidence with no reproducible precondition (a crash from a third-party SDK
  callback, a race that needs real timing). That is `unprovable` up front —
  say so rather than writing a test that fakes the condition into existence and
  then proves your own fake.
