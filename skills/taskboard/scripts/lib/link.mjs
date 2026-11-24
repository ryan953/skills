// Group items (Linear issues, PRs, jr conversations, Claude sessions) into tasks,
// derive each task's stage, and list the clean-up actions the manager can offer.

const NOISE_AUTHORS = new Set(['dependabot', 'github-actions', 'renovate', 'getsantry']);
const STAGE_ORDER = ['needs-you', 'merge', 'iterate', 'review', 'fix', 'validate', 'verify', 'adhoc', 'done'];

class UnionFind {
  parent = new Map();
  find(x) {
    if (!this.parent.has(x)) this.parent.set(x, x);
    let p = this.parent.get(x);
    if (p !== x) {
      p = this.find(p);
      this.parent.set(x, p);
    }
    return p;
  }
  union(a, b) {
    const ra = this.find(a);
    const rb = this.find(b);
    if (ra !== rb) this.parent.set(rb, ra);
  }
}

function edgesOf(item, known) {
  // A summary's first tracked ref is its subject; later ones are usually context
  // ("VDY-445 is related but distinct"), so only that one links.
  const firstWeak = item.weak.find(k => known.has(k));
  return firstWeak ? [...item.strong, firstWeak] : item.strong;
}

// Items that stand alone and only matter in bulk: bot PRs, team review requests outside
// your watched paths, and tickets you filed but nobody linked to your work. They are counted, not shown as tasks.
function bucketOf(item) {
  if (item.type === 'pr') {
    if (NOISE_AUTHORS.has(item.meta.author)) return 'queue';
    if (item.roles.length > 0 && item.roles.every(r => r === 'review') && !item.meta.watched) return 'queue';
  }
  if (item.type === 'linear' && item.roles.length > 0 && !item.roles.includes('assignee')) return 'backlog';
  return null;
}

function taskTitle(items) {
  const pick = t => items.find(i => i.type === t)?.title;
  return pick('linear') ?? pick('pr') ?? pick('jr') ?? pick('claude') ?? '(untitled)';
}

function stableId(keys, items, previous) {
  const prevIds = new Set();
  for (const k of keys) {
    const id = previous?.itemTask?.[k];
    if (id) prevIds.add(id);
  }
  // When two earlier tasks merge, keep the older-sorting id so links in notes survive.
  if (prevIds.size) return [...prevIds].sort()[0];
  const byType = t => items.filter(i => i.type === t).map(i => i.key).sort();
  return byType('linear')[0] ?? byType('pr')[0] ?? byType('jr')[0] ?? byType('claude')[0];
}

// A session or jr question about a ticket and PR that are both finished is stale:
// the task is done, and the conversation is something to archive, not to answer.
function liveAsks(items) {
  const tracked = items.filter(i => i.type === 'pr' || i.type === 'linear');
  const workOpen = !tracked.length || tracked.some(i => i.open);
  return items.filter(i => i.open && i.needsYou && (workOpen || i.type === 'pr' || i.type === 'linear'));
}

function deriveStage(items) {
  const prs = items.filter(i => i.type === 'pr');
  const linear = items.filter(i => i.type === 'linear');
  const openPrs = prs.filter(i => i.open);
  const openLinear = linear.filter(i => i.open);
  if (liveAsks(items).length) return 'needs-you';
  if (openPrs.length) {
    const ours = openPrs.filter(p => p.roles.some(r => r === 'author' || r === 'bot'));
    if (!ours.length) return 'review';
    const ready = ours.some(p => !p.meta.draft && p.meta.review === 'APPROVED' && p.meta.checks === 'SUCCESS');
    return ready ? 'merge' : 'iterate';
  }
  if (openLinear.length) {
    if (prs.some(p => p.status === 'merged')) return 'verify';
    return openLinear.some(l => l.meta.stateType === 'started') ? 'fix' : 'validate';
  }
  if (!prs.length && !linear.length) return items.some(i => i.open && i.meta.active) ? 'adhoc' : 'done';
  return 'done';
}

function deriveKind(items) {
  const prs = items.filter(i => i.type === 'pr');
  const hasLinear = items.some(i => i.type === 'linear');
  if (!hasLinear && prs.length && prs.every(p => !p.roles.some(r => r === 'author' || r === 'bot'))) {
    return 'review';
  }
  if (!hasLinear && !prs.length) return 'adhoc';
  return 'cycle';
}

function actionsFor(task, items) {
  const out = [];
  const byKey = new Map(items.map(i => [i.key, i]));
  const members = task.items.map(k => byKey.get(k));
  const live = t => members.filter(i => i.type === t && i.open);

  if (task.stage === 'done') {
    for (const i of [...live('jr'), ...live('claude')]) {
      if (i.meta.running) continue;
      out.push({type: 'archive', item: i.key, reason: 'task is done'});
    }
  } else {
    // Keep one session per task: the owner, or else the most recent. Others are leftovers from re-runs.
    const sessions = live('claude').sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? ''));
    const keep = sessions.find(s => s.key === task.owner) ?? sessions[0];
    for (const s of sessions) {
      if (s === keep || s.meta.running) continue;
      out.push({type: 'archive', item: s.key, reason: `duplicate of ${keep.key}`});
    }
  }

  const prs = members.filter(i => i.type === 'pr');
  for (const l of members.filter(i => i.type === 'linear' && i.open)) {
    const linked = prs.filter(p => l.strong.includes(p.key) || p.strong.includes(l.key));
    if (linked.length && linked.every(p => p.status === 'merged')) {
      out.push({type: 'close-linear', item: l.key, reason: `all linked PRs merged (${linked.map(p => p.key).join(', ')})`});
    }
  }
  for (const i of liveAsks(members)) out.push({type: 'needs-you', item: i.key, reason: i.needsReason});
  return out;
}

export function link(allItems, {previous = null, overrides = {}} = {}) {
  const ignore = new Set(overrides.ignore ?? []);
  const split = new Set(overrides.split ?? []);
  const items = allItems.filter(i => !ignore.has(i.key));
  const known = new Set(items.map(i => i.key));
  const uf = new UnionFind();

  for (const item of items) {
    uf.find(item.key);
    if (split.has(item.key)) continue;
    for (const k of edgesOf(item, known)) {
      if (known.has(k) && !split.has(k)) uf.union(item.key, k);
    }
  }
  for (const [a, b] of overrides.join ?? []) if (known.has(a) && known.has(b)) uf.union(a, b);
  // A dispatched worker belongs to its task even when its title names nothing the linker knows.
  for (const t of previous?.tasks ?? []) {
    const anchor = t.items.find(k => known.has(k) && k !== t.owner);
    if (t.owner && known.has(t.owner) && anchor && !split.has(t.owner)) uf.union(anchor, t.owner);
  }

  const groups = new Map();
  for (const item of items) {
    const root = uf.find(item.key);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(item);
  }

  const tasks = [];
  const queue = [];
  const backlog = [];
  for (const members of groups.values()) {
    const bucket = members.length === 1 && bucketOf(members[0]);
    if (bucket) {
      (bucket === 'queue' ? queue : backlog).push(members[0].key);
      continue;
    }
    const keys = members.map(i => i.key).sort();
    const id = stableId(keys, members, previous);
    const prevTask = previous?.tasks?.find(t => t.id === id);
    const task = {
      id,
      title: prevTask?.titleOverride ?? taskTitle(members),
      kind: prevTask?.kindOverride ?? deriveKind(members),
      stage: deriveStage(members),
      items: keys,
      // Fields the manager or the user set by hand carry over between syncs.
      owner: prevTask?.owner ?? null,
      notes: prevTask?.notes ?? null,
      titleOverride: prevTask?.titleOverride ?? null,
      kindOverride: prevTask?.kindOverride ?? null,
    };
    task.actions = actionsFor(task, items);
    tasks.push(task);
  }
  tasks.sort((a, b) => STAGE_ORDER.indexOf(a.stage) - STAGE_ORDER.indexOf(b.stage) || a.id.localeCompare(b.id));

  const itemTask = {};
  for (const t of tasks) for (const k of t.items) itemTask[k] = t.id;

  return {tasks, queue: queue.sort(), backlog: backlog.sort(), itemTask, changes: diff(previous, tasks, items)};
}

function diff(previous, tasks, items) {
  if (!previous) return [];
  const out = [];
  const prevTasks = new Map((previous.tasks ?? []).map(t => [t.id, t]));
  for (const t of tasks) {
    const p = prevTasks.get(t.id);
    if (!p) out.push({type: 'new-task', task: t.id, detail: t.title});
    else if (p.stage !== t.stage) out.push({type: 'stage', task: t.id, detail: `${p.stage} -> ${t.stage}`});
  }
  const prevItems = previous.items ?? {};
  for (const i of items) {
    const p = prevItems[i.key];
    if (p && p.status !== i.status) out.push({type: 'status', item: i.key, detail: `${p.status} -> ${i.status}`});
  }
  return out;
}

export {STAGE_ORDER};
