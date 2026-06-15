# Prefer layout components over styled wrappers

**Prerequisite:** Only check this rule if `styled` is imported in the file, or if raw HTML elements are used for layout.

Use `<Flex>`, `<Grid>`, and `<Container>` from `@sentry/scraps/layout` instead of styled components for layout.

## Flex

Use `<Flex>` instead of `styled('div')` with `display: flex`:

```tsx
import {Flex} from '@sentry/scraps/layout';

// bad
const Component = styled('div')`
  display: flex;
  flex-direction: column;
`;

// good
<Flex direction="column"></Flex>
```

## Grid

Use `<Grid>` instead of `styled('div')` with `display: grid`:

```tsx
import {Grid} from '@sentry/scraps/layout';

// bad
const Component = styled('div')`
  display: flex;
  flex-direction: column;
`;

// good
<Grid direction="column"></Grid>
```

## Container

Use `<Container>` for elements that need border or border-radius:

```tsx
import {Container} from '@sentry/scraps/layout';

// bad
const Component = styled('div')`
  padding: space(2);
  border: 1px solid ${p => p.theme.tokens.border.primary};
`;

// good
<Container padding="md" border="primary"></Container>
```

## Favor props over style attribute

```tsx
// bad
<Flex style={{width: "100%", padding: `${space(1)} ${space(1.5)}`}}>

// good
<Flex width="100%" padding="md lg">
```

## Use responsive props instead of styled media queries

```tsx
import {Flex} from '@sentry/scraps/layout';

// bad
const Component = styled('div')`
  display: flex;
  flex-direction: column;

  @media screen and (min-width: ${p => p.theme.breakpoints.md}) {
    flex-direction: row;
  }
`;

// good
<Flex direction={{xs: 'column', md: 'row'}}></Flex>
```

## Prefer gap or padding over margin

```tsx
import {Flex} from '@sentry/scraps/layout';

// bad
const Component = styled('div')`
  display: flex;
  flex-direction: column;
  gap: ${p => p.theme.spacing.lg};
`;

// good
<Flex gap="lg">
  <Child1 />
  <Child2 />
</Flex>
```

## Exceptions — do NOT flag these

- The styled component applies non-layout CSS (colors, borders, typography, transforms, animations) alongside layout
- The styled component uses dynamic props or complex interpolations that layout components can't express
- The styled component wraps a third-party component that needs specific CSS overrides
