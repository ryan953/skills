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
    meta: {stateType: n.state.type, assignee: n.assignee?.name ?? null, priority: n.priority, team: n.team.key},
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
      meta: {cwd: s.cwd, running: false, active: true, prs: recorded},
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
