---
name: deprecate-pattern
description: Deprecate and remove a function, component, or pattern across the codebase, replacing each callsite with a modern alternative. Use when asked to "deprecate X", "replace all uses of X", "migrate away from X", "remove X and replace with Y", or refactor a pattern out of the codebase.
---

# Deprecate Pattern

Replace all callsites of a deprecated function, component, or pattern with a modern alternative, then remove the original.

## Arguments

- `$0` — The pattern to deprecate (function name, component, import path, etc.)
- `$1` — (Optional) The replacement approach or target pattern. If omitted, infer from the deprecation target's implementation.

## Phase 1: Understand the Target

Before touching any callsite, fully understand the pattern being replaced.

1. **Read the source** of the deprecated pattern. Understand its API surface, parameters, return type, and any edge cases (e.g., optional flags that change behavior).
2. **Design the replacement**. If `$1` was provided, use it. Otherwise, determine the idiomatic replacement by reading the deprecated implementation and understanding what it abstracts. Write down the before/after transformation as a template.
3. **Read the relevant AGENTS.md** for the area being modified (frontend vs backend) to understand conventions.

## Phase 2: Discovery (Sub-Agent)

Spawn an **Explore agent** to find every callsite. The agent should:

1. Find all files that import or reference `$0`
2. For each file, report:
   - File path
   - How the pattern is used (which parts of the API surface are consumed)
   - Whether `strict: false` or other non-default options are passed
   - Estimated complexity: **trivial** (mechanical swap), **moderate** (logic adjustment needed), or **complex** (structural refactor)
3. Return a structured list

## Phase 3: Plan and Create Tasks

Based on discovery results, decide the batching strategy:

| Callsite count | Complexity mix | Strategy |
|---|---|---|
| 1-5 | Any | Single PR with all changes |
| 6-15 | Mostly trivial | 1-2 PRs grouped by directory or ownership |
| 6-15 | Mixed with complex | Separate PR for each complex site; batch trivial ones |
| 16+ | Mostly trivial | Batch into PRs of ~10-15 files each, grouped by CODEOWNERS |
| 16+ | Mixed | Trivial sites in batches; complex sites get individual PRs |

Create a **dex task** for each planned unit of work. Each task should include:
- The files to modify
- The transformation to apply
- Whether it's a batch or individual change

Create one final task for removing the deprecated source file and its tests.

## Phase 4: Execute Each Task

For each task, follow this loop:

1. **Transform each callsite** using the before/after template from Phase 1
2. **Handle edge cases** — if a callsite uses non-default options or the pattern differently, adapt the replacement accordingly
3. **Check for unused imports** — remove the import of the deprecated pattern; add imports for the replacement
4. **Run type checking** on modified files:
   ```bash
   pnpm run typecheck
   ```
5. **Run tests** for modified files:
   ```bash
   pnpm test-ci <test-file>
   ```
6. **Run lint** on modified files:
   ```bash
   pnpm run lint:js <files...>
   ```
7. Mark the dex task complete

## Phase 5: Remove the Deprecated Source

After all callsites are migrated:

1. Delete the source file containing the deprecated pattern
2. Delete associated test files
3. Remove any re-exports or barrel file references
4. Run typecheck and tests to confirm nothing breaks

## Transformation Guidelines

- **Preserve behavior exactly** — the refactor should be invisible to users of the code
- **Don't expand scope** — only change what's needed for the migration; don't refactor surrounding code
- **Keep imports clean** — no unused imports, no duplicate imports
- **Match existing style** — follow the conventions of each file being modified
- **One logical change per commit** — each task should be a single commit

## Stop Conditions

Stop and ask the user before proceeding when:

- A callsite uses the deprecated pattern in a way not covered by the transformation template
- The replacement would change observable behavior
- A file has no tests and the transformation is non-trivial
- The deprecated pattern is re-exported from a public API or package boundary
