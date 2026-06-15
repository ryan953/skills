# Prefer core asset components

Use core components for images, avatars, and disclosure patterns instead of building from scratch.

## Image

Use `<Image>` from `@sentry/scraps/image` instead of intrinsic `<img>`.

```tsx
// bad
function Component() {
  return <img src="/path/to/image.jpg" />;
}

// good
import {Image} from '@sentry/scraps/image';
import image from 'sentry-images/example.jpg';

function Component() {
  return <Image src={image} alt="Descriptive Alt Attribute" />;
}
```

## Avatars

Use the core avatar components from `static/app/components/core/avatar`:
- `<UserAvatar>`, `<TeamAvatar>`, `<ProjectAvatar>`, `<OrganizationAvatar>`, `<SentryAppAvatar>`, `<DocIntegrationAvatar>`
- For lists of avatars, use `<AvatarList>`.

```tsx
// bad
function Component() {
  return (
    <img
      src="/path/to/image.jpg"
      style={{width: 20, height: 20, borderRadius: '50%', objectFit: 'cover'}}
    />
  );
}

// good
import {UserAvatar} from '@sentry/scraps/avatar/userAvatar';

<UserAvatar user={user} />
```

## Disclosure

Use the core `<Disclosure>` component instead of reimplementing expand/collapse.

```tsx
// bad
function Component() {
  const [isExpanded, setIsExpanded] = useState(false);
  return (
    <div>
      <Button
        onClick={() => setIsExpanded(!isExpanded)}
        icon={<IconChevron direction={isExpanded ? 'down' : 'right'} />}
      >
        Title
      </Button>
      {isExpanded && <Container>Content</Container>}
    </div>
  );
}

// good
<Disclosure>
  <Disclosure.Title>Title</Disclosure.Title>
  <Disclosure.Content>Content</Disclosure.Content>
</Disclosure>
```
