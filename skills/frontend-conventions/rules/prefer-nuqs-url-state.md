# Prefer nuqs for URL state

**Prerequisite:** Only check this rule if the diff contains URL state patterns — `useQueryParamState`, `useLocationQuery`, `updateNullableLocation`, `updateLocation`, `decodeScalar`, `decodeList`, `decodeInteger`, `decodeSorts`, `useUrlParams`, `URLSearchParams`, `location.query`, or manual `router.push`/`router.replace` for query param updates.

Use [nuqs](https://nuqs.dev/) for URL state management. See the [Sentry URL State docs](https://develop.sentry.dev/frontend/url-state/) for full guidance.

## Why

nuqs provides type-safe, `useState`-like API that syncs with the URL, handles un-parseable values gracefully, supports defaults, and throttles URL updates out of the box.

## Examples

```tsx
import {parseAsInteger, parseAsString, useQueryState} from 'nuqs';

// bad — legacy decode helpers
import {decodeScalar} from 'sentry/utils/queryString';
const cursor = decodeScalar(location.query.cursor);

// good
const [cursor, setCursor] = useQueryState('cursor');

// bad — manual integer parsing
const page = parseInt(location.query.page ?? '1', 10);

// good
const [page, setPage] = useQueryState('page', parseAsInteger);

// bad — useLocationQuery
import {useLocationQuery} from 'sentry/utils/url/useLocationQuery';
const {sort, query} = useLocationQuery({fields: {sort: decodeScalar, query: decodeScalar}});

// good
const [sort, setSort] = useQueryState('sort');
const [query, setQuery] = useQueryState('query');

// bad — manual router.push to update query params
router.push({...location, query: {...location.query, page: '2'}});

// good
setPage(2);

// bad — updateLocation / updateNullableLocation
updateLocation({cursor: newCursor});

// good
setCursor(newCursor);
```

### Arrays

For array values represented as multiple URL params (e.g. `?project=1&project=2`), use `parseAsNativeArrayOf`:

```tsx
import {parseAsInteger, parseAsNativeArrayOf, useQueryState} from 'nuqs';

// bad
const projects = decodeList(location.query.project);

// good
const [projects, setProjects] = useQueryState('project', parseAsNativeArrayOf(parseAsInteger));
```

For comma-separated arrays (`?project=1,2,3`), use `parseAsArrayOf`:

```tsx
const [projects, setProjects] = useQueryState('project', parseAsArrayOf(parseAsInteger));
```

### Options

nuqs defaults to `history: 'replace'` without scrolling. Override when needed:

```tsx
const [state, setState] = useQueryState('foo', {
  ...parseAsString,
  history: 'push',
  scroll: true,
});
```

## Deprecated patterns to flag

- `useQueryParamState`
- `useLocationQuery`
- `updateLocation` / `updateNullableLocation`
- `decodeScalar` / `decodeList` / `decodeInteger` / `decodeSorts`
- `useUrlParams`
- Direct reads from `location.query` for state that should be managed
- Manual `router.push` / `router.replace` solely to update query params

## Exceptions — do NOT flag these

- Code in routing infrastructure itself (route definitions, redirects)
- One-off reads of `location.query` for analytics or logging (not state management)
- Legacy code not touched by the diff (only flag new/changed lines)
- Page filter params (`project`, `environment`, `statsPeriod`) managed by the global PageFilters system
