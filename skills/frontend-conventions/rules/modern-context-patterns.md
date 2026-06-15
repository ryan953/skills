# Modern React context patterns (React 19)

**Prerequisite:** Only check this rule if `createContext`, `.Provider`, `.Consumer`, or `.displayName` appears in the diff.

React 19 simplifies context usage. Follow these patterns.

## No `.Provider` — render context directly

React 19 lets you render `<Context value={...}>` without `.Provider`.

```tsx
// bad
<MyContext.Provider value={value}>
  {children}
</MyContext.Provider>

// good
<MyContext value={value}>
  {children}
</MyContext>
```

Also do not export `.Provider` as an alias:

```tsx
// bad
export const MyProvider = MyContext.Provider;

// good
export const MyProvider = MyContext;
```

## No `.Consumer` — use `useContext` hook

The `Context.Consumer` render-prop pattern is obsolete. Use the `useContext` hook instead.

```tsx
// bad
<OnDemandControlConsumer>
  {context => (
    <ChildComponent onDemandControl={context} />
  )}
</OnDemandControlConsumer>

// good
function ParentComponent() {
  const onDemandControl = useOnDemandControl();
  return <ChildComponent onDemandControl={onDemandControl} />;
}
```

## No `.displayName` on context objects

React 19 infers the display name from the variable name. Setting it manually is unnecessary.

```tsx
// bad
const WidgetSyncCtx = createContext<WidgetSyncContext | undefined>(undefined);
WidgetSyncCtx.displayName = 'WidgetSyncContext';

// good — React 19 infers the name
const WidgetSyncCtx = createContext<WidgetSyncContext | undefined>(undefined);
```

## Exceptions — do NOT flag these

- Code that must support React 18 or earlier (check the project's React version)
- `.displayName` used on components (not context), where it aids debugging of HOCs or `memo`
