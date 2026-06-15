# Consistent destructuring

When accessing multiple properties from one object, pick one style and stick with it. Prefer destructuring.

## Examples

```tsx
// bad — mixing styles
const {name} = props;
const avatar = props.avatar;
const size = props.size;

// good — destructure everything
const {name, avatar, size} = props;

// bad — mixing styles
const {data} = result;
console.log(result.isLoading);

// good
const {data, isLoading} = result;
```

## Exceptions — do NOT flag these

- Accessing a property only once in a large function where destructuring at the top would be premature
- Dynamic property access (`obj[key]`)
- Spreading the rest (`const {a, ...rest} = obj`) alongside dot access of the spread object
- The object is not destructured at all (consistent dot access is fine)
