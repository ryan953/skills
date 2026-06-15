# Icons and Images

## Icons

All icons live in `static/app/icons`. Never inline SVGs or place them in any other folder. Optimize SVGs using svgo or svgomg.

```tsx
// bad — inlined SVG
function Component() {
  return (
    <Button icon={
      <svg viewBox="0 0 16 16">
        <circle cx="8.00134" cy="8.4314" r="5.751412" />
      </svg>
    } />
  );
}

// bad — icon outside the icons folder
import {CustomIcon} from "./customIcon"

// good
import {IconExclamation} from "sentry/icons"
```

## Images

All images belong inside `static/app/images`. Import them via the `sentry-images` loader alias — never use static paths.

```tsx
// bad — static path
function Component() {
  return <Image src="/path/to/image.png" />;
}

// bad — relative import outside images folder
import image from './image.png';

// good
import image from 'sentry-images/example.png';

function Component() {
  return <Image src={image} />;
}
```
