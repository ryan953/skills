---
name: frontend-conventions
description: Review JS/TS/CSS changes for convention violations, coding style, common patterns, and slop. A superficial but thorough lint-like pass over the diff. Use when asked to "review style", "check conventions", "de-slop", "style review", "JS style", "TS style", "code tightness", or "frontend conventions".
---

# Frontend Conventions Review

Review the current branch diff for convention violations in JavaScript, TypeScript, and CSS files.

## Step 1: Get the diff

```bash
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)
git diff "$BASE"...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx'
```

If the diff is empty, check for uncommitted changes:

```bash
git diff HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx'
```

If still empty, report "No JS/TS changes to review." and stop.

Save the diff output — you will pass it to sub-agents in the next step.

## Step 2: Determine which categories apply

Scan the diff to decide which sub-agents to launch. Skip a category entirely if its prerequisite isn't met.

| Category | Prerequisite | Rule docs |
|---|---|---|
| **Code style** | Always | `rules/inline-exports.md`, `rules/no-unnecessary-intermediates.md`, `rules/consistent-destructuring.md`, `rules/no-unnecessary-renames.md`, `rules/no-thin-wrapper-hooks.md` |
| **API usage** | Diff contains `useQuery`, `useQueries`, `useMutation`, `useApiQuery`, `apiOptions`, `mutationOptions`, or `@tanstack/react-query` imports | `rules/api-calls.md`, `rules/react-query-patterns.md` |
| **UI components** | Diff contains `styled` import or raw HTML layout/text elements (`<div>`, `<span>`, `<h1>`–`<h6>`, `<p>`, `<img>`) | `rules/prefer-layout-components.md`, `rules/prefer-typography-components.md`, `rules/prefer-core-assets.md`, `rules/icons-and-images.md` |
| **React patterns** | Diff contains `createContext`, `.Provider`, `.Consumer`, or `.displayName` | `rules/modern-context-patterns.md` |
| **URL state** | Diff contains `useQueryParamState`, `useLocationQuery`, `updateLocation`, `updateNullableLocation`, `decodeScalar`, `decodeList`, `decodeInteger`, `decodeSorts`, `useUrlParams`, or manual `location.query` reads | `rules/prefer-nuqs-url-state.md` |
| **Testing** | Diff includes test files (`.spec.`, `.test.`) | `rules/testing-guidelines.md` |

## Step 3: Launch sub-agents in parallel

For each applicable category, launch a sub-agent using the Task tool with `subagent_type: "generalPurpose"` and `run_in_background: true`. Launch all applicable sub-agents in a single message so they run concurrently.

Each sub-agent prompt must contain:

1. The **full diff** (verbatim from Step 1)
2. The **rule doc paths** to read for that category (from the table above)
3. These shared instructions:

```
You are reviewing a code diff for convention violations.

RULES TO CHECK:
Read each of these rule docs before scanning the diff:
<list the rule doc paths here>

INSTRUCTIONS:
- Only flag lines that appear as additions (+ lines) in the diff.
- When you suspect a violation, read enough surrounding context from the source file to confirm it is real.
- For each violation found, report it in this exact format:

<file>:<line> — <rule name>
  <one-line fix suggestion>

- Group findings by file.
- If no violations are found for your rules, report: "No violations found."
- Do not explain rules, lecture about best practices, or add commentary beyond the fix suggestion.

DIFF:
<paste diff here>
```

## Step 4: Collect and report

Wait for all sub-agents to complete. Merge their findings into a single report grouped by file. If all sub-agents reported no violations, report: "No style issues found."

Do not explain the rules, lecture about best practices, or add commentary beyond the fix suggestions.
