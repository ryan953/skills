// Run: node --test scripts/
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {taskGroup} from './lib/group.mjs';

const ticket = (key, project, open = true) => ({key, type: 'linear', open, meta: {team: 'VDY', teamName: 'Value Discovery', project}});
const pr = (repo, number, open = true) => ({key: `${repo}#${number}`, type: 'pr', open, meta: {repo, number}});
const session = {key: 'cc-1', type: 'claude', open: true, meta: {}};
const items = Object.fromEntries(
  [ticket('VDY-1', 'Onboarding'), ticket('VDY-2', null), ticket('VDY-3', 'Old', false), pr('getsentry/sentry', 1), pr('ryan953/skills', 2), session].map(i => [i.key, i])
);

test('a task with a ticket sits under its team and project, PRs included', () => {
  assert.deepEqual(taskGroup({items: ['getsentry/sentry#1', 'VDY-1'], owner: null}, items), {kind: 'team', team: 'Value Discovery', project: 'Onboarding'});
  assert.deepEqual(taskGroup({items: ['VDY-2'], owner: null}, items), {kind: 'team', team: 'Value Discovery', project: null});
});

test('the owner and open tickets decide before closed ones', () => {
  assert.equal(taskGroup({items: ['VDY-3', 'VDY-1'], owner: null}, items).project, 'Onboarding');
  assert.equal(taskGroup({items: ['VDY-1', 'VDY-2'], owner: 'VDY-2'}, items).project, null);
});

test('a task with no ticket sits under its PR repo, or under other', () => {
  assert.deepEqual(taskGroup({items: ['ryan953/skills#2', 'cc-1'], owner: 'cc-1'}, items), {kind: 'repo', repo: 'ryan953/skills'});
  assert.deepEqual(taskGroup({items: ['cc-1'], owner: 'cc-1'}, items), {kind: 'other'});
});

test('an old ledger with only the team key still groups', () => {
  const old = {'VDY-9': {key: 'VDY-9', type: 'linear', open: true, meta: {team: 'VDY'}}};
  assert.deepEqual(taskGroup({items: ['VDY-9'], owner: null}, old), {kind: 'team', team: 'VDY', project: null});
});
