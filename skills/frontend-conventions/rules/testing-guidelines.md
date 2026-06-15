# React Testing Guidelines

**Prerequisite:** Only check this rule for test files (`*.spec.*`, `*.test.*`).

## Philosophy

- **User-centric testing**: Write tests that resemble how users interact with the app.
- **Avoid implementation details**: Focus on behavior, not internal component structure.
- **Do not share state between tests**: Behavior should not be influenced by other tests.

## Imports

**Always** import from `sentry-test/reactTestingLibrary`, not directly from `@testing-library/react`:

```tsx
import {
  render,
  screen,
  userEvent,
  waitFor,
  within,
} from 'sentry-test/reactTestingLibrary';
```

## Query priority (in order of preference)

1. `getByRole` — primary selector for most elements
2. `getByLabelText` / `getByPlaceholderText` — for form elements
3. `getByText` — for non-interactive elements
4. `getByTestId` — last resort only

## Avoid mocking hooks, functions, or components

Do not use `jest.mocked()`.

```tsx
// bad
jest.mocked(useDataFetchingHook)

// good — set the response data
MockApiClient.addMockResponse({
  url: '/data/',
  body: DataFixture(),
})

// bad
jest.mocked(useOrganization)

// good — use the provided organization config on render()
render(<Component />, {organization: OrganizationFixture({...})})

// bad
jest.mocked(useLocation)

// good — use the provided router config
render(<TestComponent />, {
  initialRouterConfig: {
    location: {pathname: "/foo/"},
  },
});

// bad
jest.mocked(usePageFilters)

// good — update the corresponding data store
PageFiltersStore.onInitializeUrlState(
  PageFiltersFixture({projects: [1]}),
)

// bad — recreating context providers
renderHook(useNavigate, {
  wrapper: (children) => (<AllTheProviders>{children}</AllTheProviders>),
})

// good
renderHookWithProviders(useNavigate)
```

## Use fixtures

```tsx
// bad — importing type and initializing manually
import type {Project} from 'sentry/types/project';
const project: Project = {...}

// good
import {ProjectFixture} from 'sentry-fixture/project';
const project = ProjectFixture(partialProject)
```

Sentry fixtures: `tests/js/fixtures/`. GetSentry fixtures: `tests/js/getsentry-test/fixtures/`.

## Use `screen` instead of destructuring

```tsx
// bad
const {getByRole} = render(<Component />);

// good
render(<Component />);
const button = screen.getByRole('button');
```

## Query selection

- `getBy...` — for elements that should exist
- `queryBy...` — ONLY when checking for non-existence
- `await findBy...` — when waiting for elements to appear

```tsx
// bad
expect(screen.queryByRole('alert')).toBeInTheDocument();

// good
expect(screen.getByRole('alert')).toBeInTheDocument();
expect(screen.queryByRole('button')).not.toBeInTheDocument();
```

## Async testing

```tsx
// bad — don't use waitFor for appearance
await waitFor(() => {
  expect(screen.getByRole('alert')).toBeInTheDocument();
});

// good — use findBy for appearance
expect(await screen.findByRole('alert')).toBeInTheDocument();

// good — use waitForElementToBeRemoved for disappearance
await waitForElementToBeRemoved(() => screen.getByRole('alert'));
```

## Avoid waiting for loading indicators

```tsx
// bad — findBy errors if element not found
expect(await screen.findByTestId('loading-indicator')).not.toBeInTheDocument();

// good — wait for the actual content you care about
expect(await screen.findByRole('button', {name: 'Submit'})).toBeInTheDocument();
```

## User interactions

```tsx
// bad — don't use fireEvent
fireEvent.change(input, {target: {value: 'text'}});

// good — use userEvent
await userEvent.click(input);
await userEvent.keyboard('text');
```

## Testing routing

```tsx
const {router} = render(<TestComponent />, {
  initialRouterConfig: {
    location: {pathname: '/foo/', query: {page: '1'}},
  },
});

expect(router.location.pathname).toBe('/foo');

await userEvent.click(screen.getByRole('link', {name: 'Go to /bar/'}));
expect(router.location.pathname).toBe('/bar/');

router.navigate('/new/path/');
router.navigate(-1); // back button
```

For components using `useParams()`:

```tsx
const {router} = render(<TestComponent />, {
  initialRouterConfig: {
    location: {pathname: '/foo/123/'},
    route: '/foo/:id/',
  },
});
expect(screen.getByText('123')).toBeInTheDocument();
```

For components using `useMatches()`, pass `children` to instrument nested routes so `useMatches` returns the full route tree with handles:

```tsx
const routeChildren = [
  {
    path: 'one',
    handle: {name: 'One', path: '/one/'},
    children: [
      {
        path: 'two',
        handle: {name: 'Two', path: '/two/'},
        element: <div />,
        children: [
          {
            path: 'three',
            handle: {name: 'Three', path: '/three/'},
            element: <div />,
          },
        ],
      },
    ],
  },
];

render(
  <MyComponent />,
  {
    initialRouterConfig: {
      route: '/',
      location: {pathname: '/one/two/three/'},
      children: routeChildren,
    },
  }
);
```

## Testing network requests

```tsx
// GET
MockApiClient.addMockResponse({
  url: '/projects/',
  body: [{id: 1, name: 'my project'}],
});

// POST
MockApiClient.addMockResponse({
  url: '/projects/',
  method: 'POST',
  body: {id: 1, name: 'my project'},
});

// Complex matching
MockApiClient.addMockResponse({
  url: '/projects/',
  method: 'POST',
  body: {id: 2, name: 'other'},
  match: [
    MockApiClient.matchQuery({param: '1'}),
    MockApiClient.matchData({name: 'other'}),
  ],
});

// Error responses
MockApiClient.addMockResponse({
  url: '/projects/',
  body: {detail: 'Internal Error'},
  statusCode: 500,
});
```

Always await async assertions for network requests:

```tsx
// bad
expect(screen.getByText('Loaded Data')).toBeInTheDocument();

// good
expect(await screen.findByText('Loaded Data')).toBeInTheDocument();
```

Handle refetches in mutations — override mocks before the refetch:

```tsx
it('adds item and updates list', async () => {
  MockApiClient.addMockResponse({url: '/items/', body: []});

  const createRequest = MockApiClient.addMockResponse({
    url: '/items/',
    method: 'POST',
    body: {id: 1, name: 'New Item'},
  });

  render(<ItemList />);
  await userEvent.click(screen.getByRole('button', {name: 'Add Item'}));

  // Override mock before refetch happens
  MockApiClient.addMockResponse({
    url: '/items/',
    body: [{id: 1, name: 'New Item'}],
  });

  await waitFor(() => expect(createRequest).toHaveBeenCalled());
  expect(await screen.findByText('New Item')).toBeInTheDocument();
});
```
