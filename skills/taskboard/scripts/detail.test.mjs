// Run: node --test scripts/
import assert from 'node:assert/strict';
import {test} from 'node:test';

import {prDetailText} from './lib/format.mjs';
import {prDetail} from './lib/sources.mjs';

const thread = (login, isResolved = false) => ({isResolved, comments: {nodes: [{author: {login}}]}});
const node = ({threads = [], runs = [], counts = [], pending = []} = {}) => ({
  additions: 120,
  deletions: 30,
  changedFiles: 4,
  reviewThreads: {nodes: threads},
  reviews: {nodes: pending},
  commits: {nodes: [{commit: {statusCheckRollup: {contexts: {checkRunCountsByState: counts, statusContextCountsByState: [], nodes: runs}}}}]},
});

test('check counts group the GraphQL states into passed, failed and pending', () => {
  const d = prDetail(node({counts: [{state: 'SUCCESS', count: 40}, {state: 'NEUTRAL', count: 5}, {state: 'SKIPPED', count: 20}, {state: 'FAILURE', count: 1}, {state: 'IN_PROGRESS', count: 3}]}), 'me');
  assert.deepEqual(d.checks, {passed: 45, failed: 1, pending: 3});
});

test('warden is the agent review; cursor, Seer and CodeQL are minor bot notes', () => {
  const d = prDetail(
    node({
      threads: [thread('sentry-warden'), thread('sentry-warden', true), thread('cursor[bot]'), thread('sentry'), thread('github-advanced-security', true), thread('a-human')],
      runs: [{name: 'warden', conclusion: 'SUCCESS'}, {name: 'warden: code-review', conclusion: 'NEUTRAL'}, {name: 'lint', conclusion: 'SUCCESS'}],
    }),
    'me'
  );
  assert.deepEqual(d.warden, {running: false, open: 1, found: 2});
  assert.equal(d.minorBots, 2);
  assert.equal(d.unresolved, 4);
});

test('warden with no findings is "no problems"; a run with no conclusion is running', () => {
  const clean = prDetail(node({runs: [{name: 'warden', conclusion: 'SUCCESS'}]}), 'me');
  assert.match(prDetailText(clean), /warden: no problems/);
  const running = prDetail(node({runs: [{name: 'warden', conclusion: null}]}), 'me');
  assert.match(prDetailText(running), /warden running/);
  assert.equal(prDetail(node(), 'me').warden, null);
});

test('only your own pending review counts as your draft', () => {
  const d = prDetail(node({pending: [{author: {login: 'me'}, comments: {totalCount: 3}}, {author: {login: 'other'}, comments: {totalCount: 9}}]}), 'me');
  assert.equal(d.draftComments, 3);
  assert.equal(prDetailText(d), '+120 −30 · 4 files · your draft review: 3');
});
