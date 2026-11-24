// Run: node --test scripts/
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {dispatch} from './lib/dispatch.mjs';
import {subIssueTask, taskTree} from './lib/tree.mjs';

const child = (id, stateType, prs = []) => ({id, title: `T ${id}`, url: `https://linear.app/x/${id}`, state: stateType, stateType, prs});
const linear = (key, parent = null) => ({key, type: 'linear', title: key, open: true, meta: {stateType: 'started', parent}});

const siblings = Array.from({length: 14}, (_, n) => child(`VDY-${500 + n}`, 'triage'));
const trees = {
  'VDY-376': {id: 'VDY-376', title: 'Parent', url: 'https://linear.app/x/VDY-376', children: [child('VDY-423', 'started'), child('VDY-1', 'completed'), child('VDY-2', 'canceled'), ...siblings]},
  'VDY-423': {id: 'VDY-423', title: 'Self', url: '', children: [child('VDY-10', 'completed'), child('VDY-11', 'started', ['getsentry/sentry#132081']), child('VDY-12', 'triage')]},
};
const ledger = {items: {'VDY-423': linear('VDY-423', 'VDY-376')}, trees, itemTask: {'VDY-423': 'VDY-423'}};

test('the tree has the parent with progress, open sub-issues and capped open siblings', () => {
  const tr = taskTree({id: 'VDY-423', items: ['VDY-423']}, ledger);
  // Canceled children count toward neither side.
  assert.deepEqual(tr.parent.progress, {done: 1, total: 16});
  assert.deepEqual(tr.progress, {done: 1, total: 3});
  assert.deepEqual(tr.children.map(c => [c.id, c.canDispatch]), [['VDY-11', false], ['VDY-12', true]]);
  assert.equal(tr.siblings.length, 10);
  assert.equal(tr.moreSiblings, 4);
  assert.ok(!tr.siblings.some(c => c.id === 'VDY-423'));
});

test('a task with no Linear ticket, or a lone ticket, has no tree', () => {
  assert.equal(taskTree({id: 'getsentry/sentry#1', items: []}, ledger), null);
  assert.equal(taskTree({id: 'VDY-9', items: ['VDY-9']}, {...ledger, items: {'VDY-9': linear('VDY-9')}}), null);
});

test('an untracked sub-issue dispatches to a new session that starts with validation', () => {
  const sub = subIssueTask('VDY-12', trees);
  assert.equal(sub.task.stage, 'validate');
  const out = dispatch(sub.task, sub.members);
  assert.equal(out.route, 'new');
  assert.match(out.title, /^VDY-12: /);
  assert.match(out.prompt, /^Task VDY-12/);
  assert.equal(subIssueTask('VDY-404', trees), null);
});
