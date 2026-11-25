// The board's tree. A task with a ticket sits under the ticket's project, or with no project
// under the ticket's team; its PRs ride along inside the task. A PR with no ticket sits under
// its repo, then your role on it, then its author. A task with neither goes under Other.
// A level that would only repeat its parent is left out: your own PRs sit straight under
// "Your PRs" (only bot authors get a level there), and a team review with one team is one heading.
// PRs with no ticket that you unsubscribed from go last, under Unsubscribed, folded.

import {edgesOf, STAGE_ORDER} from './link.mjs';

const ROLES = [
  // A bot's PR made for you counts as yours; it sits under the bot's name.
  ['mine', 'Your PRs'],
  ['direct', 'Review requested of you'],
  ['team', 'Team review'],
  ['reviewed', 'You reviewed'],
  ['other', 'Other PRs'],
];
// Team review requests come from CODEOWNERS and can number 40 or more, so they start folded.
const FOLDED_ROLES = new Set(['team']);

const BOT_NAMES = {'sentry-junior': 'jr', 'seer-by-sentry': 'seer'};
// Ledgers written before the fetch kept the author's type only know bots by name.
const KNOWN_BOTS = new Set(['dependabot', 'renovate', 'github-actions', 'getsantry', 'sentry-junior', 'seer-by-sentry', 'cursor', 'claude', 'copilot']);

export function prRole(pr) {
  const r = new Set(pr.roles);
  if (r.has('author') || r.has('bot')) return 'mine';
  if (r.has('review-direct')) return 'direct';
  if (r.has('review')) return 'team';
  if (r.has('reviewed')) return 'reviewed';
  return 'other';
}

export function prAuthor(pr, me) {
  const login = pr.meta.author;
  if (pr.meta.isBot ?? KNOWN_BOTS.has(login)) return BOT_NAMES[login] ?? login;
  return login === me ? 'you' : 'human';
}

// The owner decides when it can; open items outrank closed ones, which may be stale links.
function pick(task, items, type) {
  const members = task.items.map(k => items[k]).filter(Boolean);
  return [items[task.owner], ...members.filter(i => i.open), ...members].find(i => i?.type === type) ?? null;
}

export function taskPlace(task, items, me) {
  const ticket = pick(task, items, 'linear');
  if (ticket) {
    return ticket.meta.project ? {kind: 'project', project: ticket.meta.project} : {kind: 'team', team: ticket.meta.teamName ?? ticket.meta.team};
  }
  const pr = pick(task, items, 'pr');
  if (pr) return prPlace(pr, me);
  return {kind: 'other'};
}

function prPlace(pr, me) {
  const role = prRole(pr);
  return {kind: 'pr', repo: pr.meta.repo, role, team: role === 'team' ? (pr.meta.reviewTeams?.[0] ?? 'unknown team') : null, author: prAuthor(pr, me)};
}

const NOUN = {claude: 'Claude session', jr: 'jr conversation', linear: 'ticket', pr: 'PR'};

// A card with no ticket can hold PRs from more than one repo while it sits under one repo's
// heading, so it says which items tie its PRs together: the ones whose own links name two or more.
export function linkedBy(task, items) {
  const prs = new Set(task.items.filter(k => items[k]?.type === 'pr' && items[k].open));
  if (prs.size < 2) return null;
  const known = new Set(Object.keys(items));
  const linkers = task.items.map(k => items[k]).filter(i => i && edgesOf(i, known).filter(k => prs.has(k)).length >= 2);
  // A ticket's own PRs need no explaining: they sit inside the ticket's card.
  if (!linkers.length || linkers.some(i => i.type === 'linear')) return null;
  const byType = Map.groupBy(linkers, i => i.type);
  const names = [...byType].map(([type, list]) =>
    list.length === 1 && (type === 'linear' || type === 'pr') ? list[0].key : `${list.length} ${NOUN[type] ?? type}${list.length === 1 ? '' : 's'}`,
  );
  return `Linked: ${prs.size === 2 ? 'both PRs' : `all ${prs.size} PRs`} are named by ${names.join(' and ')}`;
}

const byName = (a, b) => a.localeCompare(b);

// `rank` orders siblings before their title does; it is dropped from the output.
function node(key, title, {url = null, folded = false, rank = 0, caption = null} = {}) {
  return {key, title, caption, url, folded, count: 0, needsYou: 0, children: [], tasks: [], prs: [], rank};
}

function child(parent, key, title, opts) {
  let c = parent.children.find(n => n.key === key);
  if (!c) parent.children.push((c = node(key, title, opts)));
  return c;
}

// Counts are of rows (tasks and lone PRs) under a node, so a folded heading still says how much it holds.
function tally(n, stageOf) {
  for (const c of n.children) tally(c, stageOf);
  n.count = n.tasks.length + n.prs.length + n.children.reduce((s, c) => s + c.count, 0);
  n.needsYou = n.tasks.filter(id => stageOf(id) === 'needs-you').length + n.children.reduce((s, c) => s + c.needsYou, 0);
}

// `tasks` are the open tasks. `queue` holds rows for the lone PRs (bot PRs and team review
// requests): they are not tasks, but this is where the board lists them. `unsubscribed` holds
// the lone PRs you unsubscribed from; a task carries its own `unsubscribed` flag.
export function boardSections({tasks, items, queue = [], unsubscribed = [], projects = [], me = null}) {
  const projectSec = node('projects', 'Projects');
  const teamSec = node('teams', 'Tickets with no project');
  const prSec = node('adhoc', 'PRs with no ticket', {caption: 'By repo, then how the PR involves you, then who opened it. Your PRs include bot PRs made for you.'});
  const otherSec = node('other', 'Other');
  const unsubSec = node('unsubscribed', 'Unsubscribed', {folded: true});

  // Projects you lead or belong to show even with no ticket of yours; a ticket's project shows either way.
  // Keyed by name, since a ticket carries only its project's name.
  const projectKey = p => `project:${p.name}`;
  const known = new Map(projects.map(p => [p.name, p]));
  for (const p of projects) child(projectSec, projectKey(p), p.name, {url: p.url});

  const prNode = place => {
    const repo = child(prSec, `repo:${place.repo}`, place.repo);
    const role = ROLES.findIndex(([r]) => r === place.role);
    let at = child(repo, `${repo.key}:${place.role}`, ROLES[role][1], {folded: FOLDED_ROLES.has(place.role), rank: role});
    if (place.team) at = child(at, `${at.key}:${place.team}`, place.team);
    if (place.role === 'mine' && place.author === 'you') return at;
    // People's PRs lead the bots'.
    const rank = place.author === 'human' ? 0 : 1;
    return child(at, `${at.key}:author:${place.author}`, place.author, {rank});
  };

  const stage = new Map(tasks.map(t => [t.id, t.stage]));
  const rank = id => STAGE_ORDER.indexOf(stage.get(id));
  for (const t of [...tasks].sort((a, b) => rank(a.id) - rank(b.id) || byName(a.id, b.id))) {
    if (t.unsubscribed) {
      unsubSec.tasks.push(t.id);
      continue;
    }
    const place = taskPlace(t, items, me);
    if (place.kind === 'project') {
      const name = place.project;
      child(projectSec, projectKey({name}), name, {url: known.get(name)?.url ?? null}).tasks.push(t.id);
    } else if (place.kind === 'team') child(teamSec, `team:${place.team}`, place.team).tasks.push(t.id);
    else if (place.kind === 'pr') prNode(place).tasks.push(t.id);
    else otherSec.tasks.push(t.id);
  }
  const updated = row => items[row.key]?.updatedAt ?? '';
  const newest = (a, b) => updated(b).localeCompare(updated(a));
  for (const row of [...queue].sort(newest)) prNode(prPlace(items[row.key], me)).prs.push(row);
  unsubSec.prs.push(...[...unsubscribed].sort(newest));

  // The merged heading keeps the role's key, so its fold state stays put; the author levels below keep theirs.
  const oneTeam = repo => {
    for (const role of repo.children) {
      if (role.key !== `${repo.key}:team` || role.children.length !== 1) continue;
      const [team] = role.children;
      Object.assign(role, {title: `${role.title}: ${team.title}`, children: team.children, tasks: team.tasks, prs: team.prs});
    }
  };
  prSec.children.forEach(oneTeam);
  // Names sort alphabetically so a group stays put between syncs.
  const sortTree = n => {
    n.children.sort((a, b) => a.rank - b.rank || byName(a.title, b.title));
    for (const c of n.children) sortTree(c);
    delete n.rank;
  };
  const out = [projectSec, teamSec, prSec, otherSec, unsubSec];
  for (const s of out) {
    sortTree(s);
    tally(s, id => stage.get(id));
  }
  // You chose not to hear about these, so the heading never says they need you.
  unsubSec.needsYou = 0;
  // An empty Projects section still matters when you belong to a project; the others hide when empty.
  return out.filter(s => s.count || s.children.length);
}
