const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const {DatabaseSync} = require('node:sqlite');
const M = require('./machine.js');

const schema = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');

function db() {
  const d = new DatabaseSync(':memory:');
  d.exec(schema);
  return d;
}
const one = (d, sql, ...args) => d.prepare(sql).get(...args);
const run = (d, sql, ...args) => d.prepare(sql).run(...args);
const task = (d, title, parent = null) => Number(run(d, 'INSERT INTO tasks (title, parent_id) VALUES (?, ?)', title, parent).lastInsertRowid);
const setStatus = (d, id, s) => run(d, 'UPDATE tasks SET status = ? WHERE id = ?', s, id);
const status = (d, id) => one(d, 'SELECT status FROM tasks WHERE id = ?', id).status;
let n = 0;
const pr = (d, {kind = 'mine', origin = 'task', taskId = null} = {}) =>
  Number(run(d, 'INSERT INTO prs (repo, number, title, kind, origin, task_id) VALUES (?, ?, ?, ?, ?, ?)', 'acme/app', ++n, 'PR', kind, origin, taskId).lastInsertRowid);
const prStatus = (d, id) => one(d, 'SELECT status FROM pr_state WHERE id = ?', id).status;
const comment = (d, prId) => Number(run(d, 'INSERT INTO pr_comments (pr_id, external_id) VALUES (?, ?)', prId, `t${++n}`).lastInsertRowid);

test('task_transitions matches machine.js', () => {
  const d = db();
  const rows = d.prepare('SELECT event, from_status, to_status, actor FROM task_transitions').all()
    .map(r => `${r.event}:${r.from_status}:${r.to_status}:${r.actor}`).sort();
  const expected = [
    ...M.transitions.map(t => `${t.event}:${t.from}:${t.to}:${t.actor}`),
    ...M.actions.flatMap(a => a.states.map(s => `${a.event}:${s}:${s}:${a.actor}`)),
  ].sort();
  assert.deepEqual(rows, expected);
});

test('tasks start in todo and follow allowed transitions only', () => {
  const d = db();
  assert.throws(() => run(d, "INSERT INTO tasks (title, status) VALUES ('x', 'done')"), /start in todo/);
  const t = task(d, 'Write docs');
  assert.throws(() => setStatus(d, t, 'in_review'), /not allowed/);
  setStatus(d, t, 'in_progress');
  assert.equal(status(d, t), 'in_progress');
});

test('being a parent is derived, and subtasks start in todo', () => {
  const d = db();
  const parent = task(d, 'Offsite');
  setStatus(d, parent, 'in_progress');
  const child = task(d, 'Pick dates', parent);
  assert.equal(status(d, child), 'todo');
  assert.equal(status(d, parent), 'in_progress');
  const s = one(d, 'SELECT is_parent, incomplete_subtasks FROM task_state WHERE id = ?', parent);
  assert.deepEqual({...s}, {is_parent: 1, incomplete_subtasks: 1});
});

test('a done task cannot be decomposed', () => {
  const d = db();
  const t = task(d, 'x');
  setStatus(d, t, 'in_progress');
  setStatus(d, t, 'done');
  assert.throws(() => task(d, 'late', t), /cannot be decomposed/);
});

test('done waits for subtasks', () => {
  const d = db();
  const parent = task(d, 'Offsite');
  setStatus(d, parent, 'in_progress');
  const child = task(d, 'Pick dates', parent);
  assert.throws(() => setStatus(d, parent, 'done'), /incomplete subtasks/);
  setStatus(d, child, 'in_progress');
  setStatus(d, child, 'done');
  setStatus(d, parent, 'done');
  assert.equal(status(d, parent), 'done');
});

test('PR status is derived from facts in priority order', () => {
  const d = db();
  const p = pr(d, {origin: 'detected'});
  assert.equal(prStatus(d, p), 'awaiting_review');
  const c = comment(d, p);
  assert.equal(prStatus(d, p), 'has_feedback');
  run(d, "UPDATE prs SET ci = 'failed' WHERE id = ?", p);
  assert.equal(prStatus(d, p), 'ci_failed');
  run(d, "UPDATE prs SET ci = 'pending', head_sha = 'abc' WHERE id = ?", p); // new commits
  run(d, "UPDATE pr_comments SET resolved_at = 'now' WHERE id = ?", c);      // reply
  run(d, 'UPDATE prs SET accepted = 1 WHERE id = ?', p);
  assert.equal(prStatus(d, p), 'accepted');
  run(d, "UPDATE prs SET ci = 'failed' WHERE id = ?", p);
  assert.equal(prStatus(d, p), 'ci_failed');
});

test('CI results only arrive while a run is pending', () => {
  const d = db();
  const p = pr(d, {origin: 'detected'});
  run(d, "UPDATE prs SET ci = 'failed' WHERE id = ?", p);
  assert.throws(() => run(d, "UPDATE prs SET ci = 'passed' WHERE id = ?", p), /pending/);
});

test('only an accepted PR can merge, and merged is final', () => {
  const d = db();
  const p = pr(d, {origin: 'detected'});
  assert.throws(() => run(d, "UPDATE prs SET merged_at = 'now' WHERE id = ?", p), /accepted/);
  run(d, 'UPDATE prs SET accepted = 1 WHERE id = ?', p);
  run(d, "UPDATE prs SET merged_at = 'now' WHERE id = ?", p);
  assert.equal(prStatus(d, p), 'merged');
  assert.throws(() => run(d, "UPDATE prs SET head_sha = 'def' WHERE id = ?", p), /final/);
  assert.throws(() => comment(d, p), /final/);
});

test('bot and other people\'s PRs are only detected; task PRs need a started task', () => {
  const d = db();
  const started = task(d, 'started');
  setStatus(d, started, 'in_progress');
  assert.throws(() => pr(d, {kind: 'bot', origin: 'task', taskId: started}), /CHECK/);
  assert.throws(() => pr(d, {kind: 'mine', origin: 'task', taskId: null}), /CHECK/);
  const fresh = task(d, 'not started');
  assert.throws(() => pr(d, {kind: 'mine', origin: 'task', taskId: fresh}), /in progress or in review/);
  assert.ok(pr(d, {kind: 'other', origin: 'detected'}));
});

test('detection is idempotent on repo and number', () => {
  const d = db();
  const upsert = d.prepare(`INSERT INTO prs (repo, number, title, kind, origin) VALUES ('acme/app', 42, ?, 'bot', 'detected')
    ON CONFLICT (repo, number) DO UPDATE SET title = excluded.title`);
  upsert.run('Bump deps');
  upsert.run('Bump deps (v2)');
  assert.equal(one(d, 'SELECT count(*) n FROM prs').n, 1);
  assert.equal(one(d, 'SELECT title FROM prs').title, 'Bump deps (v2)');
});

test('auto-complete: in review with every PR merged; closed PRs are ignored', () => {
  const d = db();
  const t = task(d, 'Book a venue');
  setStatus(d, t, 'in_progress');
  const a = pr(d, {taskId: t});
  setStatus(d, t, 'in_review');
  const b = pr(d, {taskId: t});
  assert.throws(() => setStatus(d, t, 'done'), /open PRs/);
  run(d, "UPDATE prs SET closed_at = 'now' WHERE id = ?", b);
  run(d, 'UPDATE prs SET accepted = 1 WHERE id = ?', a);
  run(d, "UPDATE prs SET merged_at = 'now' WHERE id = ?", a);
  assert.deepEqual(d.prepare('SELECT id FROM tasks_to_auto_complete').all().map(r => r.id), [t]);
  setStatus(d, t, 'done');
  const s = one(d, 'SELECT merged_prs, closed_prs, open_prs FROM task_state WHERE id = ?', t);
  assert.deepEqual({...s}, {merged_prs: 1, closed_prs: 1, open_prs: 0});
});

test('events log accepts both machines and valid JSON only', () => {
  const d = db();
  const t = task(d, 'x');
  run(d, "INSERT INTO events (task_id, event, actor, from_status, to_status) VALUES (?, 'ENTER', 'human', NULL, 'todo')", t);
  const p = pr(d, {kind: 'other', origin: 'detected'});
  run(d, `INSERT INTO events (pr_id, event, actor, to_status, detail) VALUES (?, 'DETECTED', 'system', 'awaiting_review', '{"source":"github"}')`, p);
  assert.throws(() => run(d, "INSERT INTO events (pr_id, event, actor, detail) VALUES (?, 'X', 'me', 'not json')", p), /CHECK/);
  assert.equal(one(d, 'SELECT count(*) n FROM events').n, 2);
});
