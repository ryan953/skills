---
name: frontend-conventions-fix
description: Apply fixes for frontend convention violations found by the frontend-conventions review skill. Use when asked to "fix conventions", "apply style fixes", "fix the findings", "auto-fix style", "fix slop", or after running a frontend-conventions review.
---

# Frontend Conventions Fix

Apply fixes for convention violations. This skill consumes the output of the `frontend-conventions` review skill and edits the source files.

## Step 1: Get the findings

If findings were provided in the conversation, use those. Otherwise, run the `frontend-conventions` skill first to produce them.

Findings follow this format:

```
<file>:<line> — <rule name>
  <one-line fix suggestion>
```

If the findings say "No style issues found.", report that and stop.

## Step 2: Read rule docs for context

Collect the unique rule names from the findings. For each rule, read its doc from the sibling skill to understand the expected pattern:

| Rule name                    | Doc path                                                        |
|------------------------------|-----------------------------------------------------------------|
| Inline exports               | `../frontend-conventions/rules/inline-exports.md`               |
| No unnecessary intermediates | `../frontend-conventions/rules/no-unnecessary-intermediates.md` |
| Consistent destructuring     | `../frontend-conventions/rules/consistent-destructuring.md`     |
| No unnecessary renames       | `../frontend-conventions/rules/no-unnecessary-renames.md`       |
| No thin wrapper hooks        | `../frontend-conventions/rules/no-thin-wrapper-hooks.md`        |
| Modern context patterns      | `../frontend-conventions/rules/modern-context-patterns.md`      |
| Prefer nuqs URL state        | `../frontend-conventions/rules/prefer-nuqs-url-state.md`        |
| Frontend API calls           | `../frontend-conventions/rules/api-calls.md`                    |
| React Query patterns         | `../frontend-conventions/rules/react-query-patterns.md`         |
| React Query patterns         | `../frontend-conventions/rules/react-query-patterns.md`         |
| Prefer layout components     | `../frontend-conventions/rules/prefer-layout-components.md`     |
| Prefer typography components | `../frontend-conventions/rules/prefer-typography-components.md` |
| Prefer core assets           | `../frontend-conventions/rules/prefer-core-assets.md`           |
| Icons and images             | `../frontend-conventions/rules/icons-and-images.md`             |
| Testing guidelines           | `../frontend-conventions/rules/testing-guidelines.md`           |

Only read the docs for rules that appear in the findings.

## Step 3: Apply fixes

For each finding, read the source file around the reported line, then apply the fix using the file editing tool. Follow these principles:

- **Match the "good" pattern** from the rule doc exactly.
- **Preserve surrounding code** — only change what is necessary.
- **Update imports** if the fix requires adding or removing them (e.g. adding `import {Flex} from '@sentry/scraps/layout'` when replacing a styled wrapper).
- **Remove dead code** — if a fix eliminates a styled component or intermediate variable, delete the now-unused declaration.
- **One file at a time** — finish all fixes in a file before moving to the next.

When multiple findings affect the same file, apply them top-to-bottom to avoid line number drift.

## Step 4: Verify

After all fixes are applied, run the linter on edited files to check for errors introduced by the changes. Fix any linter errors before finishing.

```bash
git diff --name-only HEAD | head -20
```

Report a summary of what was changed:

```
Fixed N violation(s) across M file(s):
- <file>: <count> fix(es) — <rule names>
- ...
```
