// Run: node --test scripts/
// The --board output is what the mod draws, so it is checked through the CLI on a cached fetch.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';

const CLI = join(dirname(fileURLToPath(import.meta.url)), 'taskboard.mjs');

const pr = (number, {roles = ['author'], author = 'ryan953', strong = [], unsubscribed = false, checks = 'SUCCESS', needsReason = null} = {}) => ({
  key: `getsentry/sentry#${number}`,
  type: 'pr',
  title: `PR ${number}`,
  url: `https://github.com/getsentry/sentry/pull/${number}`,
  open: true,
  status: 'open',
  needsYou: Boolean(needsReason),
  needsReason,
  updatedAt: '2026-11-24T10:00:00Z',
  roles,
  strong,
  weak: [],
  meta: {repo: 'getsentry/sentry', number, author, isBot: false, reviewTeams: ['value-discovery'], draft: false, review: null, checks, unsubscribed},
});
const ticket = key => ({key, type: 'linear', title: key, url: `https://linear.app/x/${key}`, open: true, status: 'In Progress', needsYou: false, updatedAt: '2026-11-24T10:00:00Z', roles: ['assignee'], strong: [], weak: [], meta: {stateType: 'started', team: 'VDY', teamName: 'Value Discovery', project: null, parent: null}});

function board(items) {
  const dir = mkdtempSync(join(tmpdir(), 'taskboard-board-'));
  mkdirSync(join(dir, 'sources'));
  writeFileSync(join(dir, 'sources', 'fetched.json'), JSON.stringify({me: 'ryan953', teams: ['VDY'], items, trees: {}, projects: [], fetchedAt: '2026-11-24T12:00:00Z'}));
  return JSON.parse(execFileSync('node', [CLI, 'sync', '--offline', '--board'], {env: {...process.env, TASKBOARD_DIR: dir}, encoding: 'utf8'}));
}

test('counts leave unsubscribed PRs out, and the Unsubscribed section holds them', () => {
  const b = board([
    // Your PR with failing CI, unsubscribed: it would need you.
    pr(131000, {checks: 'FAILURE', needsReason: 'CI failing', unsubscribed: true}),
    pr(130433, {roles: ['review'], author: 'sentry-junior', unsubscribed: true}),
    pr(131412, {roles: ['review'], author: 'Ultroncn'}),
    // Unsubscribed, but its ticket keeps it in view and in the counts.
    pr(131651, {strong: ['VDY-433'], checks: 'FAILURE', needsReason: 'CI failing', unsubscribed: true}),
    ticket('VDY-433'),
  ]);
  assert.deepEqual(b.counts, {open: 1, needsYou: 1, followUp: 0, check: 0, archive: 0, close: 0, nudge: 0, queue: 1, backlog: 0, unsubscribed: 2});
  const sec = b.sections.at(-1);
  assert.equal(sec.key, 'unsubscribed');
  assert.deepEqual(sec.tasks, ['getsentry/sentry#131000']);
  assert.deepEqual(sec.prs.map(p => p.key), ['getsentry/sentry#130433']);
  assert.equal(sec.needsYou, 0);
  assert.equal(b.tasks.find(t => t.id === 'getsentry/sentry#131000').unsubscribed, true);
  assert.equal(b.tasks.find(t => t.id === 'VDY-433').unsubscribed, false);
});
