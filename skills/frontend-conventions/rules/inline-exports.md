# Inline exports

Put `export` directly on the declaration. Do not define something and then export it separately.

## Examples

```tsx
// bad
function parseQuery(query: string) { ... }
export {parseQuery};

// bad
const DEFAULT_LIMIT = 25;
export {DEFAULT_LIMIT};

// good
export function parseQuery(query: string) { ... }
export const DEFAULT_LIMIT = 25;
```

## Exceptions — do NOT flag these

- Re-exports from other modules (`export {Thing} from './other'`)
- Renaming exports (`export {internalName as publicName}`)
- `export default` on a previously-defined identifier (sometimes necessary)
- Barrel files (`index.ts`) that only re-export
