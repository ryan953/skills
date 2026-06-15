# No unnecessary destructuring renames

Don't rename a destructured property unless the new name is meaningfully more descriptive in context.

## Examples

```tsx
// bad — rename adds no clarity
const {mutate: handleAction} = useMutation({...});
handleAction({id, isApproved: true});

// good — use the original name
const {mutate} = useMutation({...});
mutate({id, isApproved: true});

// bad — rename is just a synonym
const {data: result} = useQuery({...});
return result;

// good
const {data} = useQuery({...});
return data;

// bad — generic rename on a well-known hook return
const {isPending: isLoading} = useMutation({...});
```

## Exceptions — do NOT flag these

- The rename resolves a naming conflict (`const {data: userData} = useUser(); const {data: orgData} = useOrg();`)
- The rename adds domain-specific meaning that the original name lacks (`const {data: projects} = useQuery(...)`)
- The property name is very short or cryptic and the rename improves readability (`const {t: theme}`)
- The rename aligns with an existing convention in the file or component API
