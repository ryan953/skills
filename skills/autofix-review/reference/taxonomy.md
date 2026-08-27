# The verdict vocabulary

`autofix-review` emits exactly one of `accept`, `reject`, `needs-human`. Both
`accept` and `reject` must be **earned**; `needs-human` is what happens when
neither is. That ordering is the whole precision story — a reviewer that reaches
for `reject` when it is merely uneasy, or for `accept` when it merely failed to
find anything, is a reviewer nobody can trust.

## Rejection codes (closed set)

**Nothing outside this list is a reject.** If a finding does not fit one of these
codes, it is not reported as a reject — not as a "minor" one, not as a note
appended to an accept. This is deliberate: the closed set is what stops
edge-case opinions from leaking into a verdict that is only supposed to answer
"does it do the documented job".

Every reject reason carries three things or it does not count:

1. a **code** from the table below,
2. a **citation** — `path/to/file.tsx:120`, or a named field of the issue
   (`evidence.failing_frames[2]`, `rca.mechanism`),
3. a **survival record** — either a base-fail/head-fail probe, or a refuter that
   tried to kill it and failed.

| Code | Name | Fires when | Does **not** fire for |
|---|---|---|---|
| `R1` | Evidence mismatch | The reported failure can still occur after the change. The diff isn't on the path the stack trace names, or the guard it adds is downstream of the throw. | A *different* failure you imagined. R1 is about the failure in the evidence card, nothing else. |
| `R2` | RCA contradiction | The change addresses a different mechanism than the RCA identified, and neither the body nor a comment says why the RCA is wrong. | A change that addresses the RCA's mechanism by a different *means* than the RCA proposed. The RCA proposes; it doesn't prescribe. |
| `R3` | Intent mismatch | The diff does something the description never claims (scope creep), or omits something it does claim. | Mechanical noise the description wouldn't be expected to mention — import reordering, a rename the change forced, a lockfile. |
| `R4` | Incomplete | The evidence names N sites and the change covers fewer than N. | Sites you found yourself that the evidence doesn't name. If the trace names one call site, fixing one call site is complete. |
| `R5` | Documented-convention violation | A repo skill, CLAUDE.md/AGENTS.md note, or an established precedent gives a specific way to do this, it is quotable, and the diff does otherwise. | Your own sense of good style. No citation to a repo document or a real prior commit ⇒ no R5. |
| `R6` | Symptom-only | The change silences the error while the evidence or RCA show the bad state persists — a `try/catch` around the throw, an optional chain over the null the RCA says shouldn't be null, a default that papers over a failed fetch. | A guard that is genuinely the fix, i.e. the RCA's mechanism *is* "this value can legitimately be absent". |
| `R7` | Suppression *(lintfix mode)* | The change disables the rule, downgrades it in config, or casts to `any` instead of satisfying it — with no stated reason. | A suppression the description justifies ("rule is wrong here because…"). That is `N4`, a human's call, not a defect. |

### The R2/R6 boundary

These are the two codes most likely to misfire, so state the test explicitly:

- **R2** is about *which problem* was solved. Compare `rca.mechanism` against
  `change.effects`.
- **R6** is about *whether a problem was solved at all*. Compare
  `change.suppression_flags` against whether `rca.mechanism` describes a state
  that is still reachable after the change.

A change can be R6 without being R2 (it targeted the right mechanism and merely
muffled it) and R2 without being R6 (it solidly fixed the wrong thing).

## `needs-human` codes

Not failures. Each says what a human needs to look at and why the machine
stopped.

| Code | Name | Fires when |
|---|---|---|
| `N1` | Missing input | No discoverable issue or RCA; the linked issue is unreachable; the diff can't be resolved. The chain has no anchor. |
| `N2` | Contested | A link validator called a link broken and the refuter killed the reason, or L4's two opposed framings disagreed. Two competent passes disagree — that is a human's tie to break, not a coin flip. |
| `N3` | Unprovable | A link rests on a probe that couldn't be written, built, or run (no harness for that surface, needs infra we don't have). |
| `N4` | Deliberate divergence | The diff knowingly departs from the RCA or a repo standard **and** gives a judgment-call reason. "The RCA's fix is a bigger refactor; doing the narrow one now" is a tradeoff a person owns, not a defect. |
| `N5` | Conflicting standards | Precedent and the repo docs disagree about the right shape, so there is no single documented answer to hold the diff to. |

`N4` is load-bearing for precision. Without it, every considered tradeoff reads
as `R2` or `R5` and the reject rate fills with false positives — which is exactly
the failure mode that makes a reviewer ignorable.

## What is never reported

Even as a footnote on an accept:

- Edge cases the evidence doesn't name. → `/deep-pr-review`
- Style, naming, formatting without a cited repo rule. → `/frontend-conventions`
- Performance, unless the evidence *is* a performance issue.
- Security speculation. → `/security-review`
- Missing tests, unless `intent.tests_claimed` promised them.
- "You could also…", "consider…", "it might be cleaner to…". This skill has no
  opinions, only findings.

A reviewer that reports one extra thing per review is a reviewer whose verdict
gets skimmed. The value here is that the output is short and every line of it is
load-bearing.
