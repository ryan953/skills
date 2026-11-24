// Run: node --test scripts/
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {boardSections, prAuthor, prRole, taskPlace} from './lib/group.mjs';
import {prItem} from './lib/sources.mjs';

const ONBOARDING = 'Onboarding deletes projects, dead-ends, and breaks agent setup';

// Shaped like the ledger's items (2026-11-24).
const ticket = (key, {project = null, team = 'VDY', teamName = 'Value Discovery', open = true, roles = ['assignee', 'creator']} = {}) => ({
  key,
  type: 'linear',
  title: `Ticket ${key}`,
  url: `https://linear.app/getsentry/issue/${key}`,
  open,
  status: open ? 'In Progress' : 'Done',
  roles,
  strong: [],
  weak: [],
  meta: {stateType: open ? 'started' : 'completed', team, teamName, project, parent: null},
});
const pr = (repo, number, {author = 'ryan953', roles = ['author'], isBot, reviewTeams = [], open = true, updatedAt = '2026-11-23T10:00:00Z'} = {}) => ({
  key: `${repo}#${number}`,
  type: 'pr',
  title: `PR ${number}`,
  url: `https://github.com/${repo}/pull/${number}`,
  open,
  status: open ? 'open' : 'merged',
  updatedAt,
  roles,
  strong: [],
  weak: [],
  meta: {repo, number, author, ...(isBot === undefined ? {} : {isBot}), reviewTeams, draft: false, checks: 'SUCCESS'},
});
const session = key => ({key, type: 'claude', title: 'Session', open: true, roles: [], strong: [], weak: [], meta: {active: true, prs: []}});
const jr = key => ({key, type: 'jr', title: 'Dashboard: number of tests', open: true, roles: [], strong: [], weak: [], meta: {active: true}});

const all = [
  ticket('VDY-433', {project: ONBOARDING}),
  ticket('VDY-432', {project: ONBOARDING}),
  ticket('VDY-376'),
  ticket('DE-1791', {team: 'DE', teamName: 'Design Engineering', roles: []}),
  pr('getsentry/sentry', 131651),
  pr('getsentry/sentry', 129579, {author: 'JoshuaKGoldberg', roles: ['reviewed']}),
  pr('getsentry/sentry', 132071, {author: 'joseph-sentry', roles: ['review'], reviewTeams: ['app-frontend']}),
  pr('getsentry/sentry', 131594, {author: 'sentry-junior', roles: ['review'], isBot: true, reviewTeams: ['value-discovery']}),
  pr('getsentry/sentry', 131700, {author: 'scttcper', roles: ['review', 'review-direct']}),
  pr('getsentry/getsentry', 22485),
  pr('bcoe/pokemon-market', 2, {author: 'seer-by-sentry', roles: ['bot'], isBot: true}),
  // Lone PRs in the queue bucket.
  pr('getsentry/sentry', 127684, {author: 'dependabot', roles: ['review'], isBot: true, reviewTeams: ['owners-js-deps'], updatedAt: '2026-11-23T23:34:26Z'}),
  pr('getsentry/sentry', 127680, {author: 'dependabot', roles: ['review'], reviewTeams: ['owners-js-deps'], updatedAt: '2026-11-20T00:00:00Z'}),
  pr('getsentry/sentry', 126704, {author: 'sansynx', roles: ['review'], reviewTeams: ['app-frontend']}),
  session('local_dotfiles'),
  jr('local:web:9892'),
];
const items = Object.fromEntries(all.map(i => [i.key, i]));
const task = (id, keys, stage = 'iterate', owner = null) => ({id, title: id, stage, items: keys, owner, actions: []});
const tasks = [
  task('VDY-433', ['VDY-433', 'getsentry/sentry#131651']),
  task('VDY-432', ['VDY-432'], 'needs-you'),
  task('VDY-376', ['VDY-376'], 'validate'),
  task('DE-1791', ['DE-1791', 'getsentry/sentry#129579'], 'review'),
  task('getsentry/sentry#132071', ['getsentry/sentry#132071'], 'review'),
  task('getsentry/sentry#131594', ['getsentry/sentry#131594', 'local_jrsession'], 'review'),
  task('getsentry/sentry#131700', ['getsentry/sentry#131700'], 'review'),
  task('getsentry/getsentry#22485', ['getsentry/getsentry#22485']),
  task('bcoe/pokemon-market#2', ['bcoe/pokemon-market#2']),
  task('local_dotfiles', ['local_dotfiles'], 'adhoc', 'local_dotfiles'),
  task('local:web:9892', ['local:web:9892'], 'needs-you'),
];
const row = k => ({key: k, label: `#${items[k].meta.number} open`, title: items[k].title, url: items[k].url, detail: null, headAt: null});
const queue = ['getsentry/sentry#127680', 'getsentry/sentry#127684', 'getsentry/sentry#126704'].map(row);
const projects = [
  {id: 'p1', name: ONBOARDING, url: 'https://linear.app/getsentry/project/onboarding'},
  {id: 'p2', name: 'Agent handoff', url: 'https://linear.app/getsentry/project/agent-handoff'},
];

const sections = boardSections({tasks, items, queue, projects, me: 'ryan953'});
const find = (nodes, key) => {
  for (const n of nodes) {
    if (n.key === key) return n;
    const hit = find(n.children, key);
    if (hit) return hit;
  }
  return null;
};
const titles = n => n.children.map(c => c.title);

test('the sections come in order: projects, tickets by team, PRs with no ticket, other', () => {
  assert.deepEqual(sections.map(s => s.title), ['Projects', 'Tickets with no project', 'PRs with no ticket', 'Other']);
});

test('projects you belong to show even with no ticket, and hold your tickets with their PRs inside the task', () => {
  const sec = find(sections, 'projects');
  assert.deepEqual(titles(sec), ['Agent handoff', ONBOARDING]);
  const onboarding = find(sections, `project:${ONBOARDING}`);
  assert.equal(onboarding.url, 'https://linear.app/getsentry/project/onboarding');
  // Most urgent first.
  assert.deepEqual(onboarding.tasks, ['VDY-432', 'VDY-433']);
  assert.equal(onboarding.needsYou, 1);
  assert.equal(find(sections, 'project:Agent handoff').count, 0);
});

test('tickets with no project group by their team', () => {
  assert.deepEqual(titles(find(sections, 'teams')), ['Design Engineering', 'Value Discovery']);
  assert.deepEqual(find(sections, 'team:Value Discovery').tasks, ['VDY-376']);
  // A review PR that names a ticket follows the ticket, not the PR grouping.
  assert.deepEqual(find(sections, 'team:Design Engineering').tasks, ['DE-1791']);
});

test('PRs with no ticket group by repo, then role, then team, then author', () => {
  assert.deepEqual(titles(find(sections, 'adhoc')), ['bcoe/pokemon-market', 'getsentry/getsentry', 'getsentry/sentry']);
  const sentry = find(sections, 'repo:getsentry/sentry');
  assert.deepEqual(titles(sentry), ['Review requested of you', 'Team review']);
  const team = find(sections, 'repo:getsentry/sentry:team');
  assert.deepEqual(titles(team), ['app-frontend', 'owners-js-deps', 'value-discovery']);
  assert.deepEqual(find(sections, 'repo:getsentry/sentry:team:value-discovery:author:jr').tasks, ['getsentry/sentry#131594']);
  assert.deepEqual(find(sections, 'repo:getsentry/sentry:direct:author:human').tasks, ['getsentry/sentry#131700']);
  assert.deepEqual(find(sections, 'repo:bcoe/pokemon-market:mine:author:seer').tasks, ['bcoe/pokemon-market#2']);
  assert.deepEqual(find(sections, 'repo:getsentry/getsentry:mine:author:you').tasks, ['getsentry/getsentry#22485']);
});

test('lone queue PRs are listed under their place, newest first, and team review starts folded', () => {
  const deps = find(sections, 'repo:getsentry/sentry:team:owners-js-deps:author:dependabot');
  assert.deepEqual(deps.prs.map(p => p.key), ['getsentry/sentry#127684', 'getsentry/sentry#127680']);
  const front = find(sections, 'repo:getsentry/sentry:team:app-frontend');
  // People lead bots, and queue rows sit beside tasks.
  assert.deepEqual(titles(front), ['human']);
  assert.deepEqual(front.children[0].tasks, ['getsentry/sentry#132071']);
  assert.deepEqual(front.children[0].prs.map(p => p.key), ['getsentry/sentry#126704']);
  assert.equal(find(sections, 'repo:getsentry/sentry:team').folded, true);
  assert.equal(find(sections, 'repo:getsentry/sentry:team').count, 5);
  assert.equal(find(sections, 'repo:getsentry/sentry:direct').folded, false);
  assert.equal(find(sections, 'adhoc').count, 8);
});

test('a task with no ticket and no PR goes under Other and keeps its needs-you count', () => {
  const other = find(sections, 'other');
  assert.deepEqual(other.tasks, ['local:web:9892', 'local_dotfiles']);
  assert.equal(other.needsYou, 1);
  // No task is lost: every open task sits in exactly one place.
  const placed = [];
  const walk = n => {
    placed.push(...n.tasks);
    n.children.forEach(walk);
  };
  sections.forEach(walk);
  assert.deepEqual(placed.sort(), tasks.map(t => t.id).sort());
});

test('empty sections hide, except projects you belong to', () => {
  const only = boardSections({tasks: [tasks[0]], items, queue: [], projects: [], me: 'ryan953'});
  assert.deepEqual(only.map(s => s.key), ['projects']);
  assert.deepEqual(boardSections({tasks: [], items, projects, me: 'ryan953'}).map(s => s.key), ['projects']);
  assert.deepEqual(boardSections({tasks: [], items, me: 'ryan953'}), []);
});

test('roles and authors read from the PR item', () => {
  assert.equal(prRole(items['getsentry/sentry#131700']), 'direct');
  assert.equal(prRole(items['bcoe/pokemon-market#2']), 'mine');
  assert.equal(prRole(items['getsentry/sentry#129579']), 'reviewed');
  assert.equal(prRole({roles: ['ref']}), 'other');
  // A ledger from before isBot was fetched still knows the common bots by name.
  assert.equal(prAuthor(items['getsentry/sentry#127680'], 'ryan953'), 'dependabot');
  assert.equal(prAuthor({meta: {author: 'renovate', isBot: true}}, 'ryan953'), 'renovate');
  assert.equal(prAuthor({meta: {author: 'cursor', isBot: true}}, 'ryan953'), 'cursor');
  assert.equal(prAuthor(items['getsentry/sentry#132071'], 'ryan953'), 'human');
});

test('the owner and open tickets decide where a task sits', () => {
  const closed = ticket('VDY-1', {project: 'Old', open: false});
  const its = {...items, 'VDY-1': closed};
  assert.deepEqual(taskPlace(task('x', ['VDY-1', 'VDY-433']), its, 'ryan953'), {kind: 'project', project: ONBOARDING});
  assert.deepEqual(taskPlace(task('x', ['VDY-433', 'VDY-376'], 'iterate', 'VDY-376'), its, 'ryan953'), {kind: 'team', team: 'Value Discovery'});
  const old = {'VDY-9': {key: 'VDY-9', type: 'linear', open: true, meta: {team: 'VDY'}}};
  assert.deepEqual(taskPlace(task('VDY-9', ['VDY-9']), old, 'ryan953'), {kind: 'team', team: 'VDY'});
});

test('a PR item keeps its bot flag and only the requested teams you are in', () => {
  const node = {
    number: 131983,
    title: 'feat(onboarding): Copy',
    url: 'https://github.com/getsentry/sentry/pull/131983',
    state: 'OPEN',
    isDraft: false,
    updatedAt: '2026-11-24T00:00:00Z',
    headRefName: 'nico/copy',
    body: '',
    author: {login: 'NicoHinderling', __typename: 'User'},
    repository: {nameWithOwner: 'getsentry/sentry', isArchived: false},
    reviewRequests: {nodes: [{requestedReviewer: {__typename: 'Team', combinedSlug: 'getsentry/agent-interfaces-sentry-frontend'}}, {requestedReviewer: {__typename: 'Team', combinedSlug: 'getsentry/app-frontend'}}]},
    reviewDecision: 'REVIEW_REQUIRED',
    commits: {nodes: []},
    files: {nodes: []},
  };
  const mine = new Set(['getsentry/app-frontend', 'getsentry/value-discovery']);
  const item = prItem(node, 'ryan953', ['review'], new Set(['VDY']), mine);
  assert.equal(item.meta.isBot, false);
  assert.deepEqual(item.meta.reviewTeams, ['app-frontend']);
  // With no team list, every requested team counts.
  assert.deepEqual(prItem(node, 'ryan953', ['review'], new Set(['VDY'])).meta.reviewTeams, ['agent-interfaces-sentry-frontend', 'app-frontend']);
  const bot = prItem({...node, author: {login: 'dependabot', __typename: 'Bot'}}, 'ryan953', ['review'], new Set(['VDY']), mine);
  assert.equal(bot.meta.isBot, true);
});
