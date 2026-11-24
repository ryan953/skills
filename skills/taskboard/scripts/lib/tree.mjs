// The Linear tree around a task's ticket: its parent, its sub-issues and its siblings.

const SIBLING_LIMIT = 10;

const isDone = c => c.stateType === 'completed' || c.stateType === 'canceled';

// Canceled sub-issues are not work, so they count toward neither side of "2 of 6 done".
function progress(children) {
  const live = children.filter(c => c.stateType !== 'canceled');
  return {done: live.filter(c => c.stateType === 'completed').length, total: live.length};
}

export function taskTree(task, {items, trees, itemTask}, label = k => k) {
  const linear = task.items.map(k => items[k]).filter(i => i?.type === 'linear');
  const primary = linear.find(i => i.key === task.id) ?? [...linear].sort((a, b) => a.key.localeCompare(b.key))[0];
  if (!primary) return null;
  const own = trees[primary.key];
  const parentId = primary.meta.parent;
  const parent = parentId ? trees[parentId] : null;
  if (!own && !parentId) return null;

  // The board shows open sub-issues; finished ones only count toward progress.
  const node = c => ({
    id: c.id,
    title: c.title,
    url: c.url,
    state: c.state,
    prs: c.prs.map(label),
    task: itemTask[c.id] ?? null,
    canDispatch: c.prs.length === 0,
  });
  const openSiblings = (parent?.children ?? []).filter(c => c.id !== primary.key && !isDone(c));
  return {
    self: primary.key,
    parent: parentId ? {id: parentId, title: parent?.title ?? null, url: parent?.url ?? null, progress: parent ? progress(parent.children) : null} : null,
    progress: own ? progress(own.children) : null,
    children: (own?.children ?? []).filter(c => !isDone(c)).map(node),
    siblings: openSiblings.slice(0, SIBLING_LIMIT).map(node),
    moreSiblings: Math.max(0, openSiblings.length - SIBLING_LIMIT),
  };
}

// A sub-issue that nothing tracks yet still gets a Dispatch button: build a one-ticket task
// from the tree, so dispatch writes a new-session brief for it.
export function subIssueTask(id, trees) {
  const c = Object.values(trees)
    .flatMap(t => t.children)
    .find(n => n.id === id);
  if (!c) return null;
  const item = {key: c.id, type: 'linear', title: c.title, url: c.url, open: !isDone(c), status: c.state, needsYou: false, roles: [], strong: c.prs, weak: [], meta: {stateType: c.stateType}};
  const stage = isDone(c) ? 'done' : c.stateType === 'started' ? 'fix' : 'validate';
  return {task: {id: c.id, title: c.title, kind: 'cycle', stage, items: [c.id], owner: null, notes: null, actions: []}, members: [item]};
}
