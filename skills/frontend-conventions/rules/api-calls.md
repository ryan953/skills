# Frontend API Calls

Use `apiOptions` with `useQuery` from TanStack Query. **Do not use `useApiQuery`, `getApiQueryData`, or `setApiQueryData`** — they are deprecated.

## Examples

```typescript
import {skipToken, useQuery} from '@tanstack/react-query';
import {apiOptions} from 'sentry/utils/api/apiOptions';

// Basic usage
const query = useQuery(
  apiOptions.as<ResponseType>()('/organizations/$organizationIdOrSlug/endpoint/', {
    path: {organizationIdOrSlug: organization.slug},
    staleTime: 30_000,
  })
);

// Conditional fetching — pass skipToken as path to disable the query
const query = useQuery(
  apiOptions.as<ResponseType>()('/organizations/$organizationIdOrSlug/items/$itemId/', {
    path: itemId ? {organizationIdOrSlug: organization.slug, itemId} : skipToken,
    staleTime: 30_000,
  })
);
```

## Key rules

- **`staleTime` is required** — you must choose a value (`0`, a number in ms, `Infinity`, or `'static'`).
- **Build abstractions over `apiOptions`**, not over `useQuery`. Return the options object so consumers can pass it to `useQuery`, `useQueries`, `prefetchQuery`, etc.
- **Cache stores `{json, headers}`**, not just the body. `apiOptions` uses `select` to extract `.json` by default, but `getQueryData`, `setQueryData`, `retry` functions, and `predicate` callbacks all receive the raw `ApiResponse<T>` shape.
- **Never** use `api.requestPromise` for a Query — it returns the wrong structure. If you must make a manual `queryFn`, use `apiFetch`.

## Accessing response headers (pagination, hit counts)

Override `select` with `selectJsonWithHeaders` when you need response headers:

```typescript
import {useQuery} from '@tanstack/react-query';
import {apiOptions, selectJsonWithHeaders} from 'sentry/utils/api/apiOptions';

const {data} = useQuery({
  ...apiOptions.as<Item[]>()('/organizations/$organizationIdOrSlug/items/', {
    path: {organizationIdOrSlug: organization.slug},
    query: {cursor, per_page: 25},
    staleTime: 0,
  }),
  select: selectJsonWithHeaders,
});

// data is ApiResponse<Item[]> — an object with `json` and `headers`
const items = data?.json ?? [];
const pageLinks = data?.headers.Link;
const totalHits = data?.headers['X-Hits'];       // number | undefined
const maxHits = data?.headers['X-Max-Hits'];     // number | undefined
```

`X-Hits` and `X-Max-Hits` are already parsed to `number | undefined` — no `parseInt` needed.
