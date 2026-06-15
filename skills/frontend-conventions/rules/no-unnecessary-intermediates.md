# No unnecessary intermediate variables

Don't introduce a variable only to immediately destructure or access it on the next line.

## Examples

```tsx
// bad
const result = useQuery(options);
const {data} = result;

// good
const {data} = useQuery(options);

// bad
const context = useContext(MyContext);
const value = context.value;

// good
const {value} = useContext(MyContext);
```

## Exceptions — do NOT flag these

- The intermediate variable is used more than once
- The intermediate variable is used in a type guard or conditional
- The expression is long/complex and naming it improves readability (use judgment — if the expression fits on one line, it probably doesn't need a name)
