# No thin wrapper hooks

Don't create a hook that just delegates to another hook with no meaningful added logic. Inline the inner hook into the outer one.

## Examples

```tsx
// bad — useContextValue is just useContext, then useMyContext just calls useContextValue
function useMyContextValue(): MyContextValue | undefined {
  return useContext(MyContext);
}

function useMyContext(): Partial<MyContextValue> {
  return useMyContextValue() ?? {};
}

// good — one hook, one level
function useMyContext(): Partial<MyContextValue> {
  return useContext(MyContext) ?? {};
}

// bad — wrapper hook adds nothing
function useInternalState() {
  return useContext(InternalStateContext);
}

export function usePublicState() {
  return useInternalState();
}

// good
export function usePublicState() {
  return useContext(InternalStateContext);
}
```

## Exceptions — do NOT flag these

- The inner hook performs setup, subscriptions, or memoization beyond a simple pass-through
- The wrapper adds default values, validation, or error handling that is non-trivial
- The wrapper is used as a seam for testing (explicitly documented as such)
- The inner hook is from a third-party library and the wrapper normalizes the API
