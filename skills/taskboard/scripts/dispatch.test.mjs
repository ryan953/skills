// Run: node --test scripts/
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {dispatch} from './lib/dispatch.mjs';
import {link} from './lib/link.mjs';

function pr(num, {status = 'draft', roles = ['author'], linear = []} = {}) {
  return {
    key: `getsentry/sentry#${num}`,
    type: 'pr',
    title: `PR ${num}`,
    url: `https://github.com/getsentry/sentry/pull/${num}`,
    open: status === 'open' || status === 'draft',
    status,
    needsYou: false,
    roles,
    strong: linear,
    weak: [],
    meta: {repo: 'getsentry/sentry', number: num, author: 'ryan953', draft: status === 'draft'},
  };
}
function issue(id, {stateType = 'started', prs = []} = {}) {
  return {key: id, type: 'linear', title: `Ticket ${id}`, open: true, status: 'In Progress', needsYou: false, roles: ['assignee'], strong: prs, weak: [], meta: {stateType}};
}
function session(id, title, {strong = [], updatedAt = '2026-11-20T00:00:00Z'} = {}) {
  return {key: id, type: 'claude', title, open: true, status: 'open', needsYou: false, updatedAt, roles: [], strong, weak: [], meta: {active: true}};
}
function jr(id, title, {strong = [], active = true} = {}) {
  return {key: id, type: 'jr', title, open: true, status: active ? 'active' : 'done', needsYou: false, updatedAt: '2026-11-21T00:00:00Z', roles: [], strong, weak: [], meta: {active}};
}

function only(items, opts) {
  const {tasks} = link(items);
  assert.equal(tasks.length, 1);
  const byKey = new Map(items.map(i => [i.key, i]));
  return dispatch(tasks[0], tasks[0].items.map(k => byKey.get(k)), opts);
}

test('a task with a live session sends the next step to that session', () => {
  const out = only([
    issue('VDY-423', {prs: ['getsentry/sentry#132081']}),
    pr(132081),
    session('cc-old', 'VDY-423 first try', {strong: ['VDY-423'], updatedAt: '2026-11-18T00:00:00Z'}),
    session('cc-new', 'VDY-423 polling', {strong: ['VDY-423']}),
    jr('jr-423', 'VDY-423', {strong: ['VDY-423']}),
  ]);
  assert.equal(out.route, 'session');
  assert.equal(out.target.key, 'cc-new');
  assert.match(out.message, /^Iterate on #132081/);
  assert.match(out.message, /Do not merge/);
});

test('with no session, the step goes to the active jr conversation', () => {
  const out = only([issue('VDY-400', {stateType: 'triage'}), jr('jr-400', 'Validate VDY-400', {strong: ['VDY-400']})]);
  assert.equal(out.route, 'jr');
  assert.equal(out.target.key, 'jr-400');
  assert.match(out.message, /^Validate VDY-400/);
});

test('with nothing to reuse, a new session gets a full brief titled with the task id', () => {
  const out = only([issue('VDY-433', {prs: ['getsentry/sentry#131651']}), pr(131651, {linear: ['VDY-433']})]);
  assert.equal(out.route, 'new');
  assert.equal(out.brief, 'full');
  assert.match(out.title, /^VDY-433: /);
  assert.ok(out.title.length < 60);
  assert.match(out.background, /full cycle/);
  assert.match(out.background, /PR #131651 \(draft\)/);
  assert.equal(out.repo, 'getsentry/sentry');
});

test('a review task gets a review brief that forbids code changes', () => {
  const out = only([pr(132109, {status: 'open', roles: ['review']}), jr('jr-r', 'Review #132109', {strong: ['getsentry/sentry#132109'], active: false})], {route: 'new'});
  assert.equal(out.brief, 'review');
  assert.match(out.title, /^Review #132109: /);
  assert.match(out.prompt, /deep-pr-review/);
  assert.match(out.background, /Do not change the code/);
});

test('validate-only stops after validation', () => {
  const out = only([issue('VDY-456', {stateType: 'triage'})], {brief: 'validate'});
  assert.equal(out.route, 'new');
  assert.match(out.prompt, /Then stop\./);
});

test('merge, needs-you and adhoc tasks go back to the user', () => {
  const ready = {...pr(131700, {status: 'open'}), meta: {repo: 'getsentry/sentry', number: 131700, author: 'ryan953', draft: false, review: 'APPROVED', checks: 'SUCCESS'}};
  assert.equal(only([ready]).route, 'user');
  assert.equal(only([session('cc-x', 'Notes')]).route, 'user');
  assert.equal(only([session('cc-x', 'Notes')], {step: 'Summarize'}).route, 'session');
});

test('the owner is reused first and stays in its task after a sync', () => {
  const items = [issue('VDY-445'), session('cc-a', 'VDY-445 a', {strong: ['VDY-445'], updatedAt: '2026-11-22T00:00:00Z'})];
  const first = link(items);
  first.tasks[0].owner = 'cc-worker';
  // The worker's title names nothing, so only the owner field ties it to VDY-445.
  const second = link([...items, session('cc-worker', 'Untitled', {updatedAt: '2026-11-19T00:00:00Z'})], {previous: {tasks: first.tasks, itemTask: first.itemTask}});
  assert.equal(second.tasks.length, 1);
  assert.deepEqual(second.tasks[0].actions, [{type: 'archive', item: 'cc-a', reason: 'duplicate of cc-worker'}]);
  const byKey = new Map([...items, session('cc-worker', 'Untitled')].map(i => [i.key, i]));
  const out = dispatch(second.tasks[0], second.tasks[0].items.map(k => byKey.get(k)));
  assert.equal(out.target.key, 'cc-worker');
});
