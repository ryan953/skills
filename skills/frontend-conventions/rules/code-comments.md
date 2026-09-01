# Code comments

Keep code comments focused on the rational for a design choice.
The purpose is not to re-state what the code is already doing, unless the code is non-conventional or is too terse.
Do not reference other places, especially external sources, or previous descisions that are no longer part of the codebase. Just explain the reasons why this was chosen, rarely compare to other options unless they're the obvious paths not taken.
Comments should be to the point, and not "AI slop"

## Examples

```tsx
// bad — restates the code
// Increment the retry count
retries += 1;

// bad — narrates the obvious
// Map over the items and return the ids
const ids = items.map(i => i.id);

// good — the reason, not the mechanic
// Retry twice: this endpoint 500s on cold caches.
retries += 1;
```

```tsx
// bad — points at a decision that is no longer in the codebase
// We used to use moment here, but switched to date-fns in Q2
const ms = Date.now();

// bad — cites an external source
// See https://internal-wiki/pages/12345 for the full discussion
const ms = Date.now();

// good — self-contained reason
// Captured once at mount so re-renders stay pure.
const ms = useRef(Date.now());
```

```tsx
// bad — AI slop: padding, hedging, restating the function name
/**
 * This function is a helper function that helps to format the given
 * user object into a display name. It takes a user and returns a string.
 */
function formatDisplayName(user: User) { ... }

// good — no comment needed, the name carries it
function formatDisplayName(user: User) { ... }
```

## Exceptions — do NOT flag these

- A comment explaining the obvious path not taken, when the alternative is the one a
  reader would reach for first. That comparison is explicitly allowed.
- Comments on genuinely non-conventional or very terse code, where the mechanic is not
  self-evident.
- `TODO` / `FIXME` / `HACK` markers, and issue links attached to them.
- JSDoc on exported public API where the type alone does not convey usage.
- `eslint-disable` and `@ts-expect-error` justifications — those must state a reason.
- Licence headers and generated-file banners.
