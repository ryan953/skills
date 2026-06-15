# React Query Patterns

Prefer `select` over dependent `useMemo` for transforming query data, and export options factories instead of pre-wrapped hooks.

## Use `select` instead of `useMemo`

When transforming data returned from `useQuery` or `useQueries`, use the `select` option instead of a dependent `useMemo`. React Query memoizes `select` internally — it only re-runs when the raw data reference changes.

```typescript
// bad — useMemo re-derived from query data
const {data} = useQuery(apiOptions.as<Item[]>()('/api/items/', {...}));
const sorted = useMemo(() => data?.toSorted((a, b) => a.name.localeCompare(b.name)), [data]);

// good — select handles the transform inside the query
const {data: sorted} = useQuery({
  ...apiOptions.as<Item[]>()('/api/items/', {...}),
  select: json => json.toSorted((a, b) => a.name.localeCompare(b.name)),
});
```

```typescript
// bad — useMemo to reshape query data
const {data} = useQuery(apiOptions.as<OrgMember[]>()('/api/members/', {...}));
const memberMap = useMemo(() => new Map(data?.map(m => [m.id, m])), [data]);

// good
const {data: memberMap} = useQuery({
  ...apiOptions.as<OrgMember[]>()('/api/members/', {...}),
  select: json => new Map(json.map(m => [m.id, m])),
});
```

### Exceptions — do NOT flag these

- The `useMemo` combines data from **multiple** queries or other state (not just one query's `data`)
- The transform has dependencies beyond the query data (e.g. a search filter from state)
- The `useMemo` is used for an expensive computation that needs explicit dependency tracking across renders unrelated to the query

## Export options factories, not pre-wrapped hooks

Reusable API calls should export an options factory — a function returning a query/mutation options object — not a hook that calls `useQuery`/`useMutation` internally. This lets consumers compose freely: `useQuery`, `useQueries`, `useSuspenseQuery`, `prefetchQuery`, etc.

```typescript
// bad — exporting a pre-wrapped hook locks consumers into useQuery
export function useOrgMembers(orgSlug: string) {
  return useQuery(apiOptions.as<OrgMember[]>()('/api/members/', {
    path: {orgSlug},
    staleTime: 30_000,
  }));
}

// good — export the options, let call sites choose the hook
export function orgMembersOptions(orgSlug: string) {
  return apiOptions.as<OrgMember[]>()('/api/members/', {
    path: {orgSlug},
    staleTime: 30_000,
  });
}

// call site picks the hook
const {data} = useQuery(orgMembersOptions(orgSlug));
const {data} = useSuspenseQuery(orgMembersOptions(orgSlug));
```

The same applies to mutations — export the options factory using `mutationOptions`, not `useMutation(mutationOptions(...))`.

```typescript
// bad
export function useDeleteItem() {
  return useMutation({...});
}

// good
export function deleteItemOptions() {
  return mutationOptions({...});
}

// call site
const mutation = useMutation(deleteItemOptions());
```

### Composing options with `select`

Layering `select` on top of an options factory is the expected pattern for call-site-specific transforms:

```typescript
const {data: memberMap} = useQuery({
  ...orgMembersOptions(orgSlug),
  select: json => new Map(json.map(m => [m.id, m])),
});
```

Wrapping options in `queryOptions({...})` for additional type safety is fine:

```typescript
const opts = queryOptions({
  ...orgMembersOptions(orgSlug),
  select: json => json.filter(m => m.role === 'admin'),
});
```

### Exceptions — do NOT flag these

- A hook that wraps the query **and** adds meaningful logic (side effects, error handling, dependent queries, state management) beyond just calling `useQuery`/`useMutation`
- Internal one-off hooks in the same file as their only consumer

## Don't accept callback props in options factories

Options factories should not accept `onSuccess`, `onError`, `onSettled`, or other callback parameters and wire them into the returned options. Call sites that need callbacks can spread the options and add their own — or use the mutation/query result imperatively.

```typescript
// bad — options factory accepts and re-wires callbacks
export function deleteItemOptions({
  onSuccess,
  onError,
}: {
  onSuccess?: () => void;
  onError?: (err: Error) => void;
} = {}) {
  return mutationOptions({
    mutationFn: (id: string) => apiFetch(`/api/items/${id}/`, {method: 'DELETE'}),
    onSuccess,
    onError,
  });
}

// good — options factory defines only the mutation, no callback plumbing
export function deleteItemOptions() {
  return mutationOptions({
    mutationFn: (id: string) => apiFetch(`/api/items/${id}/`, {method: 'DELETE'}),
  });
}

// call site adds its own callbacks by spreading
const mutation = useMutation({
  ...deleteItemOptions(),
  onSuccess: () => addSuccessMessage('Deleted'),
  onError: () => addErrorMessage('Failed to delete'),
});
```

The same applies to query options — don't pass through `onSuccess`/`onError`/`onSettled` as parameters.

### Exceptions — do NOT flag these

- Callbacks that are intrinsic to the mutation's correctness (e.g. cache invalidation in `onSuccess` that must always run) — those belong in the factory, not passed in
