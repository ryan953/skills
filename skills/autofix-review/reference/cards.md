# Cards, links, and the briefs that produce them

Everything the coordinator ever sees is on this page. The raw diff, the raw
Sentry issue, the raw PR body are read by exactly one subagent each and never
reach the coordinator's context. That is not tidiness — it is what makes the
`intent ↔ change` comparison mean anything (see **Blindness** below).

All files are JSON, under `$WORK`. JSON rather than prose because
`verdict-rule.sh` has to consume them without a model in the loop, and because a
missing field should be a parse error rather than something to squint at.

---

## Blindness

| Writer | Gets | Must never see |
|---|---|---|
| `evidence` | the issue (or the lint rule + failing output) | the diff, the PR body |
| `rca` | the root-cause analysis | the diff, the PR body |
| `intent` | PR body + commit messages | the diff, the issue |
| `change` | the diff + surrounding source | the issue, the RCA, the PR body |

**Why `change` is blind to the body.** Show a model the PR description and then
the diff, and it will describe the diff in the description's own words — the
framing primes the summary. Then `L3 intent ↔ change` compares a text against a
paraphrase of itself and holds every time. Blind, the `change` writer says what
the code does; if that diverges from what the author said they did, L3 sees it.

Enforce blindness by **what you put in the prompt**, not by asking the subagent
to ignore things. Each card writer gets a prompt containing only its own inputs
and a path to write to. A card writer that is told "here is the PR body, ignore
it" has already seen it.

---

## `cards/evidence.json`

What is actually broken, from the source of truth. In `lintfix` mode the same
shape is filled from the rule and the failing lint output.

```json
{
  "mode": "bugfix | lintfix",
  "source": "https://sentry.io/... | eslint:rule-name | pr-body",
  "symptom": "TypeError: Cannot read properties of undefined (reading 'id')",
  "failing_frames": [
    {"file": "static/app/views/foo/bar.tsx", "line": 88, "fn": "useThing", "in_repo": true}
  ],
  "preconditions": ["organization has no projects", "route hit before hydration"],
  "repro": "prose or null — how to make it happen",
  "affected_sites": ["static/app/views/foo/bar.tsx:88", "static/app/views/foo/baz.tsx:12"],
  "volume": {"events": 1420, "users": 96},
  "first_seen": "2026-07-02", "last_seen": "2026-08-19",
  "unavailable": []
}
```

`affected_sites` is the field `R4` is judged against, so it must list **only**
sites the evidence itself names — every in-repo frame in the trace, every site
named in the issue body. Never a site inferred by grepping for similar code:
that is the reviewer inventing scope.

`unavailable` names inputs that could not be read (`"seer_rca"`, `"breadcrumbs"`).
A non-empty `unavailable` on a field a link depends on routes to `N1`.

### `source: "pr-body"` — evidence with no tracker behind it

Plenty of real fixes carry the whole case in the description: a `## Bug` section,
a pasted stack trace, a reproduction. `gather.sh` detects these and sets
`EVIDENCE_SOURCE=pr-body`, and the card is built from them rather than routing
straight to `N1` — deferring the changes that came with the *most* explanation
would be a strange way to behave.

It is weaker evidence, and the reason is worth stating plainly: **the author
wrote both the evidence and the intent, so `evidence` and `intent` are no longer
independent.** `L1` (evidence ↔ rca) largely collapses — both sides are the same
person's account. What still holds is `L4`, because the `change` card is blind to
all of it, and the probe, because a test either reproduces the failure or does
not regardless of who described it.

So on a `pr-body` case: treat a `holds` from `L1` as carrying little weight, and
lean on the probe. This is the case where skipping Wave 3 costs the most.

## `cards/rca.json`

```json
{
  "present": true,
  "source": "seer | issue-comment | linked-doc | pr-body | derived-from-rule",
  "mechanism": "one paragraph: the causal chain, not the symptom",
  "faulty_locations": [{"file": "static/app/views/foo/bar.tsx", "line": 88}],
  "proposed_remedy": "what the RCA suggests, or null",
  "alternatives_considered": ["..."],
  "confidence": "high | medium | low"
}
```

`present: false` (no RCA anywhere) is legal and routes to `N1` unless
`mode: lintfix`, where the rule's own rationale is a sufficient RCA and `source`
becomes `derived-from-rule`.

`source: pr-body` is the weak case, and it is the common one: every other source
lives inside the tracker issue, and `gather.sh` cannot reach a tracker. A cause
stated in the description — "The root cause was …", "The issue was that …" —
counts, and `raw/body-evidence.txt` carries the sentences it was drawn from.
Weak means **not independent**: the author wrote the cause and the fix, so `L1`
largely collapses and the weight moves to `L2`, `L4a`/`L4b` and the probe. It
does not mean absent. Requiring an unreachable source instead sent 13 of 20
cases in a real run to `N1`, each after a full review of a description that
explained the fault plainly — a system that defers is not a safe system, it is
an unused one.

`proposed_remedy` is advisory. A change that fixes `mechanism` by other means is
not `R2` — only a change that fixes a *different mechanism* is.

## `cards/intent.json`

From the PR body and commit messages only.

```json
{
  "claims": [
    {"id": "c1", "text": "guards against a null organization in useThing", "kind": "does"},
    {"id": "c2", "text": "no behavior change for the populated case", "kind": "does-not"}
  ],
  "stated_scope": "one sentence in the author's framing",
  "out_of_scope": ["explicit 'not doing X here' statements"],
  "tests_claimed": true,
  "divergence_rationale": "quoted text where the author explains departing from the RCA, or null"
}
```

`claims[].kind` is `does` or `does-not`. Both are checkable and a violated
`does-not` is the sharpest `R3` there is.

`divergence_rationale` is what separates `R2`/`R5` from `N4`. Quote it; don't
summarize it — the coordinator decides on the author's words, not yours.

**The intent writer gets `$DIVERGENCE_FILE` as well as its own input**, because
of where such a sentence tends to live: in the framing paragraph, next to the
symptom, which is the *evidence* writer's territory. Split the body naively and
the intent writer never sees it, `divergence_rationale` comes back `null`, the
N4 conversion silently fails, and a considered tradeoff gets reported as a
defect. That is not hypothetical — it happened on a real PR whose body said "but
does not directly address its root cause".

## `cards/change.json`

From the diff and the code around it. This writer has no idea what the change is
*for*, and should not speculate: describe behavior, not purpose.

```json
{
  "effects": [
    {"file": "static/app/views/foo/bar.tsx", "line": 88,
     "before": "reads organization.id unconditionally",
     "after": "returns early when organization is null"}
  ],
  "new_tests": ["static/app/views/foo/bar.spec.tsx:40"],
  "side_effects": ["renames `thing` to `item` across 3 files"],
  "suppression_flags": [
    {"kind": "try-catch | optional-chain | default-value | type-assertion | eslint-disable | config-downgrade",
     "file": "...", "line": 88, "swallows": "what stops being observable"}
  ],
  "behavioral": true
}
```

`behavioral: false` — the diff cannot change runtime behavior (formatting,
imports, types-only, comments). It is what lets a genuine lint fix reach `accept`
without a probe, so it must be conservative: **anything you are unsure about is
`behavioral: true`.**

`suppression_flags[].swallows` is the field `R6` turns on. "what stops being
observable" — if the honest answer is "nothing, the value is legitimately
optional", say that; it is the difference between a fix and a muffle.

---

## `links/<id>.json`

One per validator. `L4` runs twice, as `L4a` (framing: prove it's fixed) and
`L4b` (framing: prove it still fires).

```json
{
  "link": "L1 | L2 | L3 | L4a | L4b",
  "status": "holds | broken | unsupported",
  "reason": "one or two sentences",
  "code": "R1 | R2 | R3 | R4 | R5 | R6 | R7 | null",
  "citations": ["static/app/views/foo/bar.tsx:88", "evidence.failing_frames[0]"]
}
```

- `holds` — the link is supported by what's in front of you.
- `broken` — it is contradicted, **and** you can cite where. Requires a `code`.
- `unsupported` — you cannot tell from the two cards you were given. This is a
  respectable answer and it is the right one far more often than it feels.
  Never guess to avoid it.

A `broken` with an empty `citations` array is discarded by `verdict-rule.sh`
without ceremony. Say where, or it didn't happen.

## `links/P.json` — precedent

```json
{
  "priors": [
    {"sha": "abc1234", "subject": "fix(issues): guard null org in useThing",
     "shape": "early return at the hook boundary", "matches_this_diff": true}
  ],
  "verdict": "matches | diverges | no-precedent",
  "note": "one sentence"
}
```

`diverges` alone is never a reject. It becomes `R5` only if `S` independently
cites a document requiring the other shape; otherwise it is context, or `N5`
when the two disagree.

`verdict` is about the **shape** this diff takes, not about whether its core idea
matches. A change that reaches the same outcome as every prior by a different
construction is `diverges`, however familiar the idea. The distinction decides a
verdict — `matches` + a violated standard is `N5`, `diverges` + the same
violation lets `R5` stand — and the rule reads the field, never the `note`.

## `links/S.json` — repo standards

```json
{
  "docs_found": ["CLAUDE.md", ".claude/skills/frontend-conventions/rules/api-calls.md"],
  "applicable": [
    {"doc": ".claude/skills/.../api-calls.md", "quote": "always use useApiQuery",
     "applies_because": "the diff adds a fetch at bar.tsx:120",
     "followed": false}
  ],
  "verdict": "followed | violated | not-applicable"
}
```

Judge **only lines the diff touched**. A rule broken by code the diff merely sits
next to is not this change's problem. Every entry needs a `quote` — an
unquotable standard is one you invented, and it is dropped.

---

## `probes/<id>.json`

Written by `probe-run.sh`, not by a model. See `probes.md`.

`link` names the link this probe backs, and `reason_id` below names the link a
refutation examined. **Both joins are keyed on the link, never on the code.**
Keying on the code lets one refutation speak for a finding it never looked at,
and lets a single proven-reject probe mark every broken link probe-proven — which
revives refuted findings and suppresses the N4 conversion at the same time.

```json
{
  "id": "p1", "link": "L4b", "derived_from": "evidence.preconditions[0]",
  "test_file": "bar.probe.test.tsx",
  "base_result": "fail | pass | error",
  "head_result": "fail | pass | error | skipped",
  "outcome": "proven | proven-reject | invalid | unprovable",
  "detail": "first failing assertion, trimmed"
}
```

## `refutations/<id>.json`

```json
{
  "reason_id": "L4b", "code": "R4",
  "outcome": "refuted | survived",
  "argument": "why it dies, or what you tried and why it didn't",
  "citations": ["static/app/views/foo/baz.tsx:12"]
}
```

`reason_id` is the **link** you examined (`L4b` above), matching the `link`
field of the finding. It is not a refutation id of your own invention: the join
is by link, and a made-up id matches nothing, so a cited finding a refuter
confirmed would come back `survived: false` and a real reject would degrade to
`needs-human`.

The refuter's brief is adversarial on purpose: *default to `refuted`, and only
report `survived` after opening the files and failing to find a way out.* A
refuter that agrees with the finding without having looked is worth nothing, so
`survived` with no `citations` is treated as `refuted`.
