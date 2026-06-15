# Prefer typography components over styled wrappers

**Prerequisite:** Only check this rule if `styled` is imported, or if raw HTML heading/text elements are used.

Use `<Heading>` and `<Text>` from `@sentry/scraps/text` instead of styled components or raw HTML elements for typography.

## Heading

Do not use or style `h1`–`h6` intrinsic elements. Use `<Heading as="h1...h6">` instead.

```tsx
import {Heading} from '@sentry/scraps/text';

// bad
const Title = styled('h2')`
  font-size: ${p => p.theme.fontSize.md};
  font-weight: bold;
`;

// bad
function Component() {
  return <h4>Title</h4>
}

// good
<Heading as="h2">Heading</Heading>

// good
function Component() {
  return <Heading as="h4">Title</Heading>
}
```

## Text

Do not style `span`, `p`, or `div` for typography. Use `<Text>` instead.

```tsx
import {Text} from '@sentry/scraps/text';

// bad
const Label = styled('span')`
  color: ${p => p.theme.tokens.content.secondary};
  font-size: ${p => p.theme.fontSizes.small};
`;

// bad — raw intrinsic elements
function Content() {
  return (
    <div>
      <p>This is a paragraph of content</p>
      <span>Status: Active</span>
    </div>
  );
}

// good
<Text variant="muted" size="sm">Text</Text>

// good
function Content() {
  return (
    <div>
      <Text as="p" variant="muted" density="comfortable">
        This is a paragraph of content
      </Text>
      <Text as="span" bold uppercase>
        Status: Active
      </Text>
    </div>
  );
}
```

## Split layout from typography

Don't couple typography with layout in a single styled component. Use layout primitives and `<Text>`/`<Heading>` separately.

```tsx
// bad
const Component = styled('div')`
  display: flex;
  flex-direction: column;
  color: ${p => p.theme.tokens.content.secondary};
  font-size: ${p => p.theme.fontSize.lg};
`;

// good
<Flex direction="column">
  <Text muted size="lg">...</Text>
</Flex>
```

## Exceptions — do NOT flag these

- The text styling is purely for non-standard visual effects (animations, gradients on text)
- The component is a low-level design system primitive itself
