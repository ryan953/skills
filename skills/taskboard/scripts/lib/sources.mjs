// Collectors. Each returns normalized items:
// {key, type, title, url, open, status, needsYou, needsReason, updatedAt, roles, strong, weak, meta}
// `strong` refs always link. `weak` refs are in reading order and only the first one
// that names a tracked item links, because later mentions are usually context.

import {execFile} from 'node:child_process';
import {readdirSync, readFileSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {promisify} from 'node:util';

import {closingRefs, DEFAULT_REPO, linearRefs, orderedRefs, prKey, prRefs} from './refs.mjs';

const run = promisify(execFile);
const BOTS = (process.env.TASKBOARD_BOTS ?? 'sentry-junior,cursor,seer-by-sentry,claude').split(',');
// Review requests that touch these paths are your area, so they are tasks, not queue noise.
const WATCH = new RegExp(process.env.TASKBOARD_WATCH ?? 'onboarding|agent[_-]?handoff', 'i');


// ---------- GitHub ----------

const PR_FIELDS = `
  number title url state isDraft updatedAt headRefName body
  author { login }
  repository { nameWithOwner isArchived }
  reviewDecision
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
  files(first: 100) { nodes { path } }
`;

async function gql(query, variables = {}) {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [k, v] of Object.entries(variables)) args.push('-F', `${k}=${v}`);
  const {stdout} = await run('gh', args, {maxBuffer: 64 * 1024 * 1024});
  return JSON.parse(stdout).data;
}

async function searchPrs(q) {
  const data = await gql(
    `query($q: String!) { search(type: ISSUE, query: $q, first: 100) { nodes { ... on PullRequest { ${PR_FIELDS} } } } }`,
    {q}
  );
  // A PR in an archived repo can never merge or change, so it is never work.
  return data.search.nodes.filter(n => n?.number && !n.repository.isArchived);
}

function prItem(node, me, roles, teams) {
  const repo = node.repository.nameWithOwner;
  const author = (node.author?.login ?? 'ghost').replace(/\[bot\]$/, '');
  const status = node.state === 'MERGED' ? 'merged' : node.state === 'CLOSED' ? 'closed' : node.isDraft ? 'draft' : 'open';
  const checks = node.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? null;
  const mine = author === me || roles.includes('bot');
  const open = node.state === 'OPEN';
  let needsReason = null;
  if (open && mine && node.reviewDecision === 'CHANGES_REQUESTED') needsReason = 'changes requested';
  else if (open && mine && (checks === 'FAILURE' || checks === 'ERROR')) needsReason = 'CI failing';
  // Branch and title name the PR's own ticket; the body can list several `Fixes` lines.
  const strong = [...new Set([...linearRefs(`${node.headRefName} ${node.title}`, teams), ...closingRefs(node.body, teams)])];
  return {
    key: prKey(repo, node.number),
    type: 'pr',
    title: node.title,
    url: node.url,
    open,
    status,
    needsYou: Boolean(needsReason),
    needsReason,
    updatedAt: node.updatedAt,
    roles: [...new Set(author === me ? ['author', ...roles] : roles)],
    strong,
    weak: [],
    meta: {
      repo,
      number: node.number,
      author,
      branch: node.headRefName,
      draft: node.isDraft,
      review: node.reviewDecision,
      checks,
      watched: (node.files?.nodes ?? []).some(f => WATCH.test(f.path)),
    },
  };
}

export async function fetchGithub(teams) {
  const me = (await run('gh', ['api', 'user', '--jq', '.login'])).stdout.trim();
  const queries = [
    ['author', `is:pr is:open author:${me}`],
    ['review', `is:pr is:open review-requested:${me}`],
    ['review-direct', `is:pr is:open user-review-requested:${me}`],
    ['reviewed', `is:pr is:open reviewed-by:${me} -author:${me}`],
    ...BOTS.map(b => ['bot', `is:pr is:open author:app/${b} involves:${me}`]),
  ];
  const results = await Promise.all(queries.map(([role, q]) => searchPrs(q).then(nodes => ({role, nodes}))));
  const byKey = new Map();
  for (const {role, nodes} of results) {
    for (const n of nodes) {
      const key = prKey(n.repository.nameWithOwner, n.number);
      const prev = byKey.get(key);
      byKey.set(key, {node: n, roles: [...(prev?.roles ?? []), ...(role === 'author' ? [] : [role])]});
    }
  }
  return {me, items: [...byKey.values()].map(({node, roles}) => prItem(node, me, roles, teams))};
}

// Review detail is heavy (threads, every check run), so it is fetched only for open PRs,
// in small batches: one search with these fields times out.
const AGENT_REVIEW = 'sentry-warden';
// Minor bot reviews: a fuller review usually follows, so they are counted, not shown as reviewed.
const MINOR_REVIEW = new Set((process.env.TASKBOARD_MINOR_REVIEWERS ?? 'cursor,sentry,github-advanced-security').split(','));
const PASSED = new Set(['SUCCESS', 'NEUTRAL']);
const FAILED = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE', 'ACTION_REQUIRED']);
const PENDING = new Set(['PENDING', 'EXPECTED', 'IN_PROGRESS', 'QUEUED', 'WAITING']);

const DETAIL_FIELDS = `
  additions deletions changedFiles
  headCommit: commits(last: 1) { nodes { commit { committedDate } } }
  reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { author { login } } } } }
  reviews(states: PENDING, first: 5) { nodes { author { login } comments { totalCount } } }
  commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) {
    checkRunCountsByState { state count }
    statusContextCountsByState { state count }
    nodes { ... on CheckRun { name conclusion } }
  } } } } }
`;

export function prDetail(node, me) {
  const login = t => (t.comments.nodes[0]?.author?.login ?? '').replace(/\[bot\]$/, '');
  const threads = node.reviewThreads?.nodes ?? [];
  const ctx = node.commits?.nodes?.[0]?.commit?.statusCheckRollup?.contexts;
  const checks = {passed: 0, failed: 0, pending: 0};
  for (const {state, count} of [...(ctx?.checkRunCountsByState ?? []), ...(ctx?.statusContextCountsByState ?? [])]) {
    if (PASSED.has(state)) checks.passed += count;
    else if (FAILED.has(state)) checks.failed += count;
    else if (PENDING.has(state)) checks.pending += count;
  }
  const wardenRuns = (ctx?.nodes ?? []).filter(c => c?.name === 'warden' || c?.name?.startsWith('warden:'));
  const wardenThreads = threads.filter(t => login(t) === AGENT_REVIEW);
  const warden = wardenRuns.length || wardenThreads.length
    ? {
        running: wardenRuns.some(c => c.conclusion === null),
        open: wardenThreads.filter(t => !t.isResolved).length,
        found: wardenThreads.length,
      }
    : null;
  const pending = (node.reviews?.nodes ?? []).find(r => r.author?.login === me);
  return {
    // The worker pushes the commit it makes, so the head commit's time stands in for the push.
    headAt: node.headCommit?.nodes?.[0]?.commit?.committedDate ?? null,
    additions: node.additions,
    deletions: node.deletions,
    files: node.changedFiles,
    unresolved: threads.filter(t => !t.isResolved).length,
    checks,
    warden,
    minorBots: threads.filter(t => !t.isResolved && MINOR_REVIEW.has(login(t))).length,
    draftComments: pending ? pending.comments.totalCount : 0,
  };
}

export async function fetchPrDetail(keys, me) {
  const out = new Map();
  const batches = [];
  for (let i = 0; i < keys.length; i += 20) batches.push(keys.slice(i, i + 20));
  await Promise.all(
    batches.map(async chunk => {
      const parts = chunk.map((k, j) => {
        const [repo, num] = k.split('#');
        const [owner, name] = repo.split('/');
        return `p${j}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) { pullRequest(number: ${num}) { ${DETAIL_FIELDS} } }`;
      });
      try {
        const data = await gql(`query { ${parts.join('\n')} }`);
        chunk.forEach((k, j) => {
          const node = data?.[`p${j}`]?.pullRequest;
          if (node) out.set(k, prDetail(node, me));
        });
      } catch {
        // Detail is extra: a failed batch leaves those PRs without it, and the sync goes on.
      }
    })
  );
  return out;
}

export async function resolvePrs(keys, me, teams) {
  if (!keys.length) return [];
  const out = [];
  for (let i = 0; i < keys.length; i += 40) {
    const chunk = keys.slice(i, i + 40);
    const parts = chunk.map((k, j) => {
      const [repo, num] = k.split('#');
      const [owner, name] = repo.split('/');
      return `p${j}: repository(owner: ${JSON.stringify(owner)}, name: ${JSON.stringify(name)}) { pullRequest(number: ${num}) { ${PR_FIELDS} } }`;
    });
    let data;
    try {
      data = await gql(`query { ${parts.join('\n')} }`);
    } catch (err) {
      // One missing repo fails the whole batch; fall back to one call per PR.
      data = {};
      for (const [j, part] of parts.entries()) {
        try {
          Object.assign(data, await gql(`query { ${part} }`));
        } catch {
          data[`p${j}`] = null;
        }
      }
    }
    for (const [j] of chunk.entries()) {
      const node = data?.[`p${j}`]?.pullRequest;
      if (node && !node.repository.isArchived) out.push(prItem(node, me, ['ref'], teams));
    }
  }
  return out;
}

// ---------- Linear ----------

const ISSUE_FIELDS = `
  identifier title url priority updatedAt
  state { name type }
  assignee { name isMe }
  creator { isMe }
  team { key }
  attachments { nodes { url } }
  parent { identifier }
`;

async function linearApi(query) {
  // The CLI prints a direnv banner on stderr when run inside a repo; run it from $HOME.
  const {stdout} = await run('linear', ['api', query], {cwd: homedir(), maxBuffer: 64 * 1024 * 1024});
  const clean = stdout.replace(/\x1b\[[0-9;]*m/g, '');
  return JSON.parse(clean.slice(clean.indexOf('{'))).data;
}

function linearItem(n) {
  const open = !['completed', 'canceled'].includes(n.state.type);
  const strong = [...new Set(n.attachments.nodes.flatMap(a => prRefs(a.url)))];
  return {
    key: n.identifier,
    type: 'linear',
    title: n.title,
    url: n.url,
    open,
    status: n.state.name,
    needsYou: false,
    needsReason: null,
    updatedAt: n.updatedAt,
    roles: [n.assignee?.isMe && 'assignee', n.creator?.isMe && 'creator'].filter(Boolean),
    strong,
    weak: [],
    meta: {stateType: n.state.type, assignee: n.assignee?.name ?? null, priority: n.priority, team: n.team.key, parent: n.parent?.identifier ?? null},
  };
}

const OPEN_FILTER = `filter: { state: { type: { nin: ["completed", "canceled"] } } }`;

export async function fetchLinear() {
  const data = await linearApi(`query { viewer {
    assignedIssues(first: 150, ${OPEN_FILTER}) { nodes { ${ISSUE_FIELDS} } }
    createdIssues(first: 150, ${OPEN_FILTER}) { nodes { ${ISSUE_FIELDS} } }
  } }`);
  const byKey = new Map();
  for (const n of [...data.viewer.assignedIssues.nodes, ...data.viewer.createdIssues.nodes]) byKey.set(n.identifier, n);
  return [...byKey.values()].map(linearItem);
}

export async function resolveLinear(ids) {
  const out = [];
  for (let i = 0; i < ids.length; i += 50) {
    const chunk = ids.slice(i, i + 50);
    const parts = chunk.map((id, j) => `i${j}: issue(id: ${JSON.stringify(id)}) { ${ISSUE_FIELDS} }`);
    let data = {};
    try {
      data = await linearApi(`query { ${parts.join('\n')} }`);
    } catch {
      for (const part of parts) {
        try {
          Object.assign(data, await linearApi(`query { ${part} }`));
        } catch {}
      }
    }
    for (const [j] of chunk.entries()) if (data?.[`i${j}`]) out.push(linearItem(data[`i${j}`]));
  }
  return out;
}

const TREE_FIELDS = `
  identifier title url state { name type }
  children(first: 100) { nodes { identifier title url state { name type } attachments { nodes { url } } } }
`;

const treeNode = n => ({
  id: n.identifier,
  title: n.title,
  url: n.url,
  state: n.state.name,
  stateType: n.state.type,
  prs: [...new Set((n.attachments?.nodes ?? []).flatMap(a => prRefs(a.url)))],
});

// Sub-issues are display data, not items: one parent can hold 80 of them, and making each
// a task would bury the board. Only issues that have children get an entry.
export async function fetchTrees(ids) {
  const trees = {};
  const batches = [];
  for (let i = 0; i < ids.length; i += 10) batches.push(ids.slice(i, i + 10));
  await Promise.all(
    batches.map(async chunk => {
      const parts = chunk.map((id, j) => `t${j}: issue(id: ${JSON.stringify(id)}) { ${TREE_FIELDS} }`);
      let data = {};
      try {
        data = await linearApi(`query { ${parts.join('\n')} }`);
      } catch {
        // The tree is extra: a failed batch leaves those issues without one.
      }
      for (const [j] of chunk.entries()) {
        const n = data?.[`t${j}`];
        if (n?.children.nodes.length) trees[n.identifier] = {...treeNode(n), children: n.children.nodes.map(treeNode)};
      }
    })
  );
  return trees;
}

// One ticket for the Overview pane, fetched when the pane opens rather than on every sync.
export async function fetchIssueDetail(id) {
  const data = await linearApi(`query { issue(id: ${JSON.stringify(id)}) {
    ${TREE_FIELDS}
    description priorityLabel branchName
    assignee { name }
    labels { nodes { name } }
    project { name }
    cycle { number name }
    team { key name }
    comments(first: 100) { nodes { body createdAt user { name } botActor { name } } }
    parent { ${TREE_FIELDS} }
  } }`);
  const n = data?.issue;
  if (!n) return null;
  const tree = t => ({...treeNode(t), children: t.children.nodes.map(treeNode)});
  return {
    ...treeNode(n),
    description: n.description ?? '',
    priority: n.priorityLabel,
    assignee: n.assignee?.name ?? null,
    labels: n.labels.nodes.map(l => l.name),
    project: n.project?.name ?? null,
    cycle: n.cycle ? (n.cycle.name ?? `Cycle ${n.cycle.number}`) : null,
    team: n.team ? `${n.team.name} (${n.team.key})` : null,
    branchName: n.branchName,
    comments: n.comments.nodes
      .map(c => ({author: c.user?.name ?? c.botActor?.name ?? 'unknown', at: c.createdAt, body: c.body}))
      .sort((a, b) => b.at.localeCompare(a.at)),
    own: tree(n),
    parent: n.parent ? tree(n.parent) : null,
  };
}

export async function linearTeams() {
  const data = await linearApi(`query { teams(first: 100) { nodes { key } } }`);
  return new Set(data.teams.nodes.map(t => t.key));
}

// ---------- Claude Code desktop sessions ----------

// The desktop app keeps one JSON file per session. This is an internal format,
// so every field is read defensively and the collector can be skipped.
const SESSIONS_ROOT = join(homedir(), 'Library', 'Application Support', 'Claude', 'claude-code-sessions');

function* sessionFiles(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e);
    if (e.startsWith('local_') && e.endsWith('.json')) yield p;
    else if (statSync(p).isDirectory()) yield* sessionFiles(p);
  }
}

const parse = v => {
  if (typeof v !== 'string') return v;
  try {
    return JSON.parse(v);
  } catch {
    return v;
  }
};

// The files have no running flag. They record when a turn was last sent and when a turn
// last ended, so a send after the last end means a turn is running. This is the app's
// internal format, so the rule lives here and nowhere else.
export function turnState(s) {
  const sent = Number(parse(s.latestUserFrameAt) ?? 0);
  const ended = Number(parse(s.lastTurnEdgeAt) ?? 0);
  if (parse(s.isArchived) === true || !sent || sent <= ended) return {running: false, turnStartedAt: null};
  return {running: true, turnStartedAt: new Date(sent).toISOString()};
}

// Only the turn state of each session: cheap enough for the mod to read every minute.
export function readSessionTurns() {
  const self = process.env.CLAUDE_CODE_SESSION_ID;
  const out = new Map();
  for (const file of sessionFiles(self ? sessionsDir(self) : SESSIONS_ROOT)) {
    try {
      const s = JSON.parse(readFileSync(file, 'utf8'));
      if (s.sessionId && !(self && s.cliSessionId === self)) out.set(s.sessionId, turnState(s));
    } catch {}
  }
  return out;
}

// The root holds one folder per account and org. Read only the folder that holds this
// session, since the app can only show and archive sessions from that one.
function sessionsDir(self) {
  if (process.env.TASKBOARD_SESSIONS_DIR) return process.env.TASKBOARD_SESSIONS_DIR;
  for (const file of sessionFiles(SESSIONS_ROOT)) {
    try {
      if (JSON.parse(readFileSync(file, 'utf8')).cliSessionId === self) return join(file, '..');
    } catch {}
  }
  return SESSIONS_ROOT;
}

export function readClaudeSessions(teams) {
  const self = process.env.CLAUDE_CODE_SESSION_ID;
  const byKey = new Map();
  for (const file of sessionFiles(self ? sessionsDir(self) : SESSIONS_ROOT)) {
    let s;
    try {
      s = JSON.parse(readFileSync(file, 'utf8'));
    } catch {
      continue;
    }
    // The manager session is not a task of its own.
    if (!s.sessionId || (self && s.cliSessionId === self)) continue;
    const recorded = (parse(s.prs) ?? []).map(p => prKey(p.repo ?? DEFAULT_REPO, p.prNumber));
    const summary = parse(s.postTurnSummary) ?? {};
    const title = s.title ?? '(untitled)';
    // The title names the task. A session can open PRs for several tickets, so its PR list
    // only decides the link when the title names nothing. Branch names are ignored: sessions
    // share checkouts, so one branch shows up in many unrelated sessions.
    const titleRefs = orderedRefs(title, teams);
    const strong = titleRefs.length ? titleRefs : recorded.slice(0, 1);
    const weak = [...new Set([...(titleRefs.length ? recorded : recorded.slice(1)), ...orderedRefs(`${summary.status_detail ?? ''} ${summary.summary ?? ''}`, teams)])];
    const needsReason = summary.needs_action || (parse(s.interruptedAwaitingPerson) ? 'waiting for you' : null);
    const archived = parse(s.isArchived) === true;
    const updatedAt = s.lastActivityAt ? new Date(Number(s.lastActivityAt)).toISOString() : null;
    const item = {
      key: s.sessionId,
      type: 'claude',
      title,
      url: `claude://claude.ai/epitaxy/${s.sessionId}`,
      open: !archived,
      status: archived ? 'archived' : 'open',
      needsYou: Boolean(needsReason) && !archived,
      needsReason: needsReason || null,
      updatedAt,
      roles: [],
      strong,
      weak,
      meta: {cwd: s.cwd, active: true, prs: recorded, ...turnState(s)},
    };
    const prev = byKey.get(item.key);
    if (!prev || (prev.updatedAt ?? '') < (updatedAt ?? '')) byKey.set(item.key, item);
  }
  return [...byKey.values()];
}

// ---------- jr (Junior) ----------

// jr is only reachable through its MCP tools, so the manager saves their output
// with `taskboard ingest jr` and this reads the normalized snapshot back.
export function normalizeJr(raw, teams, {archived = false} = {}) {
  const list = Array.isArray(raw) ? raw : (raw.conversations ?? []);
  return list.map(c => {
    const strong = orderedRefs(c.title, teams);
    // Summaries cite related work ("#131484 changed a different blocker"), so they are weak refs.
    const weak = orderedRefs(c.summary, teams);
    const needsReason = c.status === 'needs_input' || c.treeState === 'needs_you' ? 'jr needs input' : null;
    return {
      key: c.conversationId,
      type: 'jr',
      title: c.title,
      url: c.url,
      open: !archived,
      status: archived ? 'archived' : c.status,
      needsYou: Boolean(needsReason) && !archived,
      needsReason,
      updatedAt: c.lastSeenAt,
      roles: [],
      strong,
      weak,
      meta: {lastSeenAt: c.lastSeenAt, watching: c.watching, running: Boolean(c.turnActive), active: c.status !== 'done', summary: c.summary},
    };
  });
}
