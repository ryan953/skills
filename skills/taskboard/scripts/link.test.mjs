// Run: node --test scripts/
// Cases come from the 2026-11-23 inventory, where each one was checked by hand.
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {link} from './lib/link.mjs';
import {closingRefs, linearRefs, orderedRefs, prRefs} from './lib/refs.mjs';
import {normalizeJr} from './lib/sources.mjs';

const TEAMS = new Set(['VDY']);

function pr(num, {status = 'draft', roles = ['author'], linear = [], author = 'ryan953', ...meta} = {}) {
  return {
    key: `getsentry/sentry#${num}`,
    type: 'pr',
    title: `PR ${num}`,
    open: status === 'open' || status === 'draft',
    status,
    needsYou: false,
    roles,
    strong: linear,
    weak: [],
    meta: {repo: 'getsentry/sentry', number: num, author, draft: status === 'draft', ...meta},
  };
}
function issue(id, {open = true, stateType = 'started', prs = []} = {}) {
  return {key: id, type: 'linear', title: id, open, status: open ? 'In Progress' : 'Done', needsYou: false, roles: ['assignee'], strong: prs, weak: [], meta: {stateType}};
}
function session(id, title, {prs = [], linear = [], weak = [], updatedAt = '2026-11-18T00:00:00Z', ...meta} = {}) {
  return {key: id, type: 'claude', title, open: true, status: 'open', needsYou: false, updatedAt, roles: [], strong: [...linear, ...prs], weak, meta: {active: true, ...meta}};
}
const jr = c => normalizeJr([{status: 'done', treeState: 'done', lastSeenAt: '2026-11-23T00:00:00Z', ...c}], TEAMS)[0];

test('refs: branch names, qualified refs, and short bare numbers', () => {
  assert.deepEqual(linearRefs('ryan953/vdy-426-onboarding-back-nav', TEAMS), ['VDY-426']);
  assert.deepEqual(linearRefs('UTF-8 and SHA-256', TEAMS), []);
  assert.deepEqual(prRefs('Fix #132081 and getsentry/sentry-options-automator#10759'), [
    'getsentry/sentry-options-automator#10759',
    'getsentry/sentry#132081',
  ]);
  // "PR #3968" lives in security-as-code, so a short bare number must not guess getsentry/sentry.
  assert.deepEqual(prRefs('PR #3968 removes the listed memberships'), []);
  assert.deepEqual(prRefs('https://github.com/getsentry/sentry/pull/131666'), ['getsentry/sentry#131666']);
});

test('one PR that fixes four tickets becomes one task, with both jr conversations', () => {
  const items = [
    pr(131666, {linear: ['VDY-426', 'VDY-377', 'VDY-427', 'VDY-437']}),
    ...['VDY-377', 'VDY-426', 'VDY-427', 'VDY-437'].map(id => issue(id, {prs: ['getsentry/sentry#131666']})),
    jr({conversationId: 'jr-sync', title: 'Sync #131666: Keep Created Project When Going Back', summary: ''}),
    jr({conversationId: 'jr-426', title: 'VDY-426 | https://github.com/getsentry/sentry/pull/131666', summary: ''}),
  ];
  const {tasks} = link(items);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].id, 'VDY-377');
  assert.equal(tasks[0].stage, 'iterate');
  assert.equal(tasks[0].items.length, 7);
});

test('a PR named only in a jr summary does not pull in unknown work', () => {
  const items = [
    issue('VDY-400', {stateType: 'triage'}),
    jr({
      conversationId: 'jr-400',
      title: 'Validate Browser-Back Project Delete Fix',
      summary: 'VDY-400 is still unfixed. PR #131484 changed a different blocker.',
    }),
  ];
  const {tasks} = link(items);
  assert.equal(tasks.length, 1);
  assert.deepEqual(tasks[0].items, ['VDY-400', 'jr-400']);
  assert.equal(tasks[0].stage, 'validate');
});

test('ticket still open after its PR merged: close the ticket', () => {
  const items = [issue('VDY-417', {prs: ['getsentry/sentry#131673']}), pr(131673, {status: 'merged', roles: ['ref']})];
  const {tasks} = link(items);
  assert.equal(tasks[0].stage, 'verify');
  assert.deepEqual(tasks[0].actions.map(a => a.type), ['close-linear']);
});

test('sessions for a finished ticket are asked before archive, unless one is still running', () => {
  const items = [
    issue('VDY-381', {open: false}),
    session('cc-1', 'Work on VDY-381', {linear: ['VDY-381']}),
    session('cc-2', 'Work on VDY-381', {linear: ['VDY-381']}),
    session('cc-run', 'Work on VDY-381', {linear: ['VDY-381'], running: true}),
  ];
  const {tasks} = link(items);
  assert.equal(tasks[0].stage, 'done');
  assert.deepEqual(tasks[0].actions.map(a => [a.type, a.item]).sort(), [['check', 'cc-1'], ['check', 'cc-2']]);
});

test('older duplicate sessions on an open task are asked about, the newest stays', () => {
  const items = [
    issue('VDY-423', {prs: ['getsentry/sentry#132081']}),
    pr(132081, {status: 'open'}),
    session('cc-old', 'Work on VDY-423', {linear: ['VDY-423'], updatedAt: '2026-11-18T00:00:00Z'}),
    session('cc-new', 'VDY-423 Agent progress polls forever', {prs: ['getsentry/sentry#132081'], updatedAt: '2026-11-20T00:00:00Z'}),
  ];
  const {tasks} = link(items);
  assert.deepEqual(tasks[0].actions, [{type: 'check', item: 'cc-old', reason: 'duplicate of cc-new'}]);
});

test('team review requests stay in the queue unless something links them', () => {
  const items = [
    pr(131726, {status: 'open', roles: ['review'], author: 'dependabot'}),
    pr(132216, {status: 'open', roles: ['review'], author: 'cvxluo'}),
    pr(132109, {status: 'open', roles: ['review'], author: 'Harbeytee'}),
    jr({conversationId: 'jr-review', title: 'Review #132109: Keep Framework Prompt Usable on Mobile', summary: ''}),
  ];
  const {tasks, queue} = link(items);
  assert.deepEqual(queue, ['getsentry/sentry#131726', 'getsentry/sentry#132216']);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].kind, 'review');
  assert.equal(tasks[0].stage, 'review');
});

test('jr needs_input puts the task at the top and asks for you', () => {
  const items = [
    pr(131654, {linear: ['VDY-432']}),
    issue('VDY-432', {prs: ['getsentry/sentry#131654']}),
    jr({conversationId: 'jr-432', title: 'Require Received Test Error', summary: 'Iterated on draft PR #131654', status: 'needs_input', treeState: 'needs_you'}),
  ];
  const {tasks} = link(items);
  assert.equal(tasks[0].stage, 'needs-you');
  assert.deepEqual(tasks[0].actions, [{type: 'needs-you', item: 'jr-432', reason: 'jr needs input'}]);
});

test('ids, owners and notes stay stable across syncs and merges', () => {
  const first = link([issue('VDY-445'), pr(132259, {linear: ['VDY-445'], roles: ['bot'], author: 'sentry-junior'})]);
  first.tasks[0].owner = 'cc-445';
  first.tasks[0].notes = 'reuse cc-445';
  const second = link(
    [issue('VDY-445'), pr(132259, {linear: ['VDY-445'], roles: ['bot'], author: 'sentry-junior'}), session('cc-445', 'chips', {prs: ['getsentry/sentry#132259']})],
    {previous: {tasks: first.tasks, itemTask: first.itemTask, items: {}}}
  );
  assert.equal(second.tasks[0].id, 'VDY-445');
  assert.equal(second.tasks[0].owner, 'cc-445');
  assert.equal(second.tasks[0].notes, 'reuse cc-445');
});

test('overrides: split an item out, join two items', () => {
  const items = [issue('VDY-1', {prs: ['getsentry/sentry#100001']}), pr(100001, {linear: ['VDY-1']}), session('cc-x', 'Notes')];
  assert.equal(link(items, {overrides: {split: ['getsentry/sentry#100001']}}).tasks.length, 3);
  assert.equal(link(items, {overrides: {join: [['VDY-1', 'cc-x']]}}).tasks.length, 1);
});

test('refs: only closing lines of a PR body count, in reading order elsewhere', () => {
  const body = 'This closes the onboarding half of VDY-377. VDY-380 needs a follow-up.\n\nFixes VDY-426\n- Closes https://linear.app/getsentry/issue/VDY-427/x';
  assert.deepEqual(closingRefs(body, TEAMS), ['VDY-426', 'VDY-427']);
  assert.deepEqual(orderedRefs('Validated VDY-418. Confirmed VDY-445 is related. Draft PR getsentry/sentry#132261.', TEAMS), [
    'VDY-418',
    'VDY-445',
    'getsentry/sentry#132261',
  ]);
});

test('a summary links only through its first tracked ref', () => {
  const items = [
    issue('VDY-418', {stateType: 'triage', prs: ['getsentry/sentry#132261']}),
    pr(132261, {linear: ['VDY-418'], roles: ['bot'], author: 'sentry-junior'}),
    issue('VDY-445', {prs: ['getsentry/sentry#132259']}),
    pr(132259, {linear: ['VDY-445'], roles: ['bot'], author: 'sentry-junior'}),
    jr({conversationId: 'jr-418', title: 'Validate Disabled Product Chips', summary: 'Validated VDY-418. Confirmed VDY-445 is related but distinct. Draft PR getsentry/sentry#132261 is open.'}),
  ];
  const {tasks} = link(items);
  assert.equal(tasks.length, 2);
  assert.deepEqual(tasks.find(t => t.id === 'VDY-418').items, ['VDY-418', 'getsentry/sentry#132261', 'jr-418']);
});

test('tickets you filed that nothing links go to the backlog', () => {
  const filed = {...issue('VDY-384', {stateType: 'triage'}), roles: ['creator']};
  const {tasks, backlog} = link([filed]);
  assert.equal(tasks.length, 0);
  assert.deepEqual(backlog, ['VDY-384']);
});

test('an old question in a session about finished work does not ask for you', () => {
  const asking = {...session('cc-412', 'VDY-412 React init snippet', {linear: ['VDY-412']}), needsYou: true, needsReason: 'screenshots?'};
  const {tasks} = link([issue('VDY-412', {open: false}), asking]);
  assert.equal(tasks[0].stage, 'done');
  assert.deepEqual(tasks[0].actions, [{type: 'check', item: 'cc-412', reason: 'task is done'}]);
});

test('a team review request in a watched path is a review task; a bot PR stays in the queue', () => {
  const watched = pr => ({...pr, meta: {...pr.meta, watched: true}});
  const items = [
    watched(pr(132140, {status: 'open', roles: ['review'], author: 'scttcper'})),
    watched(pr(131726, {status: 'open', roles: ['review'], author: 'dependabot'})),
    pr(132216, {status: 'open', roles: ['review'], author: 'cvxluo'}),
  ];
  const {tasks, queue} = link(items);
  assert.deepEqual(queue, ['getsentry/sentry#131726', 'getsentry/sentry#132216']);
  assert.deepEqual(tasks.map(t => [t.id, t.kind, t.stage]), [['getsentry/sentry#132140', 'review', 'review']]);
});

test('the answer decides: nothing left is archived, remaining work is a follow-up, new activity asks again', () => {
  const items = [issue('VDY-381', {open: false}), session('cc-1', 'VDY-381 a', {linear: ['VDY-381']}), session('cc-2', 'VDY-381 b', {linear: ['VDY-381']})];
  const at = '2026-11-19T00:00:00Z';
  const answered = link(items, {checks: {'cc-1': {at, remaining: null}, 'cc-2': {at, remaining: 'file a ticket for the Safari bug'}}});
  assert.equal(answered.tasks[0].stage, 'follow-up');
  assert.deepEqual(answered.tasks[0].actions, [
    {type: 'archive', item: 'cc-1', reason: 'it said nothing is left'},
    {type: 'follow-up', item: 'cc-2', reason: 'file a ticket for the Safari bug'},
  ]);
  const stale = link(items, {checks: {'cc-1': {at: '2026-11-17T00:00:00Z', remaining: null}}});
  assert.equal(stale.tasks[0].stage, 'done');
  assert.deepEqual(stale.tasks[0].actions.map(a => a.type), ['check', 'check']);
});

test('a session with another open PR is left alone when one of its tasks is done', () => {
  const items = [
    issue('VDY-381', {open: false}),
    pr(131999, {status: 'open'}),
    {...session('cc-1', 'VDY-381 and more', {linear: ['VDY-381']}), meta: {active: true, prs: ['getsentry/sentry#131999']}},
  ];
  const task = link(items).tasks.find(t => t.id === 'VDY-381');
  assert.deepEqual(task.actions, []);
});

test('a PR with no ticket that you unsubscribed from is out of sight; a ticket keeps its PRs', () => {
  const items = [
    // A lone team review request, out of the queue.
    pr(130433, {status: 'open', roles: ['review'], author: 'sentry-junior', unsubscribed: true}),
    // Never subscribed: still in the queue.
    pr(131412, {status: 'open', roles: ['review'], author: 'Ultroncn', unsubscribed: false}),
    // Your own PR with no ticket: a task, marked.
    pr(131000, {status: 'open', unsubscribed: true}),
    // Under a ticket: it stays with the ticket.
    pr(131651, {status: 'open', linear: ['VDY-433'], unsubscribed: true}),
    issue('VDY-433'),
  ];
  const {tasks, queue, unsubscribed} = link(items);
  assert.deepEqual(unsubscribed, ['getsentry/sentry#130433']);
  assert.deepEqual(queue, ['getsentry/sentry#131412']);
  const byId = Object.fromEntries(tasks.map(t => [t.id, t]));
  assert.equal(byId['getsentry/sentry#131000'].unsubscribed, true);
  assert.equal(byId['VDY-433'].unsubscribed, false);
  assert.deepEqual(byId['VDY-433'].items, ['VDY-433', 'getsentry/sentry#131651']);
});

test('a task with no ticket stays in view while any of its open PRs is subscribed', () => {
  const items = [
    pr(131000, {status: 'open', unsubscribed: true}),
    pr(131001, {status: 'open', unsubscribed: false}),
    session('cc-1', 'Fix #131000 and #131001', {prs: ['getsentry/sentry#131000', 'getsentry/sentry#131001']}),
  ];
  const {tasks} = link(items);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].unsubscribed, false);
});
